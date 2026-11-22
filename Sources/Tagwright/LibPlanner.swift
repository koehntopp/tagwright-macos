import Foundation

/// Port of library/planner.py: files in, a plan out. Pure; nothing here touches the disk (ADR 0037).
enum LibPlanner {
	struct Item { var path: String; var tags: [String: String] }   // path relative to the library root, "/"-separated
	struct Move: Equatable { var src: String; var dst: String; var caseOnly: Bool }
	struct Problem: Equatable { var path: String; var reason: String }
	struct Plan { var moves: [Move] = [], unplaced: [Problem] = [], skipped: [Problem] = [], inPlace = 0 }

	static func nfd(_ s: String) -> String { s.decomposedStringWithCanonicalMapping }
	static func fold(_ parts: [String]) -> [String] { parts.map { nfd($0).lowercased() } }
	private static func leadingInt(_ v: String, _ d: Int = 0) -> Int {
		v.range(of: #"^\s*\d+"#, options: .regularExpression).flatMap { Int(v[$0].trimmingCharacters(in: .whitespaces)) } ?? d
	}

	/// DISCNUMBER above 1, or a total above 1 (`1/2`, DISCTOTAL, TOTALDISCS).
	static func isMultiDisc(_ t: [String: String]) -> Bool {
		let disc = t["DISCNUMBER"] ?? ""
		let parts = disc.split(separator: "/", omittingEmptySubsequences: false)
		let total = max(leadingInt(parts.count > 1 ? String(parts[1]) : ""), leadingInt(t["DISCTOTAL"] ?? ""), leadingInt(t["TOTALDISCS"] ?? ""))
		return leadingInt(disc, 1) > 1 || total > 1
	}

	static func suffix(_ path: String) -> String { let e = (path as NSString).pathExtension.lowercased(); return e.isEmpty ? ".flac" : "." + e }

	static func plan(_ items: [Item], _ template: LibTemplate.Template, hasDiscDirs: ([String]) -> Bool = { _ in false }) -> Plan {
		var result = Plan()
		var placed: [(Item, LibTemplate.Target)] = []
		for item in items.sorted(by: { $0.path < $1.path }) {
			do { placed.append((item, try LibTemplate.target(template, item.tags, suffix: suffix(item.path)))) }
			catch let e as LibTemplate.MissingTag { result.unplaced.append(Problem(path: item.path, reason: "\(e.tag) is empty")) }
			catch { result.unplaced.append(Problem(path: item.path, reason: "a name is empty after cleaning")) }
		}
		var spelling: [[String]: [String]] = [:]
		var multi = Set<[String]>()
		for (_, t) in placed { let k = fold(t.albumDir); if spelling[k] == nil { spelling[k] = t.albumDir } }
		for (item, t) in placed {
			let k = fold(t.albumDir)
			if multi.contains(k) { continue }
			if isMultiDisc(item.tags) || hasDiscDirs(spelling[k]!) { multi.insert(k) }
		}
		var taken: [[String]: String] = [:]
		for (item, t) in placed {
			let k = fold(t.albumDir)
			if spelling[k]! != t.albumDir {
				result.skipped.append(Problem(path: item.path, reason: "tags spell \(t.albumDir.joined(separator: "/")) differently from \(spelling[k]!.joined(separator: "/")); fix the tags"))
				continue
			}
			let parts = t.albumDir + (multi.contains(k) && !t.discDir.isEmpty ? [t.discDir] : []) + [t.filename]
			let dst = parts.joined(separator: "/"), claim = fold(parts)
			if let o = taken[claim], o != item.path { result.skipped.append(Problem(path: item.path, reason: "\(dst) is wanted by \(o) as well")); continue }
			taken[claim] = item.path
			if nfd(item.path) == nfd(dst) { result.inPlace += 1 }
			else { result.moves.append(Move(src: item.path, dst: dst, caseOnly: fold(item.path.split(separator: "/").map(String.init)) == claim)) }
		}
		return result
	}

	/// The album folders (as component arrays) that contain a `Disc N` folder.
	static func albumDirsWithDiscs(_ paths: [String]) -> Set<[String]> {
		var out = Set<[String]>()
		for p in paths {
			let c = p.split(separator: "/").map(String.init)
			if c.count >= 2, Scanner.isDisc(c[c.count - 2]) { out.insert(Array(c.dropLast(2))) }
		}
		return out
	}
}
