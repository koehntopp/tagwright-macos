import Foundation
import Darwin

/// Port of library/index.py: what is on disk, remembered so that a pass over a settled library only stats
/// directories (ADR 0037). Kept as JSON in Application Support instead of SQLite (about 11k files, rewritten
/// atomically after a pass). Paths are "/"-separated and relative to the library root; the root itself is "".
final class LibIndex {
	struct Row: Codable { var mtime: Int64, size: Int64, tags: [String: String], error: String, changedAt: Double }
	private struct Store: Codable { var root: String; var dirs: [String: Int64]; var files: [String: Row] }

	private let lock = NSRecursiveLock()
	private let url: URL
	private(set) var root = ""
	private var dirs: [String: Int64] = [:]
	private var files: [String: Row] = [:]
	private var children: [String: Set<String>] = [:]   // dir -> subdirs (full paths)
	private var byDir: [String: Set<String>] = [:]      // dir -> file names
	private var dirty = false

	init(url: URL) {
		self.url = url
		if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Store.self, from: d) {
			root = s.root; dirs = s.dirs; files = s.files
			for p in dirs.keys where !p.isEmpty { children[Self.parent(p), default: []].insert(p) }
			for p in files.keys { byDir[Self.parent(p), default: []].insert(Self.name(p)) }
		}
	}

	static func parent(_ p: String) -> String { p.lastIndex(of: "/").map { String(p[..<$0]) } ?? "" }
	static func name(_ p: String) -> String { p.lastIndex(of: "/").map { String(p[p.index(after: $0)...]) } ?? p }
	private func sync<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

	/// Another folder: nothing of the old one applies.
	func use(root r: String) { sync { if root != r { dirs = [:]; files = [:]; children = [:]; byDir = [:]; root = r; dirty = true } } }

	func save() {
		sync {
			guard dirty else { return }
			let s = Store(root: root, dirs: dirs, files: files)
			guard let d = try? JSONEncoder().encode(s) else { return }
			try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			if (try? d.write(to: url, options: .atomic)) != nil { dirty = false }
		}
	}

	// directories
	func dirMtime(_ p: String) -> Int64? { sync { dirs[p] } }
	func setDir(_ p: String, _ m: Int64) { sync { dirs[p] = m; if !p.isEmpty { children[Self.parent(p), default: []].insert(p) }; dirty = true } }
	func childDirs(_ p: String) -> [String] { sync { Array(children[p] ?? []) } }
	func forgetDirs(_ ps: Set<String>) { sync { for p in ps where dirs[p] != nil { dirs[p] = -1 }; dirty = true } }
	func forgetTree(_ p: String) { sync { for k in dirs.keys where k == p || p.isEmpty || k.hasPrefix(p + "/") { dirs[k] = -1 }; dirty = true } }
	@discardableResult func deleteTree(_ p: String) -> Int {
		sync {
			var n = 0
			for k in Array(files.keys) where Self.parent(k) == p || k.hasPrefix(p + "/") { files[k] = nil; n += 1 }
			for k in Array(dirs.keys) where k == p || k.hasPrefix(p + "/") { dirs[k] = nil; children[Self.parent(k)]?.remove(k); children[k] = nil }
			for k in Array(byDir.keys) where k == p || k.hasPrefix(p + "/") { byDir[k] = nil }
			dirty = true
			return n
		}
	}

	// files
	func filesIn(_ d: String) -> [String: Row] { sync { Dictionary(uniqueKeysWithValues: (byDir[d] ?? []).compactMap { n in files[d.isEmpty ? n : d + "/" + n].map { (n, $0) } }) } }
	func upsert(_ p: String, mtime: Int64, size: Int64, tags: [String: String], error: String, changedAt: Double) {
		sync { files[p] = Row(mtime: mtime, size: size, tags: tags, error: error, changedAt: changedAt); byDir[Self.parent(p), default: []].insert(Self.name(p)); dirty = true }
	}
	func deleteFile(_ p: String) { sync { files[p] = nil; byDir[Self.parent(p)]?.remove(Self.name(p)); dirty = true } }
	/// A file the library moved itself: keep its tags and changedAt.
	func moveFile(_ old: String, _ new: String) {
		sync {
			let row = files[old]
			deleteFile(old)
			if let row { files[new] = row; byDir[Self.parent(new), default: []].insert(Self.name(new)) }
		}
	}

	func items() -> [LibPlanner.Item] { sync { files.keys.sorted().map { LibPlanner.Item(path: $0, tags: files[$0]!.tags) } } }
	func errors() -> [String: String] { sync { files.compactMapValues { $0.error.isEmpty ? nil : $0.error } } }
	func changedAt() -> [String: Double] { sync { files.mapValues(\.changedAt) } }
	func mtimes() -> [String: Int64] { sync { files.mapValues(\.mtime) } }
	var hasFiles: Bool { sync { !files.isEmpty } }

	/// album folder -> its files' (path inside the album, mtime, size). A `Disc N` folder belongs to its parent.
	func albums() -> [String: [(path: String, row: Row)]] {
		sync {
			var out: [String: [(String, Row)]] = [:]
			for (p, r) in files {
				let d = Self.parent(p), n = Self.name(d)
				let album = Scanner.isDisc(n) && d.contains("/") ? Self.parent(d) : d
				out[album, default: []].append((p, r))
			}
			return out.mapValues { $0.sorted { $0.0 < $1.0 } }
		}
	}

	/// (album artists, albums, tracks)
	func counts() -> (artists: Int, albums: Int, tracks: Int) {
		sync {
			var albums = Set<String>(), artists = Set<String>()
			for (p, r) in files {
				let d = Self.parent(p)
				albums.insert(Scanner.isDisc(Self.name(d)) && d.contains("/") ? Self.parent(d) : d)
				let a = (r.tags["ALBUMARTIST"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
				if !a.isEmpty { artists.insert(a) }
			}
			return (artists.count, albums.count, files.count)
		}
	}
}

extension FlacFile {
	/// Tags, stream info and the front cover's size without loading picture data (an index pass must not pull the
	/// embedded art of a whole library over the network).
	static func quickRead(_ url: URL) throws -> (tags: Tags, info: StreamInfo, cover: (Int, Int)?) {
		let h = try FileHandle(forReadingFrom: url)
		defer { try? h.close() }
		guard let magic = try h.read(upToCount: 4), magic == Data("fLaC".utf8) else { throw FlacError.notFlac(url.lastPathComponent) }
		var f = FlacFile(url: url, empty: true)
		var cover: (Int, Int)?
		var coverType: UInt32 = 99
		var last = false
		while !last {
			guard let head = try h.read(upToCount: 4), head.count == 4 else { throw FlacError.truncated(url.lastPathComponent) }
			last = head[0] & 0x80 != 0
			let type = head[0] & 0x7f
			let len = Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
			switch type {
			case 0, 4:
				let body = len > 0 ? (try h.read(upToCount: len) ?? Data()) : Data()
				guard body.count == len else { throw FlacError.truncated(url.lastPathComponent) }
				if type == 0 { f.parseStreamInfoPublic(body) } else { f.parseCommentsPublic(body) }
			case 6:
				let pos = try h.offset()
				if let head = try h.read(upToCount: min(len, 4096)), let (t, w, hh) = FlacFile.pictureHeader(head), t == 3 || (cover == nil && coverType != 3) {
					coverType = t; cover = (w, hh)
				}
				try h.seek(toOffset: pos + UInt64(len))
			default: try h.seek(toOffset: try h.offset() + UInt64(len))
			}
		}
		return (f.tags, f.info, cover)
	}

	static func pictureHeader(_ b: Data) -> (UInt32, Int, Int)? {
		let b = [UInt8](b)
		var i = 0
		func u32() -> Int? { guard i + 4 <= b.count else { return nil }; defer { i += 4 }; return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
		guard let t = u32(), let ml = u32() else { return nil }; i += ml
		guard let dl = u32() else { return nil }; i += dl
		guard let w = u32(), let h = u32() else { return nil }
		return (UInt32(t), w, h)
	}
}
