import AppKit
import CryptoKit

/// Port of pipeline/artwork.py's sidecar export (ADR 0091): the embedded art of an album written beside it in the
/// library. The front cover is `folder.jpg`; back, leaflet and media images go into `Artwork/`, numbered across
/// types (`01 back.jpg`, `02 booklet-01.jpg`, `03 disc.jpg`). Identical pictures once; non-JPEG becomes JPEG; an
/// existing file is never replaced.
enum Artwork {
	static let types: [UInt32] = [3, 4, 5, 6]

	/// The distinct pictures of the files by type (0 = untyped), in file order then picture order.
	static func read(_ files: [URL]) -> [UInt32: [Picture]] {
		var out: [UInt32: [Picture]] = [0: [], 3: [], 4: [], 5: [], 6: []], seen: [UInt32: Set<String>] = [:]
		for f in files {
			guard let pics = try? AudioFile(url: f).pictures else { continue }
			for p in pics where out[p.type] != nil && !p.data.isEmpty {
				let key = SHA256.hash(data: p.data).description
				if seen[p.type, default: []].insert(key).inserted { out[p.type]!.append(p) }
			}
		}
		return out
	}

	/// `folder.jpg` for the front (an untyped picture when there is no type 3), then the numbered `Artwork/` files.
	static func names(_ g: [UInt32: [Picture]]) -> [(String, Picture)] {
		var out: [(String, Picture)] = []
		if let f = g[3]?.first ?? g[0]?.first { out.append(("folder.jpg", f)) }
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

	/// The sidecars an export into `target` would create; nothing is written.
	static func plan(_ g: [UInt32: [Picture]], target: URL) -> [String] {
		names(g).map(\.0).filter { !FileManager.default.fileExists(atPath: target.appendingPathComponent($0).path) }
	}

	@discardableResult static func export(_ g: [UInt32: [Picture]], target: URL, log: Log = { _ in }) -> [String] {
		var written: [String] = []
		for (name, p) in names(g) {
			let dst = target.appendingPathComponent(name)
			if FileManager.default.fileExists(atPath: dst.path) { continue }
			var data = p.data
			if !data.starts(with: [0xff, 0xd8]), let rep = NSBitmapImageRep(data: data), let j = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) { data = j }
			do {
				try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
				try data.write(to: dst, options: .withoutOverwriting)
				written.append(name)
			} catch { log("could not write \(name): \(error.localizedDescription)") }
		}
		if !written.isEmpty { log("wrote \(written.count) artwork file(s) for \(target.lastPathComponent)") }
		return written
	}
}
