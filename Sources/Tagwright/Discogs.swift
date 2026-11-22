import Foundation
import Security

/// Secrets live in the Keychain only (ADR 0007).
enum Keychain {
	static func get(_ account: String) -> String? {
		let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Tagwright", kSecAttrAccount as String: account, kSecReturnData as String: true]
		var r: AnyObject?
		guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
		return String(data: d, encoding: .utf8)
	}
	static func set(_ account: String, _ value: String) {
		let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Tagwright", kSecAttrAccount as String: account]
		SecItemDelete(base as CFDictionary)
		guard !value.isEmpty else { return }
		SecItemAdd(base.merging([kSecValueData as String: Data(value.utf8)]) { $1 } as CFDictionary, nil)
	}
}


// MARK: rate limiter (ADR 0053): one request at a time, >= 1.1 s apart, 5 s extra when the quota is nearly used up

actor RateLimiter {
	private var last = Date.distantPast
	private var extra: TimeInterval = 0
	let interval: TimeInterval
	init(interval: TimeInterval) { self.interval = interval }

	func wait() async {
		let due = last.addingTimeInterval(interval + extra)
		let delay = due.timeIntervalSinceNow
		if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
		last = Date(); extra = 0
	}
	func slowDown(_ s: TimeInterval) { extra = s }
}

struct DiscogsHit: Identifiable, Hashable {
	var id: Int
	var title: String, year: String, format: String, label: String, catno: String, country = "", thumb = ""
	var tracks: Int?          // filled in after the list appears
	var match = ""            // "MusicBrainz"
}

struct DTrack: Identifiable, Hashable {
	var id: Int
	var disc: Int, number: Int, title: String, artist: String, seconds: Int, subtitle: String
	var writers: [String] = [], producers: [String] = [], engineers: [String] = []
}

enum Discogs {
	static let limiter = RateLimiter(interval: 1.1)
	nonisolated(unsafe) static var cache: [String: [String: Any]] = [:]

