import Foundation
import Darwin

/// Port of library/scanner.py: find what changed on disk with as few calls as possible (ADR 0037). A quick
/// pass stats every known directory and lists only those whose mtime changed; a full pass lists everything.
enum LibScanner {
	struct Stats { var listed = 0, skipped = 0, read = 0, removed = 0, interrupted = false }

	static func mtimeNS(_ path: String) -> (Int64, Int64)? {
		var st = stat()
		guard stat(path, &st) == 0 else { return nil }
		return (Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec), Int64(st.st_size))
	}

	static func isMusic(_ name: String) -> Bool { AudioFile.isAudio(name) }

	/// The indexed tags (first values, upper-case keys), plus _COVER "WxH"; an error message if unreadable.
	static func readTags(_ url: URL) -> ([String: String], String) {
		do {
			let r = try AudioFile.quickRead(url)
			var out: [String: String] = [:]
			for k in LibTemplate.indexed { if let v = r.tags[k]?.first, !v.isEmpty { out[k] = v } }
			if let c = r.cover { out["_COVER"] = "\(c.0)x\(c.1)" }
			return (out, "")
		} catch { return ([:], error.localizedDescription) }
	}

	static func scan(root: URL, index: LibIndex, now: Double, full: Bool, shouldStop: () -> Bool, progress: (String) -> Void) async -> Stats {
		var stats = Stats()
		var todo: [(rel: String, m: Int64, s: Int64)] = []
		var stack = [""]
		let fm = FileManager.default
		while let rel = stack.popLast() {
			if shouldStop() { stats.interrupted = true; return stats }
			let abs = rel.isEmpty ? root.path : root.path + "/" + rel
			guard let (mtime, _) = mtimeNS(abs) else { index.deleteTree(rel); continue }
			if !full, index.dirMtime(rel) == mtime { stats.skipped += 1; stack += index.childDirs(rel); continue }
			stats.listed += 1
			progress("listing \(rel.isEmpty ? "/" : rel)")
			guard let names = try? fm.contentsOfDirectory(atPath: abs) else { continue }
			var subdirs: [String] = [], found: [String: (Int64, Int64)] = [:]
			for n in names where !n.hasPrefix(".") {
				var st = stat()
				guard lstat(abs + "/" + n, &st) == 0 else { continue }
				if st.st_mode & S_IFMT == S_IFDIR { subdirs.append(n) }
				else if st.st_mode & S_IFMT == S_IFREG, isMusic(n) {
					found[n] = (Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec), Int64(st.st_size))
				}
			}
			let known = index.filesIn(rel)
			for n in Set(known.keys).subtracting(found.keys) { index.deleteFile(rel.isEmpty ? n : rel + "/" + n); stats.removed += 1 }
			for n in Set(index.childDirs(rel).map { LibIndex.name($0) }).subtracting(subdirs) { stats.removed += index.deleteTree(rel.isEmpty ? n : rel + "/" + n) }
			for (n, (m, s)) in found where known[n].map({ ($0.mtime, $0.size) != (m, s) }) ?? true { todo.append((rel.isEmpty ? n : rel + "/" + n, m, s)) }
			index.setDir(rel, mtime)   // the mtime from before the listing: a change during it shows up next time
			stack += subdirs.sorted().map { rel.isEmpty ? $0 : rel + "/" + $0 }
		}
		if !todo.isEmpty {
			progress("reading tags of \(todo.count) files")
			let root = root
			var i = 0
			while i < todo.count {
				if shouldStop() { stats.interrupted = true; break }
				let batch = Array(todo[i..<min(i + 32, todo.count)]); i += batch.count
				let results = await withTaskGroup(of: (Int, [String: String], String).self) { g -> [(Int, [String: String], String)] in
					for (j, t) in batch.enumerated() { g.addTask { let (tags, err) = readTags(root.appendingPathComponent(t.rel)); return (j, tags, err) } }
					return await g.reduce(into: []) { $0.append($1) }
				}
				for (j, tags, err) in results { index.upsert(batch[j].rel, mtime: batch[j].m, size: batch[j].s, tags: tags, error: err, changedAt: now); stats.read += 1 }
				progress("reading tags \(min(i, todo.count)) / \(todo.count)")
			}
		}
		return stats
	}
}
