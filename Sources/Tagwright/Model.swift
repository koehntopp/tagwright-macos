import Foundation

// MARK: naming (ADR 0010, 0037)

enum Naming {
	static let nameMax = 255

	/// python-slugify(lowercase=False, separator="_") then sanitize: the rule of bliss.clean().
	static func clean(_ text: String) -> String {
		var s = text.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? text
		s = s.replacingOccurrences(of: "'", with: "")
		s = s.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "_", options: .regularExpression)
		return s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
	}

	/// <disc>_<track>_<title>.flac, nil while TITLE, TRACKNUMBER or DISCNUMBER is empty.
	static func blissName(_ t: Tags) -> String? {
		let title = t.first("TITLE"), no = t.first("TRACKNUMBER"), disc = t.first("DISCNUMBER")
		guard !title.isEmpty, !no.isEmpty, !disc.isEmpty else { return nil }
		func pad(_ s: String) -> String { let p = String(s.split(separator: "/").first ?? ""); return String(repeating: "0", count: max(0, 2 - p.count)) + p }
		let head = "\(pad(disc))_\(pad(no))_"
		let room = nameMax - head.utf8.count - 5
		var body = clean(title)
		while body.utf8.count > room { body.removeLast() }
		body = body.trimmingCharacters(in: CharacterSet(charactersIn: "_ ."))
		return "\(head)\(body).flac"
	}

	/// <album artist>/<album [version]>, nil while ALBUMARTIST or ALBUM is empty.
	static func blissAlbum(_ t: Tags) -> String? {
		var album = t.first("ALBUM")
		let artist = t.first("ALBUMARTIST")
		guard !album.isEmpty, !artist.isEmpty else { return nil }
		let ver = t.first("VERSION")
		if !ver.isEmpty && !album.contains(ver) { album += " \(ver)" }
		return "\(clean(artist))/\(clean(album))"
	}

	static func versionString(year: String, dr: String, format: String, edition: String, catalog: String) -> String {
		var parts: [String] = []
		if let y = Int(year.prefix(4)), y > 0 { parts.append("\(y)") }
		if let d = Int(dr) { parts.append(String(format: "DR%02d", d)) }
		if !format.isEmpty { parts.append(format) }
		if !edition.isEmpty { parts.append("(\(edition))") }
		if !catalog.isEmpty { parts.append("(\(catalog))") }
		return parts.joined(separator: " ")
	}

	static func sameName(_ a: String, _ b: String) -> Bool {
		a.lowercased().decomposedStringWithCanonicalMapping == b.lowercased().decomposedStringWithCanonicalMapping
	}
}

// MARK: status model (ADR 0054)

enum Status: String, CaseIterable { case needs, ready, fixed
	var label: String { switch self { case .needs: "Needs input"; case .ready: "Incomplete"; case .fixed: "Fixed" } }
}

enum StepID: Int, CaseIterable, Identifiable {
	case dr, replaygain, fingerprints, tags, lyrics, filenames
	var id: Int { rawValue }
	var label: String { ["Dynamic range", "ReplayGain", "Fingerprints", "Tags & cover", "Lyrics", "Filenames"][rawValue] }
	var icon: String { ["chart.bar", "speaker.wave.2", "touchid", "tag", "mic", "doc.text"][rawValue] }
	var optional: Bool { self == .lyrics }
}

enum StepState { case done, partial, open }

enum LyricsKind { case lrc, txt, instr, none }

struct Issue: Identifiable {
	enum Level { case error, warn, ingest, info }
	var id: String { text }
	var level: Level
	var text: String
	var action = ""   // search, album, tracks, cover: which button the note offers (app.py album_issues)
}

struct Missing: Identifiable {
	var step: StepID
	var label: String
	var count: Int
	var of: Int
	var tracks: [String]
	var id: Int { step.rawValue }
}

struct Track: Identifiable {
	var url: URL
	var tags: Tags
	var info: StreamInfo
	var id: String { url.path }
	var title: String { tags.first("TITLE").isEmpty ? url.deletingPathExtension().lastPathComponent : tags.first("TITLE") }
	var number: String { String(tags.first("TRACKNUMBER").split(separator: "/").first ?? "") }
	var disc: String { String(tags.first("DISCNUMBER").split(separator: "/").first ?? "") }
	var dr: String { tags.first("DYNAMIC_RANGE") }
	var fingerprint: String { tags.first("ACOUSTID_FINGERPRINT", "ACOUSTID FINGERPRINT") }

