import AppKit
import CryptoKit

/// Port of pipeline/artwork.py: embedded artwork by type, per disc (ADR 0098), the box-set cover (ADR 0099), and the
/// cover files beside an album in the library (ADR 0091, 0098). The front cover is `folder.jpg`; back, leaflet and
/// media images go into `Artwork/`, numbered across types (`01 back.jpg`, `02 booklet-01.jpg`, `03 disc.jpg`).
/// Identical pictures once; non-JPEG becomes JPEG.
enum Artwork {
	static let types: [UInt32] = [3, 4, 5, 6]
	/// Pseudo-type of the box-set cover: a front picture described `Box set`, never written as a picture type.
	static let box: UInt32 = 100
	static let boxDesc = "Box set"
	/// The copy of folder.jpg inside Artwork/, so the folder holds the whole set (ADR 0105).
	static let frontCopy = "Artwork/00 front.jpg"

	static func isBox(_ p: Picture) -> Bool {
		p.type == 3 && p.desc.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(boxDesc) == .orderedSame
	}
	/// The group a picture belongs to: its type, or `box` for the box-set cover.
	static func kind(_ p: Picture) -> UInt32 { isBox(p) ? box : p.type }

	/// The disc of a file: the leading number of DISCNUMBER, else disc 1 (ADR 0098).
	static func disc(_ discNumber: String) -> Int {
		Int(discNumber.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) ?? 1
	}

	/// The distinct pictures of the files (or of one disc's files) by group (0 = untyped, `box`), in file order then
	/// picture order.
	static func read(_ files: [URL], disc only: Int? = nil) -> [UInt32: [Picture]] {
		var out: [UInt32: [Picture]] = [0: [], 3: [], 4: [], 5: [], 6: [], box: []], seen: [UInt32: Set<String>] = [:]
		for f in files {
			guard let a = try? AudioFile(url: f) else { continue }
			if let only, disc(a.tags.first("DISCNUMBER")) != only { continue }
			for p in a.pictures where !p.data.isEmpty {
				let g = kind(p)
				guard out[g] != nil else { continue }
				if seen[g, default: []].insert(SHA256.hash(data: p.data).description).inserted { out[g]!.append(p) }
			}
		}
		return out
	}

	/// The front cover: type 3, else an untyped picture from an older tagger (ADR 0090).
	static func front(_ g: [UInt32: [Picture]]) -> Picture? { g[3]?.first ?? g[0]?.first }

	/// `folder.jpg` for the front (or `front`, ADR 0099; the box cover when there is no other), then the numbered
	/// `Artwork/` files.
	static func names(_ g: [UInt32: [Picture]], front given: Picture? = nil) -> [(String, Picture)] {
		var out: [(String, Picture)] = []
		if let f = given ?? front(g) ?? g[box]?.first { out += [("folder.jpg", f), (frontCopy, f)] }
		var index = 0
		for (type, stem) in [(UInt32(4), "back"), (5, "booklet"), (6, "disc")] {
			for (n, p) in (g[type] ?? []).enumerated() {
				index += 1
				let suffix = n > 0 || type == 5 ? String(format: "-%02d", n + 1) : ""
				out.append((String(format: "Artwork/%02d %@%@.jpg", index, stem, suffix), p))
			}
		}
		return out
	}

	/// The cover files of an album whose audio files sit in the folders of `byDir` (ADR 0098): every folder gets the
	/// set of its own files; when the album folder holds no audio (disc folders) it gets only folder.jpg. The album
	/// folder's folder.jpg is the box cover, else the first disc's front; a disc folder without a front of its own
	/// gets the box cover (ADR 0099).
	static func folderSets(_ albumDir: URL, _ byDir: [URL: [URL]]) -> [(URL, Picture)] {
		let top = albumDir.standardizedFileURL.path
		let dirs = byDir.keys.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
		let perDir = dirs.map { ($0, read(byDir[$0]!)) }
		let boxPic = perDir.lazy.compactMap { $0.1[box]?.first }.first
		var out: [(URL, Picture)] = [], firstFront: Picture?
		for (d, g) in perDir {
			let f = d.standardizedFileURL.path == top && boxPic != nil ? boxPic : front(g) ?? boxPic
			out += names(g, front: f).map { (d.appendingPathComponent($0.0), $0.1) }
			if firstFront == nil { firstFront = front(g) }
		}
		if !dirs.contains(where: { $0.standardizedFileURL.path == top }), let t = boxPic ?? firstFront {
			out.insert(contentsOf: [(albumDir.appendingPathComponent("folder.jpg"), t), (albumDir.appendingPathComponent(frontCopy), t)], at: 0)
		}
		return out
	}

