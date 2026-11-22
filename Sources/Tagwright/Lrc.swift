import Foundation

/// Port of pipeline/lrc_format.py and the decision part of pipeline/lyrics.py (ADR 0006, 0021).
enum Lrc {
	// MARK: regex helpers

	private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
	private static let timestamp = rx(#"\[\d{2}:\d{2}\.\d{2}\]"#)
	private static let badTimestamp = rx(#"\[\d{3,}:\d{2}:\d{2}\.\d{2}\]"#)
	private static let idTagLine = rx(#"^\[([a-zA-Z]{2,20}):.*\]\s*$"#)
	private static let lrcLine = rx(#"^(\[\d{2}:\d{2}\.\d{2}\])(.*)$"#)
	private static let manualInstrumental = rx(#"\[\d{2}:\d{2}\.\d{2}\]\s*(?:\[instrumental\]|\(instrumental\))"#, .caseInsensitive)
	private static let laOrInstrumental = rx(#"^\[(la|instrumental):"#, .caseInsensitive)
	private static let acuteBetweenLetters = rx("(?<=\\p{L})[\u{00B4}`](?=\\p{L})")
	private static let trailingBracket = rx(#"\s*[\(\[][^()\[\]]*[\)\]]\s*$"#)
	private static let longStamp = rx(#"\[(\d{2}:\d{2}\.\d{2})\d\]"#)

	private static func has(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
	private static func groups(_ r: NSRegularExpression, _ s: String) -> [String]? {
		guard let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
		return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
	}
	/// Python's splitlines(): no trailing empty element.
	static func lines(_ s: String) -> [String] {
		var l = s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
		if l.last == "" { l.removeLast() }
		return l
	}

	static let instrumentalMarker = "[instrumental:true]"
	private static let managedKeys = ["ar", "ti", "al", "length"]
	private static let suffix = ["[la:zxx]", "[instrumental:true]", "[00:00.00](Instrumental)"]

	// MARK: classification

	static func isLrc(_ t: String) -> Bool { has(timestamp, t) }
	static func isInvalid(_ t: String) -> Bool { has(badTimestamp, t) }
	static func isInstrumentalMarker(_ t: String) -> Bool { t.contains(instrumentalMarker) }
	static func hasManualInstrumentalMarker(_ t: String) -> Bool { has(manualInstrumental, t) }

	/// Only a lone `zxx` says "no vocals" (ADR 0023).
	static func isInstrumentalLanguage(_ v: [String]) -> Bool { v.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } == ["zxx"] }

	// MARK: headers

	private static func mmss(_ secs: Double) -> String { String(format: "%02d:%02d", Int(secs) / 60, Int(secs) % 60) }

	static func refreshHeaders(_ lines: [String], artist: String, title: String, album: String, length: Double) -> [String] {
		let fresh = ["ar": artist, "ti": title, "al": album, "length": length > 0 ? mmss(length) : ""]
		var seen = Set<String>(), out: [String] = []
		for line in lines {
			if let g = groups(idTagLine, line), let v = fresh[g[0].lowercased()] {
				let k = g[0].lowercased(); seen.insert(k)
				out.append(v.isEmpty ? line : "[\(k):\(v)]")
			} else { out.append(line) }
		}
		let missing = managedKeys.filter { !seen.contains($0) && !(fresh[$0] ?? "").isEmpty }.map { "[\($0):\(fresh[$0]!)]" }
		return missing + out
	}

	static func applyHeaders(_ lrc: String, artist: String, title: String, album: String, length: Double) -> String {
		refreshHeaders(lines(lrc), artist: artist, title: title, album: album, length: length).filter { !$0.isEmpty }.joined(separator: "\n")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func instrumental(artist: String, title: String, album: String, length: Double) -> String {
		let head = ["[ar:\(artist)]", "[ti:\(title)]", "[al:\(album)]", "[length:\(mmss(length))]"]
		return (head.filter { !has(laOrInstrumental, $0) } + suffix).joined(separator: "\n")
	}

	// MARK: text normalisation

	private static let map: [Character: String] = {
		var m: [Character: String] = ["\u{2026}": "..."]
		for c in "\u{2019}\u{2018}\u{201B}\u{2032}" { m[c] = "'" }
		for c in "\u{201C}\u{201D}\u{201F}\u{2033}" { m[c] = "\"" }
		for c in "\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}" { m[c] = "-" }
		for c in "\u{00A0}\u{2007}\u{2009}\u{202F}\u{2002}\u{2003}" { m[c] = " " }
		for c in "\u{200B}\u{FEFF}\u{2060}\u{3164}\u{FFFC}" { m[c] = "" }
		return m
	}()

	static func normalizeText(_ t: String) -> String {
		// unicodeScalars: a ZWSP after a letter must not be glued into one grapheme and escape the map
		var s = ""
		for u in t.unicodeScalars { let c = Character(u); s += map[c] ?? String(c) }
		return acuteBetweenLetters.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "'")
	}

	static func normalizeLrc(_ lrc: String) -> String {
		lines(lrc).map { line in
			if let g = groups(lrcLine, line) { return g[0] + normalizeText(g[1]) }
			return has(idTagLine, line) ? line : normalizeText(line)
		}.joined(separator: "\n")
	}

	static func capitalizeLine(_ t: String) -> String {
		guard let i = t.firstIndex(where: { !$0.isWhitespace }) else { return t }
		return String(t[..<i]) + String(t[i]).uppercased() + String(t[t.index(after: i)...])
	}

	static func capitalizeLrc(_ lrc: String) -> String {
		lines(lrc).map { line in
			guard let g = groups(lrcLine, line) else { return line }
			return g[0] + capitalizeLine(String(g[1].drop(while: { $0.isWhitespace })))
		}.joined(separator: "\n")
	}

	static func capitalizeTxt(_ t: String) -> String { lines(t).map(capitalizeLine).joined(separator: "\n") }

	// MARK: suspect timestamps (shown in the editor)

	static func body(_ lrc: String) -> (times: [Double], texts: [String]) {
		let r = rx(#"^\[(\d{2}):(\d{2})\.(\d{2})\](.*)$"#)
		var times: [Double] = [], texts: [String] = []
		for l in lrc.components(separatedBy: "\n") {
			let line = l.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
			if let g = groups(r, line) { times.append(Double(g[0])! * 60 + Double(g[1])! + Double(g[2])! / 100); texts.append(g[3]) }
		}
		return (times, texts)
	}

	/// Signs that a synced LRC's timestamps cannot be trusted; empty if sound.
	static func suspectReasons(_ lrc: String, length: Double = 0) -> [String] {
		if isInstrumentalMarker(lrc) { return [] }
		let (times, texts) = body(lrc)
		guard times.count >= 3 else { return [] }
		var reasons: [String] = []
		let counts = Dictionary(grouping: times, by: { $0 }).mapValues(\.count)
		if counts.count == 1 { reasons.append("one_timestamp") }
		else {
			let big = counts.values.max()!
			if big >= 5 && Double(big) / Double(times.count) >= 0.2 { reasons.append("shared_timestamps") }
			if length > 0, times.last! < 0.5 * length { reasons.append("ends_early") }
		}
		if texts.contains(where: { $0.contains("\u{2661}") || $0.contains("\u{2665}") }) { reasons.append("junk_hearts") }
		return reasons
	}

	/// Lines wrong on their own: three or more on one timestamp, or holding a heart.
	static func problemLineCount(_ lrc: String) -> Int {
		if isInstrumentalMarker(lrc) { return 0 }
		let (times, texts) = body(lrc)
		guard times.count >= 3 else { return 0 }
		let counts = Dictionary(grouping: times, by: { $0 }).mapValues(\.count)
		return zip(times, texts).filter { counts[$0]! >= 3 || $1.contains("\u{2661}") || $1.contains("\u{2665}") }.count
	}

	// MARK: decision (lyrics.fetch_one)

	enum Lookup { case found([String: Any]), notFound, failed }
	struct Result { var lyrics = "", kind = "none", action = "skip" }   // action: new fix skip error failed

	static func stripTrailingBracket(_ t: String) -> String {
		trailingBracket.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "").trimmingCharacters(in: .whitespaces)
	}

	/// ALBUMARTIST (fallback ARTIST), then the track's own ARTIST when it differs; full title then without
	/// trailing bracket; with the album name, then without.
	static func searchParams(artist: String, trackArtist: String, title: String, album: String, duration: String) -> [[String: String]] {
		let stripped = stripTrailingBracket(title)
		let names = stripped == title ? [title] : [title, stripped]
		let artists = trackArtist.isEmpty || trackArtist == artist ? [artist] : [artist, trackArtist]
		return artists.flatMap { a in names.flatMap { n in
			[["artist_name": a, "track_name": n, "album_name": album, "duration": duration], ["artist_name": a, "track_name": n, "duration": duration]]
		} }
	}

	static func decide(tags: Tags, length: Double, log: Log, lookup: ([String: String]) async -> Lookup) async -> Result {
		let artist = tags.first("ALBUMARTIST", "ARTIST"), title = tags.first("TITLE"), album = tags.first("ALBUM")
		let existing = tags.first("LYRICS").trimmingCharacters(in: .whitespacesAndNewlines)
		if artist.isEmpty || title.isEmpty { return Result(lyrics: "", kind: "none", action: "error") }
		func marker() -> String { instrumental(artist: artist, title: title, album: album, length: length) }

		if !existing.isEmpty, isInstrumentalMarker(existing) { return Result(lyrics: existing, kind: "instrumental", action: "skip") }
		if !existing.isEmpty, hasManualInstrumentalMarker(existing) { return Result(lyrics: marker(), kind: "instrumental", action: "fix") }
		if isInstrumentalLanguage(tags["LYRICS_LANGUAGE"] ?? []), !isLrc(existing) {
			return Result(lyrics: marker(), kind: "instrumental", action: "new")
		}
		if !existing.isEmpty, isLrc(existing) {   // an existing LRC is never replaced, only corrected
			let u = capitalizeLrc(normalizeLrc(applyHeaders(existing, artist: artist, title: title, album: album, length: length)))
			return Result(lyrics: u, kind: "lrc", action: u != existing ? "fix" : "skip")
		}
		var data: [String: Any] = [:]
		for p in searchParams(artist: artist, trackArtist: tags.first("ARTIST"), title: title, album: album, duration: "\(Int(length.rounded()))") {
			switch await lookup(p) {
			case .failed: return Result(lyrics: "", kind: "none", action: "failed")   // throttled/down is not "not found"
			case .found(let b): data = b
			case .notFound: continue
			}
			if p["track_name"] != title { log("lyrics found via stripped title '\(p["track_name"] ?? "")'") }
			break
		}
		if (data["instrumental"] as? Bool) == true {
			let m = marker()
			return Result(lyrics: existing == m ? existing : m, kind: "instrumental", action: existing == m ? "skip" : "new")
		}
		if let s = data["syncedLyrics"] as? String, !s.isEmpty {
			let lrc0 = longStamp.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "[$1]")
			if isInvalid(lrc0) { log("invalid LRC timestamps from lrclib, skipped: \(title)") }
			else {
				let lrc = capitalizeLrc(normalizeLrc(applyHeaders(lrc0, artist: artist, title: title, album: album, length: length)))
				return Result(lyrics: lrc, kind: "lrc", action: lrc == existing ? "skip" : "new")
			}
		}
		if let p = data["plainLyrics"] as? String, !p.isEmpty, existing.isEmpty {
			return Result(lyrics: capitalizeTxt(normalizeText(p)), kind: "txt", action: "new")
		}
		if !existing.isEmpty {
			let f = capitalizeTxt(normalizeText(existing))
			return Result(lyrics: f, kind: "txt", action: f != existing ? "fix" : "skip")
		}
		log("no lyrics found: \(title) (\(artist))")
		return Result(lyrics: "", kind: "none", action: "skip")
	}

	/// lrclib /api/search for the lyrics dialog (app.py lrclib_search): up to 20 results with their lyrics; nothing is written.
	struct Hit { var artist: String, title: String, album: String, duration: Int, instrumental: Bool, synced: String, plain: String }
	static func search(title: String, artist: String) async throws -> [Hit] {
		guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw StepError("enter a title to search for") }
		var c = URLComponents(string: "https://lrclib.net/api/search")!
		c.queryItems = [URLQueryItem(name: "track_name", value: title.trimmingCharacters(in: .whitespaces))] + (artist.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [URLQueryItem(name: "artist_name", value: artist.trimmingCharacters(in: .whitespaces))])
		let req = request(c.url!, timeout: 15)
		let d: Data, resp: URLResponse
		do { (d, resp) = try await URLSession.shared.data(for: req) } catch is CancellationError { throw CancellationError() } catch { throw StepError("lrclib.net could not be reached: \(error.localizedDescription)") }
		let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
		guard code == 200 else { throw StepError("lrclib.net answered HTTP \(code)") }
		let rows = (try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
		return rows.prefix(20).map { x in
			Hit(artist: x["artistName"] as? String ?? "", title: x["trackName"] as? String ?? "", album: x["albumName"] as? String ?? "",
				duration: Int(((x["duration"] as? Double) ?? 0).rounded()), instrumental: x["instrumental"] as? Bool ?? false,
				synced: x["syncedLyrics"] as? String ?? "", plain: x["plainLyrics"] as? String ?? "")
		}
	}

	static let userAgent = "Tagwright/0.2 (+https://github.com/koehntopp/tagwright)"
	static let appID = "Nm2UKEDqSxmkysVsuRQhjw9hWSYkbleD8mGFP7WcBOo"   // lrclib.py LRCLIB_APP_ID
	static func request(_ url: URL, timeout: Double) -> URLRequest {
		var r = URLRequest(url: url); r.timeoutInterval = timeout
		r.setValue(userAgent, forHTTPHeaderField: "User-Agent"); r.setValue(appID, forHTTPHeaderField: "Lrclib-App-Id")
		return r
	}

	/// lrclib.py get(): one lookup through the shared pacer, up to 4 attempts. `.failed` when lrclib kept failing
	/// or the circuit is open (the retry rounds take those tracks again).
	static func get(_ pacer: LrcPacer, _ params: [String: String]) async -> Lookup {
		if await pacer.isDown { return .failed }
		var c = URLComponents(string: "https://lrclib.net/api/get")!
		c.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
		let req = request(c.url!, timeout: 10)
		for attempt in 0..<4 {
			if Task.isCancelled { return .failed }
			let started = await pacer.acquire()
			var retryAfter: Double?, limited = false
			do {
				let (d, resp) = try await URLSession.shared.data(for: req)
				await pacer.release()
				let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
				switch code {
				case 200:
					await pacer.success()
					return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]).map { .found($0) } ?? .failed
				case 404: await pacer.success(); return .notFound
				case 401: await pacer.rejectCredentials(); return .failed
				default:
					limited = code == 429
					if [429, 503].contains(code), let h = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") {
						retryAfter = h * (1 + Double.random(in: 0...0.3))   // lrclib: honour Retry-After plus up to 30 % jitter
					}
				}
			} catch { await pacer.release(); if error is CancellationError { return .failed } }
			await pacer.failure(startedAt: started, retryAfter: retryAfter, rateLimited: limited)
			if await pacer.isDown { break }
			if !limited, retryAfter == nil, attempt < 3 {   // 5xx / network error: plain backoff
				try? await Task.sleep(for: .seconds(pow(2, Double(attempt)) * (1 + Double.random(in: 0...0.3))))
			}
		}
		return .failed
	}

}

/// lrclib.py Pacer: one request in flight, each starting 0.5 s (+ up to 0.25 s) after the previous one finished.
/// A 429 doubles the interval (up to 8 s), ten successes in a row shrink it again; Retry-After sets a floor. Five
/// failures in a row with no success for 60 s (or a rejected app id) open the circuit.
actor LrcPacer {
	private var interval = 0.5, nextStart = Date.distantPast, floorUntil = Date.distantPast, raisedAt = Date.distantPast
	private var successes = 0, failStreak = 0, lastSuccess = Date(), authFailed = false
	private var busy = false
	var currentInterval: Double { interval }

	func acquire() async -> Date {
		while busy { try? await Task.sleep(for: .milliseconds(20)) }
		busy = true
		let start = max(Date(), nextStart, floorUntil)
		if start > Date() { try? await Task.sleep(for: .seconds(start.timeIntervalSinceNow)) }
		return start
	}
	func release() {
		nextStart = max(nextStart, Date().addingTimeInterval(interval + Double.random(in: 0...0.25)))
		busy = false
	}
	func failure(startedAt: Date, retryAfter: Double?, rateLimited: Bool) {
		successes = 0; failStreak += 1
		if rateLimited, startedAt > raisedAt, interval < 8 {
			interval = min(interval * 2, 8); raisedAt = Date(); nextStart = max(nextStart, Date().addingTimeInterval(interval))
		}
		if let r = retryAfter ?? (rateLimited ? 1 : nil) { floorUntil = max(floorUntil, Date().addingTimeInterval(min(r, 300))) }
	}
	func success() {
		failStreak = 0; lastSuccess = Date(); successes += 1
		if successes >= 10, interval > 0.5 { interval = max(0.5, interval * 0.75); successes = 0 }
	}
	func rejectCredentials() { authFailed = true }
	var isDown: Bool { authFailed || (failStreak >= 5 && -lastSuccess.timeIntervalSinceNow >= 60) }
	/// Before a retry round: forget the failure streak, keep the learned interval.
	func closeCircuit() { failStreak = 0; lastSuccess = Date(); authFailed = false; floorUntil = .distantPast }
}