	var lyricsKind: LyricsKind {
		let l = tags.first("LYRICS", "UNSYNCEDLYRICS")
		if l.isEmpty { return tags.first("LYRICS_LANGUAGE").lowercased() == "zxx" ? .instr : .none }
		if l.lowercased().contains("[instrumental:true]") || l.range(of: #"\[\d\d:\d\d\.\d\d\][\[(]\s*instrumental\s*[\])]"#, options: [.regularExpression, .caseInsensitive]) != nil { return .instr }
		if l.range(of: #"\[\d\d:\d\d\.\d\d\]"#, options: .regularExpression) != nil { return .lrc }
		return .txt
	}
	var channelsLabel: String { info.channels == 1 ? "Mono" : info.channels == 2 ? "Stereo" : "\(info.channels)ch" }
	var formatHelp: String { formatLabel.contains("/") ? "Sample rate in kHz / bit depth" : "Sample rate in kHz" }
	var formatLabel: String {
		let r = Double(info.sampleRate) / 1000
		return "\(r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r))/\(info.bits == 0 ? 16 : info.bits)"
	}
}

struct Cover: Identifiable { var width: Int; var height: Int; var data: Data; var embedded: Bool; var id: Int { data.hashValue } }

enum ArtType: UInt32, CaseIterable, Identifiable {
	case front = 3, back = 4, leaflet = 5, media = 6
	var id: UInt32 { rawValue }
	var label: String { ["Front Cover", "Back Cover", "Leaflet", "Media"][Int(rawValue) - 3] }
}

struct Album: Identifiable {
	var url: URL
	var tracks: [Track]
	var cover: Cover?
	var artwork: [UInt32: [Cover]] = [:]
	var id: String { url.path }
	var name: String { url.lastPathComponent }
	var minCover = 1000
	var full = true   // false: from the summary cache (thumbnail cover, no artwork)

	private func all(_ k: String) -> [String] { tracks.map { $0.tags.first(k) } }
	private func first(_ keys: String...) -> String {
		for t in tracks { for k in keys { let v = t.tags.first(k); if !v.isEmpty { return v } } }
		return ""
	}

	var artist: String { first("ALBUMARTIST", "ARTIST") }
	var title: String { first("ALBUM").isEmpty ? name : first("ALBUM") }
	var year: String { String((first("ALBUM_RELEASE_YEAR", "RELEASEDATE", "DATE", "YEAR")).prefix(4)) }
	var edition: String { first("ALBUM_EDITION") }
	/// web `year` (DATE / YEAR) for the card and the inspector; `year` above is the release year of the list view.
	var dateYear: String { String(first("DATE", "YEAR").prefix(4)) }
	/// web `edition`: the card's third line, VERSION · CATALOGNUMBER.
	var editionLine: String { [first("VERSION"), first("CATALOGNUMBER")].filter { !$0.isEmpty }.joined(separator: " · ") }
	var masterYear: String { String(first("ALBUM_MASTER_YEAR", "ORIGINAL YEAR", "ORIGINALDATE").prefix(4)) }
	var format: String { first("ALBUM_FORMAT") }
	var catalog: String { first("CATALOGNUMBER", "CATALOG NUMBER", "CATALOGNUM", "LABELNO") }
	var version: String { first("VERSION") }
	var country: String { first("DISCOGS_ALBUM_RELEASECOUNTRY", "COUNTRY", "MUSICBRAINZ_ALBUM_RELEASECOUNTRY") }
	var discogsID: String { first("DISCOGS_RELEASE_ID") }
	/// The digits of DISCOGS_MASTER_ID (`m<number>`), empty without a master (ADR 0082).
	var masterID: String { first("DISCOGS_MASTER_ID").trimmingCharacters(in: CharacterSet(charactersIn: "mM ")) }
	var mbid: String { first("MUSICBRAINZ_ALBUMID", "MUSICBRAINZ ALBUM ID") }
	var albumDR: String { first("ALBUM_DR") }
	var subtitle: String {
		[edition.isEmpty ? nil : edition, format.isEmpty ? nil : format, catalog.isEmpty ? nil : "(\(catalog))"].compactMap { $0 }.joined(separator: " ")
	}
	var versionLine: String {
		var s = [year, format].filter { !$0.isEmpty }.joined(separator: " ")
		if !catalog.isEmpty { s += " (\(catalog))" }
		return s
	}
	var lrc: Int { tracks.filter { $0.lyricsKind == .lrc }.count }
	var txt: Int { tracks.filter { $0.lyricsKind == .txt }.count }
	var instr: Int { tracks.filter { $0.lyricsKind == .instr }.count }
	var duration: Double { tracks.reduce(0) { $0 + $1.info.duration } }

	var coverTooSmall: Bool { minCover > 0 && (cover == nil || cover!.width < minCover || cover!.height < minCover) }   // 0 turns the check off

	// MARK: steps

	func missingTracks(_ s: StepID) -> [Track] {
		switch s {
		case .dr: return tracks.filter { $0.dr.isEmpty }
		case .replaygain: return tracks.filter { $0.tags.first("REPLAYGAIN_ALBUM_GAIN").isEmpty }
		case .fingerprints: return tracks.filter { $0.fingerprint.isEmpty }
		case .tags: return tracks.filter { !tagsComplete($0) }
		case .lyrics: return tracks.filter { $0.lyricsKind == .none }
		case .filenames: return tracks.filter { t in guard let n = Naming.blissName(t.tags) else { return true }; return !Naming.sameName(n, t.url.lastPathComponent) }
		}
	}

	static let requiredTags = ["ARTIST", "ALBUMARTIST", "TITLE", "ALBUM", "TRACKNUMBER", "DISCNUMBER", "ALBUM_FORMAT"]

	func tagsComplete(_ t: Track) -> Bool {
		Self.requiredTags.allSatisfy { !t.tags.first($0).isEmpty }
			&& !t.tags.first("CATALOGNUMBER", "CATALOG NUMBER", "CATALOGNUM", "LABELNO").isEmpty
			&& !t.tags.first("DATE", "YEAR").isEmpty && !t.tags.first("VERSION").isEmpty
	}

	func state(_ s: StepID) -> StepState {
		let miss = missingTracks(s).count
		switch s {
		case .tags:
			if discogsID.isEmpty || miss > 0 { return .open }
			return coverTooSmall ? .partial : .done
		case .lyrics:
			if miss > 0 { return .open }
			return txt > 0 ? .partial : .done
		default: return miss == 0 ? .done : .open
		}
	}

	var states: [StepState] { StepID.allCases.map(state) }
	var doneCount: Int { states.filter { $0 != .open }.count }

	/// app.py album_issues: one line each, recomputed from the tags. Without a Discogs release ID that is the only
	/// line (ADR 0039); errors first.
	var issues: [Issue] {
		let n = tracks.count
		let t0 = tracks.first?.tags ?? [:]
		if t0.first("DISCOGS_RELEASE_ID").isEmpty { return [Issue(level: .error, text: "Add a Discogs release ID before running fixes.", action: "search")] }
		var out: [Issue] = []
		let level: [(label: String, keys: [String], action: String, required: Bool)] = [
			("Discogs release ID", ["DISCOGS_RELEASE_ID"], "search", true),
			("album artist", ["ALBUMARTIST"], "album", true),
			("catalog number", ["CATALOGNUMBER", "CATALOG NUMBER", "CATALOGNUM", "LABELNO"], "album", true),
			("album format", ["ALBUM_FORMAT"], "album", true),
			("edition", ["ALBUM_EDITION"], "album", false),
			("MusicBrainz release ID", ["MUSICBRAINZ_ALBUMID", "MUSICBRAINZ ALBUM ID"], "album", false),
			("album artist override", ["ALBUM_ARTIST_OVERRIDE"], "album", false),
			("album title override", ["ALBUM_TITLE_OVERRIDE"], "album", false),
		]
		let missingText = ["album artist": "Set the album artist.", "catalog number": "Add a catalog number (enter 'none' if the release has none).", "album format": "Set the album format (for example CD, SACD, Vinyl)."]
		for l in level {
			let values = tracks.map { t in l.keys.lazy.map { t.tags.first($0) }.first { !$0.isEmpty } ?? "" }
			let m = values.filter(\.isEmpty).count
			let lv: Issue.Level = l.label == "Discogs release ID" ? .error : .warn
			if l.required, m > 0, !(l.label == "Discogs release ID" && m == n) {
				out.append(Issue(level: lv, text: m == n ? (missingText[l.label] ?? "No track has a \(l.label).") : "\(m) of \(n) tracks have no \(l.label).", action: l.action))
			}
			let filled = values.filter { !$0.isEmpty }
			if Set(filled).count > 1 {
				out.append(Issue(level: lv, text: "The files disagree on the \(l.label) (\(Set(filled).count) different values); it is read from the first file only.", action: l.action))
			} else if !l.required, !filled.isEmpty, filled.count < n {
				out.append(Issue(level: .warn, text: "The \(l.label) is set on only \(filled.count) of \(n) tracks; it is read from the first file only.", action: l.action))
			}
		}
		for (key, what) in [("DISCNUMBER", "a disc number"), ("TRACKNUMBER", "a track number"), ("TITLE", "a title"), ("ARTIST", "an artist")] {
			let m = tracks.filter { $0.tags.first(key).isEmpty }.count
			if m > 0 { out.append(Issue(level: .warn, text: Self.countText(m, n, what), action: "tracks")) }
		}
		let numbers = tracks.compactMap { t -> String? in
			let d = t.tags.first("DISCNUMBER"), k = t.tags.first("TRACKNUMBER")
			return d.isEmpty || k.isEmpty ? nil : "\(d.split(separator: "/").first ?? "")|\(k.split(separator: "/").first ?? "")"
		}
		let dup = Dictionary(grouping: numbers, by: { $0 }).values.filter { $0.count > 1 }.count
		if dup > 0 { out.append(Issue(level: .warn, text: "\(dup) disc/track number\(dup == 1 ? " is" : "s are") used by more than one file.", action: "tracks")) }
		if coverTooSmall {
			out.append(Issue(level: .ingest, text: cover.map { "Cover is \($0.width)x\($0.height), below the minimum \(minCover)x\(minCover)." } ?? "The album has no cover.", action: "cover"))
		}
		return out.filter { $0.level == .error } + out.filter { $0.level != .error }
	}

	static func countText(_ m: Int, _ n: Int, _ what: String) -> String {
		let noun = what.split(separator: " ", maxSplits: 1).last.map(String.init) ?? what
		if m == n { return n > 1 ? "No track has \(what)." : "The track has no \(noun)." }
		return "\(m) of \(n) tracks \(m == 1 ? "has" : "have") no \(noun)."
	}


	var status: Status {
		if issues.contains(where: { $0.level == .error || $0.level == .warn }) { return .needs }
		let s = states
		return StepID.allCases.allSatisfy { $0.optional || s[$0.rawValue] != .open } ? .fixed : .ready
	}

	var canMove: Bool { status == .fixed && !issues.contains { $0.level == .ingest } }

	var missing: [Missing] {
		let labels = ["No DR", "No ReplayGain", "No fingerprints", "Tags incomplete", "No lyrics", "Names differ"]
		return StepID.allCases.compactMap { s in
			if s == .tags && !discogsID.isEmpty && missingTracks(s).isEmpty { return nil }
			let m = missingTracks(s)
			if s == .tags && m.isEmpty { return nil }
			guard !m.isEmpty else { return nil }
			return Missing(step: s, label: labels[s.rawValue], count: m.count, of: tracks.count, tracks: m.prefix(12).map(\.title))
		}
	}

	var pillText: String {
		if status == .ready, let m = missing.first(where: { !$0.step.optional }) {
			let extra = missing.filter { !$0.step.optional }.count - 1
			return extra > 0 ? "\(m.label) +\(extra)" : m.label
		}
		return status.label
	}

	var multiDisc: Bool { tracks.contains { (Int($0.disc) ?? 1) > 1 } || tracks.contains { (Int($0.tags.first("DISCTOTAL", "TOTALDISCS")) ?? 1) > 1 } }
}

/// The flag emoji of a release country (web lib/flags.ts): Discogs writes names ("UK", "Germany", "Europe"),
/// MusicBrainz ISO codes ("DE", "XE"). Empty when there is none (Worldwide, Scandinavia, ...).
enum Flag {
	static let alias: [String: String] = [
		"uk": "GB", "uk & ireland": "GB", "uk & europe": "GB", "us": "US", "usa": "US", "us & canada": "US", "europe": "EU", "xe": "EU",
		"ussr": "RU", "russia": "RU", "czech republic": "CZ", "czechia": "CZ", "south korea": "KR", "korea": "KR", "taiwan": "TW",
		"hong kong": "HK", "vietnam": "VN", "bosnia & herzegovina": "BA", "trinidad & tobago": "TT", "serbia & montenegro": "RS",
		"east germany": "DE", "west germany": "DE", "germany, austria, & switzerland": "DE", "netherlands": "NL",
	]
	static let byName: [String: String] = {
		let en = Locale(identifier: "en")
		var m: [String: String] = [:]
		for r in Locale.Region.isoRegions where r.identifier.count == 2 { if let n = en.localizedString(forRegionCode: r.identifier) { m[n.lowercased()] = r.identifier } }
		return m
	}()

	static func code(_ country: String) -> String {
		let c = country.trimmingCharacters(in: .whitespaces)
		if c.isEmpty { return "" }
		if let a = alias[c.lowercased()] { return a }
		if c.count == 2, c.allSatisfy({ $0.isASCII && $0.isLetter }) { return c.uppercased() }
		return byName[c.lowercased()] ?? ""
	}

	static func of(_ country: String) -> String {
		let c = code(country)
		guard c.count == 2 else { return "" }
		return String(String.UnicodeScalarView(c.unicodeScalars.compactMap { Unicode.Scalar(0x1F1A5 + $0.value) }))
	}
}

// MARK: discovery

enum Scanner {
	static let discDir = try! NSRegularExpression(pattern: #"^(disc|cd)\s*\d+$"#, options: .caseInsensitive)

	static func isDisc(_ n: String) -> Bool { discDir.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil }

	static func flacs(in dir: URL, recursive: Bool, discsOnly: Bool = false) -> [URL] {
		let fm = FileManager.default
		var out: [URL] = []
		guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
		for u in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
			let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
			if isDir {
				if recursive { out += flacs(in: u, recursive: true) }
				else if discsOnly && isDisc(u.lastPathComponent) { out += flacs(in: u, recursive: true) }   // all audio below a disc folder (layout.py)
			} else if !discsOnly, u.pathExtension.lowercased() == "flac" { out.append(u) }   // discsOnly: only what is in disc folders
		}
		return out
	}

	/// Staging: every top-level folder is one album (ADR 0076). Library: every folder with FLACs of its own, its
	/// `Disc N` / `CD N` folders counted as part of it; a disc folder directly in the root is an album of its own.
	static func albumFolders(root: URL, staging: Bool) -> [(URL, [URL])] {
		let fm = FileManager.default
		var out: [(URL, [URL])] = []
		if staging {
			let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
			for u in items where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
				let f = flacs(in: u, recursive: true)
				if !f.isEmpty { out.append((u, f)) }
			}
		} else {
			func walk(_ d: URL, top: Bool) {
				let own = flacs(in: d, recursive: false)
				let discs = top ? [] : flacs(in: d, recursive: false, discsOnly: true)
				if !own.isEmpty || !discs.isEmpty { out.append((d, discs)) }
				let items = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
				for u in items where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && (top || !isDisc(u.lastPathComponent)) { walk(u, top: false) }
			}
			walk(root, top: true)
		}
		return out.sorted { $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending }
	}

	static func loadAlbum(folder: URL, files: [URL], minCover: Int) -> Album? {
		var tracks: [Track] = []
		var pic: Picture?
		var art: [UInt32: [Cover]] = [:]
		for f in files {
			guard let flac = try? FlacFile(url: f) else { continue }
			tracks.append(Track(url: f, tags: flac.tags, info: flac.info))
			if pic == nil { pic = flac.pictures.first(where: { $0.type == 3 }) ?? flac.pictures.first }
			for p in flac.pictures where ArtType(rawValue: p.type) != nil {
				if art[p.type]?.contains(where: { $0.data == p.data }) == true { continue }
				if p.type == 3, art[3]?.isEmpty == false { continue }
				if let sz = ImageSize.of(p.data) { art[p.type, default: []].append(Cover(width: sz.0, height: sz.1, data: p.data, embedded: true)) }
			}
		}
		guard !tracks.isEmpty else { return nil }
		tracks.sort {
			let a = (Int($0.disc) ?? 1, Int($0.number) ?? 0, $0.url.path), b = (Int($1.disc) ?? 1, Int($1.number) ?? 0, $1.url.path)
			return a < b
		}
		var cover: Cover?
		if let p = pic, let size = ImageSize.of(p.data) { cover = Cover(width: size.0, height: size.1, data: p.data, embedded: true) }
		else if let c = folderImage(folder), let d = try? Data(contentsOf: c), let size = ImageSize.of(d) { cover = Cover(width: size.0, height: size.1, data: d, embedded: false) }
		var a = Album(url: folder, tracks: tracks, cover: cover)
		a.minCover = minCover
		a.artwork = art
		return a
	}

	static func folderImage(_ dir: URL) -> URL? {
		let names = ["cover", "folder", "front", "album"]
		for n in names { for e in ["jpg", "jpeg", "png"] {
			let u = dir.appendingPathComponent("\(n).\(e)")
			if FileManager.default.fileExists(atPath: u.path) { return u }
		} }
		return nil
	}
}