	static func get(_ path: String, _ q: [String: String] = [:]) async throws -> [String: Any] {
		let key = path + (q.isEmpty ? "" : "?" + q.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))
		if let c = cache[key] { return c }
		guard let token = Keychain.get("discogs"), !token.isEmpty else { throw StepError("Enter your Discogs token in Settings") }
		var c = URLComponents(string: "https://api.discogs.com/\(path)")!
		if !q.isEmpty { c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) } }
		var r = URLRequest(url: c.url!)
		r.setValue("Tagwright/1.0", forHTTPHeaderField: "User-Agent")
		r.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
		for attempt in 0..<4 {
			await limiter.wait()
			let (d, resp) = try await URLSession.shared.data(for: r)
			let http = resp as? HTTPURLResponse
			if let rem = http?.value(forHTTPHeaderField: "X-Discogs-Ratelimit-Remaining").flatMap(Int.init), rem < 3 { await limiter.slowDown(5) }
			switch http?.statusCode ?? 0 {
			case 200:
				let j = (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
				cache[key] = j
				return j
			case 429 where attempt < 3: try await Task.sleep(for: .seconds(60)); continue
			case 429: throw StepError("Discogs rate limit reached; try again in a minute")
			case 401: throw StepError("Discogs refused the token (401); check it in Settings")
			case 404: throw StepError("Discogs: not found")
			case let s: throw StepError("Discogs answered \(s)")
			}
		}
		throw StepError("Discogs did not answer")
	}

	/// A numeric query loads that release directly (ADR 0053).
	static func search(query: String) async throws -> [DiscogsHit] {
		let q = query.trimmingCharacters(in: .whitespaces)
		if let id = Int(q) {
			let r = try await get("releases/\(id)")
			return [hit(r, id: id)]
		}
		let j = try await get("database/search", ["type": "release", "q": q, "per_page": "20"])
		return (j["results"] as? [[String: Any]] ?? []).compactMap { r in
			guard let id = r["id"] as? Int else { return nil }
			return DiscogsHit(id: id, title: r["title"] as? String ?? "", year: r["year"] as? String ?? "", format: (r["format"] as? [String])?.joined(separator: ", ") ?? "",
				label: (r["label"] as? [String])?.prefix(2).joined(separator: ", ") ?? "", catno: r["catno"] as? String ?? "",
				country: r["country"] as? String ?? "", thumb: r["thumb"] as? String ?? "")
		}
	}

	private static func hit(_ r: [String: Any], id: Int) -> DiscogsHit {
		let artists = artistNames(r["artists"] as? [[String: Any]] ?? [])
		let labels = r["labels"] as? [[String: Any]] ?? []
		let fmt = (r["formats"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
		return DiscogsHit(id: id, title: "\(artists) - \(r["title"] as? String ?? "")", year: (r["year"] as? Int).map(String.init) ?? "", format: fmt,
			label: labels.first?["name"] as? String ?? "", catno: labels.first?["catno"] as? String ?? "", country: r["country"] as? String ?? "",
			thumb: (r["thumb"] as? String) ?? ((r["images"] as? [[String: Any]])?.first?["uri150"] as? String ?? ""), tracks: tracklist(r).count)
	}

	static func trackCount(_ id: Int) async -> Int? { (try? await get("releases/\(id)")).map { tracklist($0).count } }

	// MARK: names (fixtags.clean_name, artist_names)

	static func name(_ s: String) -> String { s.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }

	static func artistNames(_ artists: [[String: Any]]) -> String {
		var out = ""
		for a in artists {
			out += name(a["name"] as? String ?? "")
			let j = (a["join"] as? String ?? "").trimmingCharacters(in: .whitespaces)
			if !j.isEmpty { out += j == "," ? ", " : " \(j) " }
		}
		return out.trimmingCharacters(in: .whitespaces)
	}

	// MARK: tracklist (ADR 0053, 0060, 0081)

	static func tracklist(_ r: [String: Any]) -> [DTrack] {
		var out: [DTrack] = []
		var heading = "", headDisc: Int?
		let albumArtist = artistNames(r["artists"] as? [[String: Any]] ?? [])
		func credits(_ t: [String: Any], _ roles: [String]) -> [String] {
			let ea = (t["extraartists"] as? [[String: Any]] ?? []).filter { a in roles.contains { (a["role"] as? String ?? "").lowercased().contains($0) } }
			return ea.map { name($0["name"] as? String ?? "") }
		}
		func parse(_ pos: String) -> (Int, Int)? {
			let u = pos.uppercased()
			if let m = u.range(of: #"^(?:CD|DVD)?(\d+)[-.](\d+)"#, options: .regularExpression) {
				let nums = u[m].components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap(Int.init)
				if nums.count >= 2 { return (nums[0], nums[1]) }
			}
			return nil
		}
		for t in r["tracklist"] as? [[String: Any]] ?? [] {
			let type = t["type_"] as? String ?? "track"
			let title = (t["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
			if type == "heading" {
				heading = title
				headDisc = title.range(of: #"^(?:disc|cd|dvd)\s*(\d+)"#, options: [.regularExpression, .caseInsensitive]).flatMap { Int(title[$0].filter(\.isNumber)) }
				continue
			}
			var pos = t["position"] as? String ?? ""
			var mainTitle = title
			if type == "index", let subs = t["sub_tracks"] as? [[String: Any]], let f = subs.first {
				pos = (f["position"] as? String ?? "").replacingOccurrences(of: #"\.\d+$"#, with: "", options: .regularExpression)
				mainTitle = title
			} else if type != "track" { continue }
			var disc = 1, no = out.count + 1
			if let (d, n) = parse(pos) { disc = d; no = n }
			else if let hd = headDisc, let n = Int(pos.filter(\.isNumber)) { disc = hd; no = n }
			else if let last = out.last, headDisc == nil { disc = last.disc; no = (out.filter { $0.disc == disc }.count) + 1 }
			else { no = out.count + 1 }
			let ta = artistNames(t["artists"] as? [[String: Any]] ?? [])
			let secs: Int = {
				let p = (t["duration"] as? String ?? "").split(separator: ":").compactMap { Int($0) }
				return p.count == 2 ? p[0] * 60 + p[1] : p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : 0
			}()
			let isDisc = heading.range(of: #"^(?:disc|cd|dvd)\s*\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
			var tr = DTrack(id: out.count, disc: disc, number: no, title: mainTitle, artist: ta.isEmpty ? albumArtist : ta, seconds: secs, subtitle: isDisc ? "" : heading)
			tr.writers = credits(t, ["written", "composed", "music by", "songwriter", "lyrics by", "words by"])
			tr.producers = credits(t, ["producer"]); tr.engineers = credits(t, ["engineer"])
			out.append(tr)
		}
		return out
	}

	// MARK: the tags a release gives (fixtags.discogs_extra_tags, ADR 0053 table)

	static func tagKey(_ prefix: String, _ text: String) -> String {
		let slug = text.uppercased().replacingOccurrences(of: "[^A-Z0-9]+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
		return slug.isEmpty ? "" : prefix + slug
	}

	static func extraTags(_ r: [String: Any]) -> Tags {
		var tags = Tags()
		var order: [String] = []
		func add(_ key: String, _ value: String) {
			let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !key.isEmpty, !v.isEmpty, !(tags[key]?.contains(v) ?? false) else { return }
			tags[key, default: []].append(v); order.append(key)
		}
		for c in r["companies"] as? [[String: Any]] ?? [] { add(tagKey("ALBUM_COMPANY_", c["entity_type_name"] as? String ?? ""), name(c["name"] as? String ?? "")) }
		for a in r["extraartists"] as? [[String: Any]] ?? [] {
			let role = a["role"] as? String ?? ""
			let detail = role.range(of: #"\[(.*)\]"#, options: .regularExpression).map { String(role[$0]).dropFirst().dropLast() }
			let base = role.replacingOccurrences(of: #"\s*\[.*?\]"#, with: "", options: .regularExpression)
			let n = name(a["name"] as? String ?? "")
			let value = (detail != nil && !n.isEmpty) ? "\(n) [\(detail!)]" : n
			for rr in base.split(separator: ",") { add(tagKey("ALBUM_CREDIT_", String(rr)), value) }
		}
		for i in r["identifiers"] as? [[String: Any]] ?? [] {
			let desc = (i["description"] as? String ?? "").trimmingCharacters(in: .whitespaces), val = (i["value"] as? String ?? "").trimmingCharacters(in: .whitespaces)
			add(tagKey("ALBUM_IDENT_", i["type"] as? String ?? ""), (!desc.isEmpty && !val.isEmpty) ? "\(val) (\(desc))" : val)
		}
		for l in r["labels"] as? [[String: Any]] ?? [] {
			add("ALBUM_RELEASE_LABELS", name(l["name"] as? String ?? ""))
			let cat = (l["catno"] as? String ?? "").trimmingCharacters(in: .whitespaces)
			if cat.lowercased() != "none" { add("ALBUM_RELEASE_CATALOGNUMBERS", cat) }
		}
		for f in r["formats"] as? [[String: Any]] ?? [] {
			add("ALBUM_RELEASE_FORMAT", f["name"] as? String ?? "")
			for d in f["descriptions"] as? [String] ?? [] { add("ALBUM_RELEASE_FORMAT_DESCRIPTIONS", d) }
			add("ALBUM_RELEASE_FORMAT_TEXT", f["text"] as? String ?? "")
		}
		for g in r["genres"] as? [String] ?? [] { add("ALBUM_RELEASE_GENRES", g) }
		for s in r["styles"] as? [String] ?? [] { add("ALBUM_RELEASE_STYLES", s) }
		for s in r["series"] as? [[String: Any]] ?? [] { add("ALBUM_RELEASE_SERIES", s["name"] as? String ?? "") }
		add("ALBUM_RELEASE_NOTES", r["notes"] as? String ?? "")
		add("ALBUM_RELEASE_DATE_FULL", r["released"] as? String ?? "")
		add("ALBUM_RELEASE_DATA_QUALITY", r["data_quality"] as? String ?? "")
		return tags
	}

	/// Player tags filled from a release when empty (ADR 0053 table); catalogue number and format are led by Discogs (ADR 0080).
	static func playerTags(_ r: [String: Any]) -> Tags {
		var t = Tags()
		func set(_ k: String, _ v: [String]) { let x = v.filter { !$0.isEmpty }; if !x.isEmpty { t[k] = x } }
		set("GENRE", r["genres"] as? [String] ?? [])
		set("MOOD", [(r["styles"] as? [String] ?? []).joined(separator: ", ")])
		let labels = r["labels"] as? [[String: Any]] ?? []
		set("LABEL", Array(NSOrderedSet(array: labels.map { name($0["name"] as? String ?? "") })) as? [String] ?? [])
		set("MEDIA", [(r["formats"] as? [[String: Any]] ?? []).map { f -> String in
			let d = (f["descriptions"] as? [String] ?? []).joined(separator: ",")
			return (f["name"] as? String ?? "") + (d.isEmpty ? "" : " (\(d))")
		}.joined(separator: ", ")])
		set("COUNTRY", [r["country"] as? String ?? ""])
		set("BARCODE", [((r["identifiers"] as? [[String: Any]] ?? []).first { ($0["type"] as? String) == "Barcode" })?["value"] as? String ?? ""])
		set("CATALOG", labels.compactMap { $0["catno"] as? String }.filter { $0.lowercased() != "none" && !$0.isEmpty })
		let companies = r["companies"] as? [[String: Any]] ?? []
		set("COPYRIGHT", [companies.compactMap { c -> String? in
			let t = c["entity_type_name"] as? String ?? "", n = name(c["name"] as? String ?? "")
			return t == "Phonographic Copyright (p)" ? "℗ \(n)" : t == "Copyright (c)" ? "© \(n)" : nil
		}.joined(separator: ", ")])
		set("PUBLISHER", [companies.filter { ($0["entity_type_name"] as? String) == "Published By" }.map { name($0["name"] as? String ?? "") }.joined(separator: ", ")])
		let ea = r["extraartists"] as? [[String: Any]] ?? []
		func role(_ keys: [String]) -> [String] { ea.filter { a in keys.contains { (a["role"] as? String ?? "").lowercased().contains($0) } }.map { name($0["name"] as? String ?? "") } }
		set("COMPOSER", role(["written", "composed", "music by", "songwriter", "lyrics by", "words by"]))
		set("PRODUCER", role(["producer"])); set("ENGINEER", role(["engineer"]))
		set("PERSONNEL", ea.map { "\(name($0["name"] as? String ?? "")) - \($0["role"] as? String ?? "")" })
		return t
	}

	// MARK: master (fixtags.fetch_master, master_year)

	static func master(of r: [String: Any]) async -> (title: String, year: Int?) {
		let title = (r["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
		guard let mid = r["master_id"] as? Int, mid > 0, let m = try? await get("masters/\(mid)") else { return (title, nil) }
		var year: Int?
		if let main = m["main_release"] as? Int, let mr = try? await get("releases/\(main)") { year = mr["year"] as? Int }
		return ((m["title"] as? String ?? title).trimmingCharacters(in: .whitespaces), year)
	}

	static func release(_ id: Int) async throws -> [String: Any] { try await get("releases/\(id)") }

	static func imageData(_ r: [String: Any]) async -> Data? {
		let imgs = r["images"] as? [[String: Any]] ?? []
		guard let u = (imgs.first { ($0["type"] as? String) == "primary" } ?? imgs.first)?["uri"] as? String, let url = URL(string: u), let token = Keychain.get("discogs") else { return nil }
		var q = URLRequest(url: url); q.setValue("Tagwright/1.0", forHTTPHeaderField: "User-Agent"); q.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
		await limiter.wait()
		return try? await URLSession.shared.data(for: q).0
	}
}

// MARK: MusicBrainz (ADR 0023)

struct MBHit: Identifiable, Hashable {
	var id: String
	var title: String, artist: String, date: String, country: String, tracks: Int, catno: String, label: String, format: String, barcode: String
	var match = ""
	var thumbOK = true
}

struct MBRelease {
	var id: String, year: String, tracks: Int, discogsIDs: [Int], group: String
}

enum MusicBrainz {
	static let limiter = RateLimiter(interval: 1.1)
	nonisolated(unsafe) static var cache: [String: Any] = [:]

	static func get(_ path: String, _ q: [String: String]) async throws -> [String: Any] {
		var c = URLComponents(string: "https://musicbrainz.org/ws/2/\(path)")!
		c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "fmt", value: "json")]
		let key = c.url!.absoluteString
		if let hit = cache[key] as? [String: Any] { return hit }
		var r = URLRequest(url: c.url!)
		r.setValue("Tagwright/1.0 (+https://github.com/koehntopp/tagwright)", forHTTPHeaderField: "User-Agent")
		for attempt in 0..<4 {
			await limiter.wait()
			let (d, resp) = try await URLSession.shared.data(for: r)
			switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
			case 200:
				let j = (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
				cache[key] = j; return j
			case 429, 503 where attempt < 3: try await Task.sleep(for: .seconds(5)); continue
			case 404: throw StepError("MusicBrainz: not found")
			case let s: throw StepError("MusicBrainz answered \(s)")
			}
		}
		throw StepError("MusicBrainz did not answer")
	}

	static func parse(_ r: [String: Any]) -> MBHit? {
		guard let id = r["id"] as? String else { return nil }
		let artist = (r["artist-credit"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
		let li = (r["label-info"] as? [[String: Any]]) ?? []
		let labels = li.compactMap { ($0["label"] as? [String: Any])?["name"] as? String }
		let cats = li.compactMap { $0["catalog-number"] as? String }
		let fmt = (r["media"] as? [[String: Any]])?.first?["format"] as? String ?? ""
		return MBHit(id: id, title: r["title"] as? String ?? "", artist: artist, date: String((r["date"] as? String ?? "").prefix(4)), country: r["country"] as? String ?? "",
			tracks: (r["track-count"] as? Int) ?? (r["media"] as? [[String: Any]])?.reduce(0) { $0 + (($1["track-count"] as? Int) ?? 0) } ?? 0,
			catno: Array(NSOrderedSet(array: cats)).compactMap { $0 as? String }.joined(separator: ", "), label: Array(NSOrderedSet(array: labels)).compactMap { $0 as? String }.joined(separator: ", "), format: fmt, barcode: r["barcode"] as? String ?? "")
	}

	/// ADR 0023: a UUID loads that release; otherwise every word matches the title or an artist. Discogs-ID, barcode and catalogue matches first.
	static func search(query: String, discogsID: String, barcode: String, catno: String) async throws -> [MBHit] {
		let q = query.trimmingCharacters(in: .whitespaces)
		if UUID(uuidString: q) != nil {
			let r = try await get("release/\(q)", ["inc": "labels+media+artist-credits"])
			return parse(r).map { [$0] } ?? []
		}
		var lead: [MBHit] = []
		if let did = Int(discogsID) {
			let r = try? await get("url", ["resource": "https://www.discogs.com/release/\(did)", "inc": "release-rels"])
			for rel in (r?["relations"] as? [[String: Any]] ?? []).prefix(5) {
				if let id = (rel["release"] as? [String: Any])?["id"] as? String, let full = try? await get("release/\(id)", ["inc": "labels+media+artist-credits"]), var h = parse(full) { h.match = "Discogs ID match"; lead.append(h) }
			}
		}
		if lead.isEmpty, !barcode.isEmpty, let j = try? await get("release", ["query": "barcode:\(barcode)", "limit": "5"]) {
			for r in j["releases"] as? [[String: Any]] ?? [] { if var h = parse(r) { h.match = "barcode match"; lead.append(h) } }
		}
		if lead.isEmpty, !catno.isEmpty, catno.lowercased() != "none", let j = try? await get("release", ["query": "catno:\"\(catno)\"", "limit": "2"]) {
			for r in j["releases"] as? [[String: Any]] ?? [] { if var h = parse(r) { h.match = "catalog number match"; lead.append(h) } }
		}
		let words = q.split(separator: " ").map { w in "(release:\(w) OR artist:\(w))" }.joined(separator: " AND ")
		let j = try await get("release", ["query": words.isEmpty ? q : words, "limit": "20"])
		let rest = (j["releases"] as? [[String: Any]] ?? []).compactMap(parse).filter { h in !lead.contains { $0.id == h.id } }
		return lead + rest
	}

	struct Detail {
		var title = "", artist = ""
		var id: String, groupID: String, groupTypes: String, artistIDs: [String], barcode: String, asin: String, country: String, status: String
		var tracks: [DTrack]; var trackArtistIDs: [[String]]
	}

	/// Full release with its tracks (ADR 0078: MusicBrainz tracks carry disc, position on the medium, title, artist, length).
	static func detail(_ id: String) async throws -> Detail {
		let r = try await get("release/\(id)", ["inc": "release-groups+artist-credits+recordings+labels"])
		let g = r["release-group"] as? [String: Any] ?? [:]
		let types = ([g["primary-type"] as? String].compactMap { $0 } + (g["secondary-types"] as? [String] ?? [])).joined(separator: ",")
		let ac = (r["artist-credit"] as? [[String: Any]] ?? []).compactMap { ($0["artist"] as? [String: Any])?["id"] as? String }
		var tracks: [DTrack] = [], ids: [[String]] = []
		for m in r["media"] as? [[String: Any]] ?? [] {
			let disc = (m["position"] as? Int) ?? 1
			for t in m["tracks"] as? [[String: Any]] ?? [] {
				let credit = (t["artist-credit"] as? [[String: Any]] ?? [])
				let artist = credit.map { c in (c["name"] as? String ?? "") + (c["joinphrase"] as? String ?? "") }.joined()
				tracks.append(DTrack(id: tracks.count, disc: disc, number: (t["position"] as? Int) ?? tracks.count + 1, title: t["title"] as? String ?? "", artist: artist,
					seconds: ((t["length"] as? Int) ?? 0) / 1000, subtitle: (m["title"] as? String) ?? ""))
				ids.append(credit.compactMap { ($0["artist"] as? [String: Any])?["id"] as? String })
			}
		}
		return Detail(title: r["title"] as? String ?? "", artist: (r["artist-credit"] as? [[String: Any]] ?? []).map { c in (c["name"] as? String ?? "") + (c["joinphrase"] as? String ?? "") }.joined(), id: id, groupID: g["id"] as? String ?? "", groupTypes: types, artistIDs: ac, barcode: r["barcode"] as? String ?? "", asin: r["asin"] as? String ?? "",
			country: r["country"] as? String ?? "", status: r["status"] as? String ?? "", tracks: tracks, trackArtistIDs: ids)
	}

	static func release(_ id: String) async -> MBRelease? {
		guard let r = try? await get("release/\(id)", ["inc": "release-groups+url-rels+recordings"]) else { return nil }
		let discogs = (r["relations"] as? [[String: Any]] ?? []).compactMap { rel -> Int? in
			guard let u = (rel["url"] as? [String: Any])?["resource"] as? String, u.contains("discogs.com") && u.contains("/release/") else { return nil }
			return Int(u.components(separatedBy: "/release/").last?.prefix { $0.isNumber } ?? "")
		}
		let n = (r["media"] as? [[String: Any]])?.reduce(0) { $0 + (($1["track-count"] as? Int) ?? 0) } ?? 0
		return MBRelease(id: id, year: String((r["date"] as? String ?? "").prefix(4)), tracks: n, discogsIDs: discogs, group: (r["release-group"] as? [String: Any])?["title"] as? String ?? "")
	}
}
