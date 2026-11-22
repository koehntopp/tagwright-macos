import Foundation

/// Port of library/template.py (ADR 0037, 0010): which tags make up the folders and the file name.
enum LibTemplate {
	static let palette: [(key: String, label: String)] = [
		("ALBUMARTIST", "Album artist"), ("ARTIST", "Artist"), ("ALBUM", "Album"), ("VERSION", "Version"),
		("ALBUM_VERSION", "Album + version"), ("ALBUM_EDITION", "Edition"), ("ALBUM_FORMAT", "Format"), ("CATALOGNUMBER", "Catalog #"),
		("DATE", "Year"), ("ORIGINALDATE", "Original year"), ("DISCNUMBER", "Disc"), ("TRACKNUMBER", "Track"), ("TITLE", "Title"),
		("DISCSUBTITLE", "Disc subtitle"),
	]
	static let formats = ["text", "num", "int", "year"]
	static let maxLevels = 4
	/// What the index stores per file: the palette (without the composite), what multi-disc detection reads, and
	/// what the CSV export and "In your library" need (ADR 0077, 0082).
	static let indexed: [String] = palette.map(\.key).filter { $0 != "ALBUM_VERSION" } + [
		"DISCTOTAL", "TOTALDISCS", "ALBUM_TITLE_OVERRIDE", "ALBUM_MASTER_TITLE", "ORIGINAL_TITLE", "ALBUM_DR", "RELEASEDATE",
		"DISCOGS_RELEASE_ID", "DISCOGS_MASTER_ID", "MUSICBRAINZ_ALBUMID", "SUBTITLE", "CATALOG NUMBER", "CATALOG_NUMBER", "CATALOGNO",
	]

	struct Chip: Codable, Equatable {
		var tag = "", text = "", fmt = "text", pad = 0, fallback = ""
		init(tag: String = "", text: String = "", fmt: String = "text", pad: Int = 0, fallback: String = "") { self.tag = tag; self.text = text; self.fmt = fmt; self.pad = pad; self.fallback = fallback }
		init(from d: Decoder) throws {
			let c = try d.container(keyedBy: K.self)
			tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""; text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
			fmt = try c.decodeIfPresent(String.self, forKey: .fmt) ?? "text"; pad = try c.decodeIfPresent(Int.self, forKey: .pad) ?? 0
			fallback = try c.decodeIfPresent(String.self, forKey: .fallback) ?? ""
		}
		enum K: String, CodingKey { case tag, text, fmt, pad, fallback }
	}
	typealias Level = [Chip]

	struct Template: Codable, Equatable {
		var folders: [Level]
		var discFolder: Level?
		var filename: Level
	}

	struct MissingTag: Error { var tag: String }
	struct EmptyName: Error {}

	static let `default` = Template(
		folders: [[Chip(tag: "ALBUMARTIST")], [Chip(tag: "ALBUM_VERSION")]],
		discFolder: [Chip(text: "Disc "), Chip(tag: "DISCNUMBER", fmt: "int")],
		filename: [Chip(tag: "DISCNUMBER", fmt: "num", pad: 2), Chip(text: "_"), Chip(tag: "TRACKNUMBER", fmt: "num", pad: 2), Chip(text: "_"), Chip(tag: "TITLE")])

	static func validate(_ t: Template) -> (errors: [String], warnings: [String]) {
		var errors: [String] = [], warnings: [String] = []
		var levels = t.folders.enumerated().map { ("folder level \($0.offset + 1)", $0.element) }
		if let d = t.discFolder { levels.append(("disc folder", d)) }
		levels.append(("file name", t.filename))
		if t.folders.isEmpty { errors.append("at least one folder level is needed") }
		if t.folders.count > maxLevels { errors.append("at most \(maxLevels) folder levels") }
		let keys = Set(palette.map(\.key))
		for (name, level) in levels {
			if level.isEmpty { errors.append("\(name) is empty") }
			for c in level {
				if !c.tag.isEmpty {
					if !keys.contains(c.tag) { errors.append("\(name): unknown tag \(c.tag)") }
					if !c.fallback.isEmpty, !keys.contains(c.fallback) { errors.append("\(name): unknown fallback tag \(c.fallback)") }
					if !formats.contains(c.fmt) { errors.append("\(name): unknown format \(c.fmt)") }
					if !(0...6).contains(c.pad) { errors.append("\(name): padding must be 0 to 6") }
				} else if c.text.isEmpty || c.text.range(of: #"[/\\:*?"<>|\x00-\x1f]"#, options: .regularExpression) != nil {
					errors.append("\(name): text must be non-empty without / \\ : * ? \" < > |")
				}
			}
			if !level.isEmpty, !level.contains(where: { !$0.tag.isEmpty }) { errors.append("\(name) needs at least one tag") }
		}
		let tags = Set(t.filename.map(\.tag))
		if !tags.contains("TITLE") { warnings.append("the file name has no title: names are less readable") }
		if !(tags.contains("TRACKNUMBER") && tags.contains("TITLE")) { warnings.append("without track and title in the file name, tracks of one album can get the same name") }
		if !tags.contains("DISCNUMBER"), t.discFolder == nil { warnings.append("without a disc number in the file name or a disc folder, multi-disc albums collide") }
		return (errors, warnings)
	}

	private static func leading(_ v: String) -> String? {
		v.range(of: #"^\s*(\d+)"#, options: .regularExpression).map { String(v[$0]).trimmingCharacters(in: .whitespaces) }
	}

	private static func value(_ t: [String: String], _ tag: String) -> String {
		if tag == "ALBUM_VERSION" {
			let a = t["ALBUM"] ?? "", v = t["VERSION"] ?? ""
			return !a.isEmpty && !v.isEmpty && !a.contains(v) ? "\(a) \(v)" : a
		}
		return t[tag] ?? ""
	}

	static func render(_ level: Level, _ tags: [String: String]) throws -> String {
		var out = ""
		for c in level {
			if c.tag.isEmpty { out += c.text; continue }
			var raw = value(tags, c.tag).trimmingCharacters(in: .whitespacesAndNewlines)
			if raw.isEmpty, !c.fallback.isEmpty { raw = value(tags, c.fallback).trimmingCharacters(in: .whitespacesAndNewlines) }
			if raw.isEmpty { throw MissingTag(tag: c.tag) }
			switch c.fmt {
			case "num":
				let p = String(raw.split(separator: "/", omittingEmptySubsequences: false).first ?? "")
				out += String(repeating: "0", count: max(0, c.pad - p.count)) + p
			case "int":
				guard let n = leading(raw), let i = Int(n) else { throw MissingTag(tag: c.tag) }
				out += String(i)
			case "year": out += Naming.clean(String(raw.prefix(4)))
			default: out += Naming.clean(raw)
			}
		}
		return out
	}

	struct Target { var albumDir: [String]; var discDir: String; var filename: String }

	static func target(_ t: Template, _ tags: [String: String], suffix: String = ".flac") throws -> Target {
		let dir = try t.folders.map { try render($0, tags) }
		let disc = try t.discFolder.map { try render($0, tags) } ?? ""
		let stem = try render(t.filename, tags)
		if stem.isEmpty || dir.contains("") { throw EmptyName() }
		return Target(albumDir: dir, discDir: disc, filename: stem + suffix)
	}
}
