import Foundation

/// Stored album summaries (ADR 0067): tracks, tags and a small cover per album folder, so the board opens
/// without reading every FLAC. An entry is valid while its signature (path, mtime, size of every FLAC and of the
/// folder image) is unchanged. Artwork is not stored: a summary album has `full == false` and is read from disk
/// when it is selected or acted on.
final class Summaries: @unchecked Sendable {   // state behind `lock`
	static let version = 1
	static let thumbSize = 640

	private struct T: Codable { var path: String; var tags: Tags; var info: StreamInfo }
	private struct C: Codable { var w: Int; var h: Int; var thumb: Data; var embedded: Bool }
	private struct Entry: Codable { var sig: [String]; var tracks: [T]; var cover: C? }
	private struct Store: Codable { var version: Int; var albums: [String: Entry] }

	private let lock = NSLock()
	private let url: URL
	private var albums: [String: Entry] = [:]
	private var dirty = false

	init(url: URL) {
		self.url = url
		if let d = try? Data(contentsOf: url), let s = try? PropertyListDecoder().decode(Store.self, from: d), s.version == Self.version { albums = s.albums }
	}

	static func signature(folder: URL, files: [URL]) -> [String] {
		func stat(_ u: URL) -> String? {
			guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
			return "\(u.path)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(v.fileSize ?? -1)"
		}
		return files.compactMap(stat) + [Scanner.folderImage(folder).flatMap(stat) ?? ""]
	}

	/// The stored summary, if the files have not changed since it was written.
	func album(folder: URL, sig: [String], minCover: Int) -> Album? {
		lock.lock(); let e = albums[folder.path]; lock.unlock()
		guard let e, e.sig == sig else { return nil }
		var a = Album(url: folder, tracks: e.tracks.map { Track(url: URL(fileURLWithPath: $0.path), tags: $0.tags, info: $0.info) },
			cover: e.cover.map { Cover(width: $0.w, height: $0.h, data: $0.thumb, embedded: $0.embedded) })
		a.minCover = minCover
		a.full = false
		return a
	}

	func put(_ a: Album, sig: [String]) {
		let c = a.cover.flatMap { c in ImageSize.jpeg(c.data, max: Self.thumbSize, quality: 0.75).map { C(w: c.width, h: c.height, thumb: $0, embedded: c.embedded) } }
		// The board only asks whether a fingerprint exists; the value (several KiB per track) stays in the file.
		let e = Entry(sig: sig, tracks: a.tracks.map { t in
			var tags = t.tags
			for k in ["ACOUSTID_FINGERPRINT", "ACOUSTID FINGERPRINT"] where tags[k] != nil { tags[k] = ["(stored in file)"] }
			return T(path: t.url.path, tags: tags, info: t.info)
		}, cover: c)
		lock.lock(); albums[a.url.path] = e; dirty = true; lock.unlock()
	}

	/// Drops entries under `root` whose folder was not seen in the last scan.
	func prune(root: URL, keep: Set<String>) {
		let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
		lock.lock(); defer { lock.unlock() }
		for k in albums.keys where k.hasPrefix(prefix) && !keep.contains(k) { albums[k] = nil; dirty = true }
	}

	/// Encodes outside the lock: the store of a large library is over 100 MB.
	func save() {
		lock.lock()
		guard dirty else { lock.unlock(); return }
		let store = Store(version: Self.version, albums: albums); dirty = false
		lock.unlock()
		let enc = PropertyListEncoder(); enc.outputFormat = .binary
		try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		guard let d = try? enc.encode(store), (try? d.write(to: url, options: .atomic)) != nil else { lock.lock(); dirty = true; lock.unlock(); return }
	}

	private let saver = DispatchQueue(label: "tagwright.summaries", qos: .utility)
	/// Saves in the background, a few seconds later: one write for a burst of changes.
	func saveSoon() { saver.asyncAfter(deadline: .now() + 3) { [self] in save() } }
}
