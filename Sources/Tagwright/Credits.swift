import Foundation

/// Port of pipeline/credits.py (ADR 0100): track artists and credits from a Discogs release, one value per name; the
/// legacy tags an assignment removes; the required tags an update must never take away.
enum Credits {
	/// Dedicated credit tags: (tag, roles it equals, roles it contains); a role matches the first tag that fits.
	static let tags: [(String, [String], [String])] = [
		("COMPOSER", ["written-by", "written by", "composed by", "music by", "songwriter"], []),
		("LYRICIST", ["lyrics by", "words by"], []),
		("ARRANGER", [], ["arranged by"]),
		("CONDUCTOR", ["conductor"], []),
		("REMIXER", [], ["remix"]),
		("MIXER", ["mixed by"], []),
		("PRODUCER", [], ["producer"]),
		("ENGINEER", ["recorded by"], ["engineer"]),
	]
	static let keys = tags.map(\.0) + ["PERSONNEL"]
	/// Discogs "... By" roles under the noun Roon lists; any other "X By" becomes "X".
	static let personnelRoles = [
		"mastered by": "Mastering Engineer", "remastered by": "Remastering Engineer", "programmed by": "Programming",
		"edited by": "Editing", "directed by": "Director", "orchestrated by": "Orchestration",
		"transferred by": "Transfer", "translated by": "Translation",
	]
	static let legacy: Set<String> = [
		"PERFORMER", "PERFORMERYR", "INVOLVEDPEOPLE", "INVOLVEDPEOPLEYR", "RETAIL DATE", "RIP DATE", "RELEASE TYPE",
		"ORGANIZATION", "DYNAMIC RANGE (DR)", "DYNAMIC RANGE (R128)", "ALBUM DYNAMIC RANGE (DR)", "ALBUM DYNAMIC RANGE (R128)",
		"ORIGINALYEAR", "TRACKNUM", "DISC", "TRACK", "ALBUMARTIST2", "ARTISTS", "NUMBER_OF_FRAMES", "NUMBER_OF_BYTES", "BPS",
		"DURATION", "LENGTH", "APISEEDS_STATUS", "GET_LYRICS_STATUS",
	]
	static let legacyPrefixes = ["DISCOGS ", "_STATISTICS_"]
	static let required = ["TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "TRACKNUMBER", "DISCNUMBER"]

	static func isLegacy(_ key: String) -> Bool { let k = key.uppercased(); return legacy.contains(k) || legacyPrefixes.contains { k.hasPrefix($0) } }

	/// Required tags that had a value before and have none after.
	static func lostRequired(_ before: Tags, _ after: Tags) -> [String] {
		func has(_ t: Tags, _ k: String) -> Bool { (t[k] ?? []).contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
		return required.filter { has(before, $0) && !has(after, $0) }
	}

	/// The positions of the release's tracks in order, medley parts included (credits.flat_tracks).
	static func order(_ r: [String: Any]) -> [String] {
		var out: [String] = []
		for t in r["tracklist"] as? [[String: Any]] ?? [] {
			let parts = t["type_"] as? String == "index" ? t["sub_tracks"] as? [[String: Any]] ?? [] : []
			if !parts.isEmpty || t["type_"] as? String == "track" { out.append(t["position"] as? String ?? "") }
			out += parts.map { $0["position"] as? String ?? "" }
		}
		return out
	}

	/// Whether a credit's `tracks` text ("1 to 3, 5", "A1 to B2") covers the position.
	static func covered(_ spec: String, _ position: String, _ order: [String]) -> Bool {
		guard let at = order.firstIndex(of: position) else { return false }
		for part in spec.split(separator: ",") {
			let ends = part.trimmingCharacters(in: .whitespaces).components(separatedBy: " to ").map { $0.trimmingCharacters(in: .whitespaces) }
			if ends.count == 2, let a = order.firstIndex(of: ends[0]), let b = order.firstIndex(of: ends[1]) { if a <= at && at <= b { return true } }
			else if ends.first == position { return true }
		}
		return false
	}

	/// The roles of one credit ("Bass, Producer [Additional]"), each without its bracketed qualifier.
	static func roles(_ role: String) -> [String] {
		var parts: [String] = [], cur = "", depth = 0
		for c in role {
			if c == "[" { depth += 1 } else if c == "]" { depth -= 1 }
			if c == ",", depth == 0 { parts.append(cur); cur = "" } else { cur.append(c) }
		}
		parts.append(cur)
		return parts.map { $0.replacingOccurrences(of: #"\s*\[.*?\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
	}

	static func tag(of role: String) -> String {
		let low = role.lowercased()
		return tags.first { $0.1.contains(low) || $0.2.contains { low.contains($0) } }?.0 ?? "PERSONNEL"
	}

	static func personnelRole(_ role: String) -> String {
		personnelRoles[role.lowercased()] ?? role.replacingOccurrences(of: #"\s+By$"#, with: "", options: [.regularExpression, .caseInsensitive])
	}

	static func collect(_ credits: [[String: Any]]) -> Tags {
		var out = Tags()
		for c in credits {
			let n = Discogs.name(c["name"] as? String ?? "")
			guard !n.isEmpty else { continue }
			for role in roles(c["role"] as? String ?? "") {
				let k = tag(of: role)
				out[k, default: []].append(k == "PERSONNEL" ? "\(n) - \(personnelRole(role))" : n)
			}
		}
		return out.mapValues(Discogs.uniq)
	}

	/// ARTIST and the credit tags of one tracklist entry (`parent`: the medley it is a part of), one value per name;
	/// tags without a value are left out.
	static func trackTags(_ r: [String: Any], entry: [String: Any], parent: [String: Any]? = nil, order: [String]? = nil) -> Tags {
		let order = order ?? self.order(r)
		let positions = Set([entry["position"] as? String ?? "", parent?["position"] as? String ?? ""]).subtracting([""])
		let releaseCredits = r["extraartists"] as? [[String: Any]] ?? []
		let own = collect((entry["extraartists"] as? [[String: Any]] ?? []) + (parent?["extraartists"] as? [[String: Any]] ?? []) + releaseCredits.filter { c in
			let spec = (c["tracks"] as? String ?? "").trimmingCharacters(in: .whitespaces)
			return !spec.isEmpty && positions.contains { covered(spec, $0, order) }
		})
		let wide = collect(releaseCredits.filter { ($0["tracks"] as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
		var out = Tags()
		for k in keys { out[k] = own[k] ?? wide[k] ?? [] }
		out["PERSONNEL"] = Discogs.uniq((own["PERSONNEL"] ?? []) + (wide["PERSONNEL"] ?? []))
		let artists = (entry["artists"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 } ?? (parent?["artists"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 } ?? r["artists"] as? [[String: Any]] ?? []
		out["ARTIST"] = Discogs.uniq(artists.map { Discogs.name($0["name"] as? String ?? "") })
		return out.filter { !$0.value.isEmpty }
	}
}
