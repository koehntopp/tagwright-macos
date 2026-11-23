import SwiftUI

/// Settings of the library watcher (ADR 0037): apply, cooldown, interval, sweep, template. Stored as JSON.
struct LibrarySettings: Codable, Equatable {
	var apply = false           // move files; off = report only (off by default in this port until the first report has been checked)
	var cooldown = 60.0         // seconds without any change before an album is acted on
	var interval = 120.0        // seconds between quick passes
	var sweepHours = 24.0       // a full pass (stats every file) at least this often
	var template = LibTemplate.default

	static func load() -> LibrarySettings {
		UserDefaults.standard.data(forKey: "librarySettings").flatMap { try? JSONDecoder().decode(LibrarySettings.self, from: $0) } ?? LibrarySettings()
	}
	func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "librarySettings") }
}

struct LibraryStatus {
	var phase = "starting"      // starting scanning planning moving waiting idle error
	var message = "", error = ""
	var artists = 0, albums = 0, tracks = 0
	var planned: [(from: String, to: String)] = []
	var waiting = 0
	var unplaced: [LibPlanner.Problem] = [], skipped: [LibPlanner.Problem] = []
	var recent: [(t: Date, text: String)] = []
	var lastScan: Date?, lastFull: Date?
	var nextWake: Date?
}

/// Port of library/watcher.py: keeps the library folder in the canonical layout. Each pass scans (cheaply), plans
/// and, with Apply on, moves what has settled. An album is left alone until nothing in it has changed for the
/// cooldown, so half-copied albums and tags that an editor is still writing are never acted on.
@MainActor final class LibraryWatcher: ObservableObject {
	@Published private(set) var status = LibraryStatus()
	@Published var settings = LibrarySettings.load() { didSet { if settings != oldValue { settings.save(); templateChanged = settings.template != oldValue.template; rescan() } } }
	/// Set while Tagwright itself moves an album into the library: the watcher does not move files meanwhile (ADR 0008).
	var exclusive = false
	/// After a move batch: the album folders files moved out of and into, absolute (from == to for renames inside one
	/// folder), so the UI can follow an open album (ADR 0037).
	var onMoved: (([(from: String, to: String)]) -> Void)?

	private let index: LibIndex
	private var root: URL?
	var rootPath: String { root?.path ?? "" }
	private var loop: Task<Void, Never>?
	private var wake: CheckedContinuation<Void, Never>?
	private var fullRequested = true
	private var templateChanged = false
	private var lastFull = Date.distantPast
	private var stopFlag = false

	init() {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tagwright")
		index = LibIndex(url: dir.appendingPathComponent("library-index.json"))
	}

	// MARK: control

	func setRoot(_ path: String) {
		let r = path.isEmpty ? nil : URL(fileURLWithPath: path)
		guard r != root else { return }
		root = r
		if let r { index.use(root: r.path) }
		fullRequested = true
		if r == nil { status = LibraryStatus(phase: "error", error: "The library folder is not set.") }
		if loop == nil { start() } else { poke() }
	}

	func start() {
		guard loop == nil else { return }
		loop = Task { [weak self] in
			while !Task.isCancelled {
				guard let self else { return }
				await self.cycle()
				await self.sleep(self.delay())
			}
		}
	}

	func rescan() { fullRequested = true; poke() }
	func poke() { wake?.resume(); wake = nil }
	/// Something inside this folder was changed by Tagwright (a tag, a cover): list it again at the next pass.
	func refresh(_ folder: URL) {
		guard let root, folder.path.hasPrefix(root.path) else { return }
		index.forgetTree(folder.path == root.path ? "" : String(folder.path.dropFirst(root.path.count + 1)))
		poke()
	}

