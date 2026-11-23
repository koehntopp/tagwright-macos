import Foundation

/// Port of library/executor.py: moving the files (ADR 0037). Nothing is overwritten or merged; case-only changes go
/// through a temporary name; an existing folder that differs only in case is renamed in place; sidecar files follow
/// when all FLACs of a folder go to one place; emptied folders are removed (macOS litter aside), never the root.
final class LibExecutor {
	struct Result {
		var done: [(old: String, new: String)] = []
		var sidecars = 0, removedDirs = 0
		var errors: [LibPlanner.Problem] = []
		var touched = Set<String>(), renamedDirs = Set<String>()
		var actions: [String] = []
	}
	static let litter = [".DS_Store", "Thumbs.db", "desktop.ini"]
	static func isLitter(_ n: String) -> Bool { litter.contains(n) || n.hasPrefix("._") }

	let root: String
	let shouldStop: () -> Bool
	private var renamed: [String: String] = [:]
	private(set) var result = Result()
	private let fm = FileManager.default
	init(root: URL, shouldStop: @escaping () -> Bool = { false }) { self.root = root.path; self.shouldStop = shouldStop }

	private func rel(_ p: String) -> String { p == root ? "" : String(p.dropFirst(root.count + 1)) }
	private func follow(_ p: String) -> String {
		for (old, new) in renamed where p == old || p.hasPrefix(old + "/") { return new + p.dropFirst(old.count) }
		return p
	}
	private func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue }

	private func renameCase(_ parent: String, _ wanted: String) {
		guard isDir(parent), let names = try? fm.contentsOfDirectory(atPath: parent) else { return }
		if names.contains(where: { LibPlanner.nfd($0) == LibPlanner.nfd(wanted) }) { return }
		for n in names where LibPlanner.nfd(n).lowercased() == LibPlanner.nfd(wanted).lowercased() {
			let src = parent + "/" + n, tmp = src + ".library-tmp", dst = parent + "/" + wanted
			guard (try? fm.moveItem(atPath: src, toPath: tmp)) != nil, (try? fm.moveItem(atPath: tmp, toPath: dst)) != nil else { return }
			result.renamedDirs.insert(rel(src)); result.touched.insert(rel(parent))
			if isDir(dst) { renamed[src] = dst }
			return
		}
	}

	private func moveOne(_ m: LibPlanner.Move) throws -> Bool {
		var src = follow(root + "/" + m.src)
		guard fm.fileExists(atPath: src) else { return false }   // vanished since the scan
		let dst = root + "/" + m.dst, dstDir = (dst as NSString).deletingLastPathComponent
		var parent = root
		for c in (m.dst as NSString).deletingLastPathComponent.split(separator: "/").map(String.init) { renameCase(parent, c); parent += "/" + c }
		src = follow(src)
		try fm.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
		if LibPlanner.nfd(src) == LibPlanner.nfd(dst) { return src != dst }
		if LibPlanner.nfd((src as NSString).deletingLastPathComponent) == LibPlanner.nfd(dstDir),
			LibPlanner.nfd((src as NSString).lastPathComponent).lowercased() == LibPlanner.nfd((dst as NSString).lastPathComponent).lowercased() {
			try fm.moveItem(atPath: src, toPath: src + ".library-tmp"); try fm.moveItem(atPath: src + ".library-tmp", toPath: dst); return true
		}
		if fm.fileExists(atPath: dst) { result.errors.append(.init(path: m.src, reason: "\(m.dst) already exists; nothing is overwritten")); return false }
		try fm.moveItem(atPath: src, toPath: dst)
		return true
	}

	func run(_ moves: [LibPlanner.Move]) -> Result {
		var sources: [String: [(String, String)]] = [:]
		for m in moves {
			if shouldStop() { break }
			let oldDir = LibIndex.parent(m.src)
			do {
				if try moveOne(m) {
					result.done.append((m.src, m.dst)); sources[oldDir, default: []].append((m.src, m.dst))
					result.touched.formUnion([oldDir, LibIndex.parent(m.dst)])
				}
			} catch { result.errors.append(.init(path: m.src, reason: error.localizedDescription)) }
		}
		for (d, pairs) in sources { moveSidecars(d, pairs) }
		// ADR 0091: an album the watcher placed gets its cover files recreated from the embedded art (never replaced)
		for album in Set(result.done.map { m -> String in let d = LibIndex.parent(m.new); return Scanner.isDisc(LibIndex.name(d)) && d.contains("/") ? LibIndex.parent(d) : d }) {
			let dir = URL(fileURLWithPath: album.isEmpty ? root : root + "/" + album)
			result.sidecars += Artwork.export(dir).count
		}
		for d in sources.keys.sorted(by: { $0.filter { $0 == "/" }.count > $1.filter { $0 == "/" }.count }) { prune(d) }
		let albums = Set(result.done.map { LibIndex.parent($0.new) }).sorted()
		result.actions = albums.map { a in "moved \(result.done.filter { LibIndex.parent($0.new) == a }.count) file(s) to \(a)" }
		return result
	}

	private func moveSidecars(_ oldDir: String, _ pairs: [(String, String)]) {
		let abs = oldDir.isEmpty ? root : root + "/" + oldDir
		let newDirs = Set(pairs.map { LibIndex.parent($0.1) })
		guard newDirs.count == 1, isDir(abs), let names = try? fm.contentsOfDirectory(atPath: abs) else { return }
		if names.contains(where: { LibScanner.isMusic($0) || isDir(abs + "/" + $0) }) { return }   // FLACs stay, or subfolders
		let target = root + "/" + newDirs.first!
		for n in names where !Self.isLitter(n) {
			let dst = target + "/" + n
			if fm.fileExists(atPath: dst) { continue }
			if (try? fm.moveItem(atPath: abs + "/" + n, toPath: dst)) != nil { result.sidecars += 1 }
		}
	}

	private func prune(_ dir: String) {
		var path = dir.isEmpty ? root : root + "/" + dir
		while path != root, path.hasPrefix(root + "/"), isDir(path) {
			guard let names = try? fm.contentsOfDirectory(atPath: path), names.allSatisfy(Self.isLitter) else { return }
			do { for n in names { try fm.removeItem(atPath: path + "/" + n) }; try fm.removeItem(atPath: path) } catch { return }
			result.removedDirs += 1; result.touched.insert(rel(path))
			path = (path as NSString).deletingLastPathComponent
		}
	}
}