	/// The audio files of an album by the folder they sit in (the album folder and its disc folders).
	static func byDir(_ albumDir: URL) -> [URL: [URL]] {
		let files = Scanner.flacs(in: albumDir, recursive: false) + Scanner.flacs(in: albumDir, recursive: false, discsOnly: true)
		return Dictionary(grouping: files) { $0.deletingLastPathComponent() }
	}

	/// The cover files a move of (source, destination) audio files into `albumDir` would create, relative to it.
	/// Nothing is written.
	static func plan(_ albumDir: URL, moves: [(URL, URL)]) -> [String] {
		var byDir: [URL: [URL]] = [:]
		for (src, dst) in moves { byDir[dst.deletingLastPathComponent(), default: []].append(src) }
		let base = albumDir.standardizedFileURL.path + "/"
		return folderSets(albumDir, byDir).map(\.0).filter { !FileManager.default.fileExists(atPath: $0.path) }
			.map { $0.standardizedFileURL.path.replacingOccurrences(of: base, with: "") }
	}

	/// Create the missing cover files of an album in place from its embedded art; existing files stay (ADR 0091).
	@discardableResult static func export(_ albumDir: URL, log: Log = { _ in }) -> [String] {
		writeAll(albumDir, folderSets(albumDir, byDir(albumDir)), overwrite: false, log: log)
	}

	/// Make a library album's cover files match its embedded art (ADR 0098): rewrite every file, delete folder.jpg
	/// and Artwork/ files no picture backs any more, and remove an emptied Artwork/ folder.
	@discardableResult static func rebuild(_ albumDir: URL, log: Log = { _ in }) -> [String] {
		let fm = FileManager.default
		let dirs = byDir(albumDir)
		let items = folderSets(albumDir, dirs)
		let wanted = Set(items.map(\.0.standardizedFileURL.path))
		for d in Set([albumDir] + Array(dirs.keys)) {
			let art = d.appendingPathComponent("Artwork")
			let stale = [d.appendingPathComponent("folder.jpg")] + ((try? fm.contentsOfDirectory(at: art, includingPropertiesForKeys: nil)) ?? [])
			for u in stale where !wanted.contains(u.standardizedFileURL.path) && fm.fileExists(atPath: u.path) {
				do { try fm.removeItem(at: u) } catch { log("could not remove \(u.lastPathComponent): \(error.localizedDescription)") }
			}
			if (try? fm.contentsOfDirectory(atPath: art.path))?.isEmpty == true { try? fm.removeItem(at: art) }
		}
		return writeAll(albumDir, items, overwrite: true, log: log)
	}

	private static func writeAll(_ base: URL, _ items: [(URL, Picture)], overwrite: Bool, log: Log) -> [String] {
		var written: [String] = []
		let prefix = base.standardizedFileURL.path + "/"
		for (dst, p) in items {
			if !overwrite && FileManager.default.fileExists(atPath: dst.path) { continue }
			var data = p.data
			if !data.starts(with: [0xff, 0xd8]), let rep = NSBitmapImageRep(data: data), let j = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) { data = j }
			do {
				try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
				try data.write(to: dst, options: overwrite ? .atomic : .withoutOverwriting)
				written.append(dst.standardizedFileURL.path.replacingOccurrences(of: prefix, with: ""))
			} catch { log("could not write \(dst.lastPathComponent): \(error.localizedDescription)") }
		}
		if !written.isEmpty { log("wrote \(written.count) artwork file(s) for \(base.lastPathComponent)") }
		return written
	}

	/// Whether writing `type` replaces this picture: the front replaces untyped pictures too, but never the box
	/// cover, and the box replaces only the box cover.
	static func replaced(_ p: Picture, by type: UInt32) -> Bool {
		type == 3 ? (p.type == 3 || p.type == 0) && !isBox(p) : kind(p) == type
	}

	/// Put `pictures` of one group into every file (or one disc's files, ADR 0098); other groups stay. A disc's own
	/// front goes first, the box cover after it (ADR 0099).
	static func write(_ files: [URL], type: UInt32, pictures: [Picture], disc only: Int? = nil) throws {
		for u in files {
			var f = try AudioFile(url: u)
			if let only, disc(f.tags.first("DISCNUMBER")) != only { continue }
			let keep = f.pictures.filter { !replaced($0, by: type) }
			let wanted = type == 3 ? pictures + keep : keep + pictures
			if wanted == f.pictures { continue }
			f.pictures = wanted
			try f.save()
		}
	}
}