	private func sleep(_ s: Double) async {
		await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
			wake = c
			Task { [weak self] in try? await Task.sleep(nanoseconds: UInt64(s * 1e9)); self?.poke() }
		}
	}

	private func delay() -> Double {
		if let w = status.nextWake, w > Date() { return max(1, min(settings.interval, w.timeIntervalSinceNow + 0.5)) }
		return settings.interval
	}

	private func note(_ s: String) { status.recent.insert((Date(), s), at: 0); if status.recent.count > 100 { status.recent.removeLast() }; AppLog.library(s) }

	// MARK: one pass

	func cycle() async {
		guard let root, FileManager.default.fileExists(atPath: root.path) else {
			status.phase = "error"; status.error = "The library folder is not set or does not exist."; status.message = ""; return
		}
		let cfg = settings
		let errs = LibTemplate.validate(cfg.template).errors
		if !errs.isEmpty { status.phase = "error"; status.error = "The path template is invalid: " + errs.joined(separator: "; "); status.message = ""; return }
		let now = Date()
		let full = fullRequested || now.timeIntervalSince(lastFull) >= cfg.sweepHours * 3600
		fullRequested = false
		status.phase = "scanning"; status.error = ""; status.message = "scanning" + (full ? " (full)" : "")
		let index = index
		let stats = await LibScanner.scan(root: root, index: index, now: now.timeIntervalSince1970, full: full, shouldStop: { Task.isCancelled }, progress: { [weak self] m in Task { @MainActor in self?.status.message = m } })
		if stats.interrupted { return }
		if full { lastFull = now; status.lastFull = now }
		let c = index.counts()
		status.phase = "planning"; status.message = "planning"; status.artists = c.artists; status.albums = c.albums; status.tracks = c.tracks; status.lastScan = now

		let items = index.items()
		let discs = LibPlanner.albumDirsWithDiscs(items.map(\.path))
		let plan = LibPlanner.plan(items, cfg.template, hasDiscDirs: { discs.contains($0) })
		let unreadable = index.errors()
		let unplaced = unreadable.map { LibPlanner.Problem(path: $0.key, reason: "unreadable: \($0.value)") }.sorted { $0.path < $1.path } + plan.unplaced.filter { unreadable[$0.path] == nil }
		let (ready, waiting, wake) = settle(plan.moves, now: now.timeIntervalSince1970, cooldown: cfg.cooldown)
		status.waiting = waiting.count
		status.nextWake = wake.map { Date(timeIntervalSince1970: $0) }
		status.unplaced = Array(unplaced.prefix(200)); status.skipped = Array(plan.skipped.prefix(200))
		status.planned = Array((ready + waiting).prefix(200)).map { ($0.src, $0.dst) }
		if cfg.apply, !ready.isEmpty, !exclusive { await execute(root, ready) }
		if cfg.apply, full, !exclusive { await afterFullPass(root, items) }
		status.phase = waiting.isEmpty ? "idle" : "waiting"
		status.message = waiting.isEmpty ? "" : "waiting for \(waiting.count) file(s) to settle"
		index.save()
	}

	/// A move waits while any file in its source or destination folder changed within the cooldown.
	private func settle(_ moves: [LibPlanner.Move], now: Double, cooldown: Double) -> ([LibPlanner.Move], [LibPlanner.Move], Double?) {
		let changed = index.changedAt(), mtimes = index.mtimes()
		var unsettled: [String: Double] = [:]
		for (p, c) in changed {
			let settles = max(c, Double(mtimes[p] ?? 0) / 1e9) + cooldown
			if settles > now { let f = LibIndex.parent(p); unsettled[f] = max(unsettled[f] ?? 0, settles) }
		}
		var ready: [LibPlanner.Move] = [], waiting: [LibPlanner.Move] = []
		var wake: Double?
		for m in moves {
			let until = max(unsettled[LibIndex.parent(m.src)] ?? 0, unsettled[LibIndex.parent(m.dst)] ?? 0)
			if until > now { waiting.append(m); wake = wake.map { min($0, until) } ?? until } else { ready.append(m) }
		}
		return (ready, waiting, wake)
	}

	private func execute(_ root: URL, _ moves: [LibPlanner.Move]) async {
		status.phase = "moving"; status.message = "moving \(moves.count) file(s)"
		let r = await Task.detached { LibExecutor(root: root, shouldStop: { Task.isCancelled }).run(moves) }.value
		for (o, n) in r.done { index.moveFile(o, n) }
		for d in r.renamedDirs { index.deleteTree(d) }
		index.forgetDirs(r.touched)
		r.actions.forEach(note)
		if r.sidecars > 0 { note("moved \(r.sidecars) other file(s) with their album") }
		if r.removedDirs > 0 { note("removed \(r.removedDirs) empty folder(s)") }
		for p in r.errors.prefix(20) { note("\(p.path): \(p.reason)") }
		status.nextWake = Date().addingTimeInterval(5)   // look again soon: the moves changed the folders
		if !r.done.isEmpty {
			func album(_ rel: String) -> String {
				let d = LibIndex.parent(rel), a = Scanner.isDisc(LibIndex.name(d)) && d.contains("/") ? LibIndex.parent(d) : d
				return a.isEmpty ? root.path : root.appendingPathComponent(a).path
			}
			let pairs = Set(r.done.map { "\(album($0.old))\n\(album($0.new))" }).sorted().map { p -> (from: String, to: String) in
				let x = p.components(separatedBy: "\n"); return (x[0], x[1])
			}
			onMoved?(pairs)
		}
	}

	/// The album folders (absolute, sorted) with a music folder that lacks folder.jpg or Artwork/00 front.jpg
	/// (ADR 0104, 0105); `items` are the index's files, relative to root.
	nonisolated static func lackingArt(root: URL, items: [LibPlanner.Item]) -> [URL] {
		var albums: [String: Set<String>] = [:]
		for i in items {
			let d = LibIndex.parent(i.path), a = Scanner.isDisc(LibIndex.name(d)) && d.contains("/") ? LibIndex.parent(d) : d
			albums[a, default: []].insert(d)
		}
		let fm = FileManager.default
		func dir(_ rel: String) -> URL { rel.isEmpty ? root : root.appendingPathComponent(rel) }
		return albums.keys.sorted().filter { a in
			!albums[a]!.allSatisfy { f in
				fm.fileExists(atPath: dir(f).appendingPathComponent("folder.jpg").path) && fm.fileExists(atPath: dir(f).appendingPathComponent(Artwork.frontCopy).path)
			}
		}.map(dir)
	}

	/// The full pass's housekeeping, with Apply on: write the missing cover files of every album with a music folder
	/// lacking folder.jpg or Artwork/00 front.jpg (ADR 0104, 0105), then remove empty folders (ADR 0103).
	private func afterFullPass(_ root: URL, _ items: [LibPlanner.Item]) async {
		var wrote = 0
		for dir in Self.lackingArt(root: root, items: items) {
			if Task.isCancelled || exclusive { return }
			let a = String(dir.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
			status.message = "writing cover files: \(a)"
			let n = await Task.detached { Artwork.export(dir).count }.value
			if n > 0 { wrote += 1; AppLog.library("wrote \(n) cover file(s) for \(a)") }
		}
		if wrote > 0 { note("wrote missing cover files for \(wrote) album(s)") }
		let gone = await Task.detached { LibExecutor.removeEmptyDirs(root: root, shouldStop: { Task.isCancelled }) }.value
		for d in gone { index.deleteTree(d) }
		if !gone.isEmpty { note("removed \(gone.count) empty folder(s) left behind") }
	}

	// MARK: reads for the UI

	/// What the template would do with one album of the index (nothing is changed): the album folder and the file names.
	func preview(_ t: LibTemplate.Template, album: String? = nil) -> (errors: [String], warnings: [String], album: String, albumDir: String, files: [(from: String, name: String, problem: String)]) {
		let (e, w) = LibTemplate.validate(t)
		guard e.isEmpty else { return (e, w, "", "", []) }
		var byDir: [String: [LibPlanner.Item]] = [:]
		for i in index.items() { byDir[LibIndex.parent(i.path), default: []].append(i) }
		let candidates = album.flatMap { byDir[$0] != nil ? [$0] : nil } ?? byDir.keys.sorted()
		var choice = candidates.first ?? "", plan = LibPlanner.plan(byDir[choice] ?? [], t)
		for d in candidates.prefix(200) { let p = LibPlanner.plan(byDir[d]!, t); if !p.moves.isEmpty || p.inPlace > 0 { choice = d; plan = p; break } }
		let wanted = Dictionary(plan.moves.map { ($0.src, $0.dst) }, uniquingKeysWith: { a, _ in a })
		let problems = Dictionary((plan.unplaced + plan.skipped).map { ($0.path, $0.reason) }, uniquingKeysWith: { a, _ in a })
		let depth = t.folders.count
		var placed = ""
		let files = (byDir[choice] ?? []).prefix(30).map { i -> (String, String, String) in
			let dst = wanted[i.path] ?? (problems[i.path] == nil ? i.path : "")
			if placed.isEmpty, !dst.isEmpty { placed = dst.split(separator: "/").prefix(depth).joined(separator: "/") }
			return (i.path, dst.split(separator: "/").dropFirst(depth).joined(separator: "/"), problems[i.path] ?? "")
		}
		return (e, w, choice, placed, files)
	}

	struct Version: Identifiable { var path: String; var artist: String; var album: String; var version: String; var id: String { path } }

	/// ADR 0082: other albums of the library with the same Discogs master (nothing is read from disk).
	func versions(master: String, excluding path: String) -> [Version] {
		guard let root, !master.isEmpty else { return [] }
		var out: [Version] = []
		for (folder, files) in index.albums().sorted(by: { $0.key < $1.key }) {
			guard let first = files.first?.row.tags, (first["DISCOGS_MASTER_ID"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "mM ")) == master else { continue }
			let abs = folder.isEmpty ? root.path : root.path + "/" + folder
			if abs == path { continue }
			out.append(Version(path: abs, artist: first["ALBUMARTIST"] ?? "", album: first["ALBUM"] ?? "", version: first["VERSION"] ?? ""))
		}
		return out
	}

	/// ADR 0077: every album of the library as CSV, from the index (no file is read).
	func csv(pathPrefix: String? = nil) -> String {
		guard let root else { return "" }
		let cols = ["Album Artist", "Album", "Version", "DR", "Format", "Edition", "Original Title", "Original Date", "Release Date", "Catalog Number", "Discogs Release ID", "MusicBrainz Album ID", "Subtitle", "Cover Art", "_DIRECTORY_PATH", "Directory"]
		func q(_ s: String) -> String { s.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
		var rows = [cols.joined(separator: ",")]
		for (folder, files) in index.albums().sorted(by: { $0.key < $1.key }) {
			guard let t = files.first?.row.tags else { continue }
			func tag(_ ks: String...) -> String { for k in ks { if let v = t[k], !v.isEmpty { return v } }; return "" }
			let album = tag("ALBUM_TITLE_OVERRIDE", "ALBUM_MASTER_TITLE", "ORIGINAL_TITLE").isEmpty ? (tag("ALBUM").components(separatedBy: "[").first ?? "").trimmingCharacters(in: .whitespaces) : tag("ALBUM_TITLE_OVERRIDE", "ALBUM_MASTER_TITLE", "ORIGINAL_TITLE")
			let abs = folder.isEmpty ? root.path : root.path + "/" + folder
			let dir = pathPrefix.map { $0 + abs.dropFirst(root.path.count) } ?? abs
			let vals = [tag("ALBUMARTIST"), album, tag("VERSION", "SUBTITLE"), tag("ALBUM_DR"), tag("ALBUM_FORMAT"), tag("ALBUM_EDITION"), tag("ORIGINAL_TITLE"), tag("ORIGINALDATE"), tag("RELEASEDATE"),
				tag("CATALOGNUMBER", "CATALOG NUMBER", "CATALOG_NUMBER", "CATALOGNO"), tag("DISCOGS_RELEASE_ID"), tag("MUSICBRAINZ_ALBUMID"), tag("SUBTITLE"), files.compactMap { $0.row.tags["_COVER"] }.first ?? "", dir, dir]
			rows.append(vals.map(q).joined(separator: ","))
		}
		return rows.joined(separator: "\n") + "\n"
	}
}
