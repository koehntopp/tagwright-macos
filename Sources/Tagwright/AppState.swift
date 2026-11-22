import AppKit
import AVFoundation
import SwiftUI

enum Filter: String, CaseIterable { case all, needs, ready, fixed
	var label: String { ["All albums", "Needs input", "Incomplete", "Fixed"][Filter.allCases.firstIndex(of: self)!] }
}
enum SortKey: String, CaseIterable { case newest = "Newest", title = "Title", artist = "Artist", status = "Status" }
enum Source: String { case staging, library }
enum JobState { case idle, running, failed, stopped }
struct LogLine { var t: String; var m: String; var k: String }   // time, text, kind: ok (green), file (dimmed)
enum ToastKind { case plain, success, error, warning, info }
struct Toast: Equatable { var text: String; var kind: ToastKind }

@MainActor
final class AppState: ObservableObject {
	@AppStorage("staging") var stagingPath = ""
	@AppStorage("library") var libraryPath = ""
	@AppStorage("minCover") var minCover = 1000
	@AppStorage("maxCover") var maxCover = 1500
	@AppStorage("deleteAfterMove") var deleteAfterMove = false
	@AppStorage("listView") var listView = false

	@AppStorage("source") var source = Source.staging   // remembered, as the web app does (localStorage)
	@Published var albums: [Album] = []
	/// Album.status reads every track's tags (names, lyrics, issues): computed when an album is loaded, not per redraw.
	private(set) var statuses: [String: Status] = [:]
	func status(_ a: Album) -> Status { statuses[a.id] ?? a.status }
	@Published var scanning = false
	@Published var filter = Filter.all
	@Published var sort = SortKey.newest
	@Published var search = ""
	@Published var selection: String? { didSet { if let a = selected, !a.full { refresh(a) } } }
	@Published var job: String?
	@Published var logLines: [LogLine] = []
	@Published var runningStep: StepID?
	@Published var toast: Toast?
	@Published var jobState = JobState.idle
	@Published var working: [String: Set<StepID>] = [:]
	@Published var coverBusy: String?
	@Published var dialogError: String?   // shown in the open dialog (a failed move)   // steps a save is rewriting (tag editor), not a pipeline job
	@Published var playing: String?
	@Published var sheet: Sheet?
	@Published var fullCover: Cover?
	@Published var lyricsTrack: String?
	@Published var editorTab = 0   // the tag editor opens on this tab (Album 0, Tracks 1)
	@Published var tableSort: (key: String, asc: Bool)? = nil   // list view column sort; a filter click resets it
	@Published var mbCheck: [String: MBCheck] = [:]
	@Published var leftover: Leftover?

	struct MBCheck { var notes: [String] = []; var mismatches: [String] = [] }
	struct Leftover { var folder: URL; var items: [(name: String, size: Int64, dir: Bool)] }

	enum Sheet: Identifiable {
		case settings, tagEditor, discogs, musicbrainz, move, lyrics, leftover, library, albumEdit, coverDelete
		var id: Int { hashValue }
	}

	let library = LibraryWatcher()
	let summaries = Summaries(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tagwright/summaries.plist"))
	private var task: Task<Void, Never>?
	private var player: AVPlayer?
	private var thumbs = NSCache<NSString, NSImage>()
	private var mtimes: [String: Date] = [:]

	init() {
		AppLog.app("Tagwright started (log level \(AppLog.level.name))")
		library.setRoot(libraryPath)
		library.onMoved = { [weak self] in if self?.source == .library { self?.rescan() } }
	}

	var root: URL? {
		let p = source == .staging ? stagingPath : libraryPath
		return p.isEmpty ? nil : URL(fileURLWithPath: p)
	}
	var selected: Album? { albums.first { $0.id == selection } }

	var counts: [Filter: Int] {
		var c: [Filter: Int] = [.all: albums.count, .needs: 0, .ready: 0, .fixed: 0]
		for s in statuses.values { c[Filter(rawValue: s.rawValue)!, default: 0] += 1 }
		return c
	}

	var shown: [Album] {
		var a = albums.filter { filter == .all || status($0).rawValue == filter.rawValue }
		let q = search.lowercased()
		if !q.isEmpty { a = a.filter { [$0.name, $0.title, $0.artist, $0.discogsID, $0.mbid].contains { $0.lowercased().contains(q) } } }
		if listView, let t = tableSort { return a.sorted { AlbumColumn.less(t.key, t.asc, $0, $1) } }
		let order: [Status: Int] = [.needs: 0, .ready: 1, .fixed: 2]
		func byTitle(_ x: Album, _ y: Album) -> Bool { x.title.localizedCompare(y.title) == .orderedAscending }
		switch sort {
		case .newest: a.sort { (mtimes[$0.id] ?? .distantPast) > (mtimes[$1.id] ?? .distantPast) }
		case .title: a.sort(by: byTitle)
		case .artist: a.sort { let c = $0.artist.localizedCompare($1.artist); return c == .orderedSame ? byTitle($0, $1) : c == .orderedAscending }
		case .status: a.sort { let x = order[status($0)]!, y = order[status($1)]!; return x == y ? byTitle($0, $1) : x < y }
		}
		return a
	}

	func cycleSort() {
		let all = SortKey.allCases
		sort = all[(all.firstIndex(of: sort)! + 1) % all.count]
		notify("Sorted by \(sort.rawValue)")
	}

	func notify(_ s: String, kind: ToastKind = .plain) {
		let t = Toast(text: s, kind: kind)
		toast = t
		Task { try? await Task.sleep(for: .seconds(4)); if toast == t { toast = nil } }
	}

	func thumbnail(_ a: Album, size: Int) -> NSImage? { a.cover.flatMap { thumbnail($0, size: size) } }

	func thumbnail(_ c: Cover, size: Int) -> NSImage? {
		let key = "\(c.data.hashValue)-\(size)" as NSString
		if let i = thumbs.object(forKey: key) { return i }
		guard let i = ImageSize.thumbnail(c.data, max: size) else { return nil }
		thumbs.setObject(i, forKey: key)
		return i
	}

	// MARK: scanning

	/// `fresh`: read every file again instead of using the stored summaries (the Rescan button, web `fresh=1`).
	func rescan(fresh: Bool = false) {
		guard let root, !scanning else { if root == nil { sheet = .settings }; return }
		scanning = true
		let staging = source == .staging, minC = minCover, sums = summaries
		Task {
			let result = await Task.detached(priority: .userInitiated) { () -> ([Album], [String: Date], [String: Status]) in
				let folders = Scanner.albumFolders(root: root, staging: staging)
				var out = [Album?](repeating: nil, count: folders.count)
				var dates: [String: Date] = [:]
				let lock = NSLock()
				DispatchQueue.concurrentPerform(iterations: folders.count) { i in
					let (dir, extra) = folders[i]
					let files = staging ? extra : Scanner.flacs(in: dir, recursive: false) + extra
					let sig = Summaries.signature(folder: dir, files: files)
					var a = fresh ? nil : sums.album(folder: dir, sig: sig, minCover: minC)
					if a == nil, let n = Scanner.loadAlbum(folder: dir, files: files, minCover: minC) { sums.put(n, sig: sig); a = n }
					let d = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
					lock.lock(); out[i] = a; dates[dir.path] = d; lock.unlock()
				}
				sums.prune(root: root, keep: Set(dates.keys))
				sums.save()
				let all = out.compactMap { $0 }
				return (all, dates, Dictionary(all.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a }))
			}.value
			statuses = result.2; albums = result.0; mtimes = result.1; scanning = false
			if selected == nil { selection = shown.first?.id }
		}
	}

	func switchSource(_ s: Source) {
		source = s; selection = nil; albums = []; statuses = [:]; rescan()
	}

	func refresh(_ a: Album) {
		guard let i = albums.firstIndex(where: { $0.id == a.id }) else { return }
		let files = albumFiles(a.url)
		if let n = Scanner.loadAlbum(folder: a.url, files: files, minCover: minCover) {
			statuses[n.id] = n.status; albums[i] = n
			summaries.put(n, sig: Summaries.signature(folder: a.url, files: files)); summaries.saveSoon()
		} else { statuses[a.id] = nil; albums.remove(at: i) }
	}

	private func albumFiles(_ dir: URL) -> [URL] {
		if source == .staging { return Scanner.flacs(in: dir, recursive: true) }
		let own = Scanner.flacs(in: dir, recursive: false)
		return dir.standardizedFileURL == root?.standardizedFileURL ? own : own + Scanner.flacs(in: dir, recursive: false, discsOnly: true)
	}

	// MARK: pipeline jobs (ADR 0008, 0051)

	func run(_ album: Album, steps: [StepID]? = nil) {
		guard job == nil else { return }
		let want = steps ?? [.dr, .replaygain, .fingerprints, .tags, .lyrics, .filenames]
		job = "Fixing \(album.title)"
		jobState = .running
		AppLog.app("run started: \(album.name) (\((steps ?? []).map(\.label).joined(separator: ", ").isEmpty ? "all steps" : (steps ?? []).map(\.label).joined(separator: ", ")))")
		notify(steps?.count == 1 ? "Running \(steps![0].label) on \(album.title)…" : "Running fixes on \(album.title)…", kind: .success)
		var failed = false, stopped = false
		task = Task {
			defer {
				job = nil; runningStep = nil; refresh(selected ?? album); task = nil
				jobState = failed ? .failed : stopped ? .stopped : .idle
				AppLog.app("run \(failed ? "finished with errors" : stopped ? "stopped" : "finished"): \(album.name)", failed ? .warning : .info)
				notify(failed ? "Run finished with errors" : stopped ? "Run stopped" : "Run finished", kind: failed ? .error : stopped ? .warning : .success)
			}
			var cur = album
			let files = cur.tracks.map(\.url)
			do { let lg: Log = { [weak self] l in Task { @MainActor in self?.appendLog(l) } }; try await Task.detached { try Pipeline.stripID3v1(files, log: lg) }.value } catch { appendLog("error: \(error.localizedDescription)") }
			for s in want {
				if Task.isCancelled { break }
				runningStep = s
				appendLog("== \(s.label)")
				do {
					let log: Log = { [weak self] l in Task { @MainActor in self?.appendLog(l) } }
					switch s {
					case .dr: try await Task.detached { try Pipeline.dynamicRange(files: files, log: log) }.value
					case .replaygain: try await Task.detached { try Pipeline.replayGain(files: files, log: log) }.value
					case .fingerprints: try await Task.detached { try Pipeline.fingerprints(files: files, log: log) }.value
					case .lyrics: refresh(cur); cur = selected ?? cur; try await Pipeline.lyrics(album: cur, log: log)
					case .filenames: refresh(cur); cur = selected ?? cur; try Pipeline.rename(album: cur, log: log)
					case .tags: refresh(cur); cur = selected ?? cur; try await Assign.fixTags(album: cur, log: log)
					}
				} catch is CancellationError { appendLog("stopped"); stopped = true; break
				} catch { appendLog("error: \(error.localizedDescription)"); failed = true }
			}
			if Task.isCancelled { stopped = true }
			appendLog(failed ? "finished with errors" : stopped ? "stopped" : "finished")
		}
	}

	func stop() { task?.cancel() }

	func appendLog(_ s: String) {
		AppLog.pipeline(s, s.hasPrefix("renamed ") ? .debug : s.hasPrefix("error") ? .error : .info)
		let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
		let k = s.hasPrefix("renamed ") ? "file" : s.range(of: "finished|done|success", options: [.regularExpression, .caseInsensitive]) != nil && !s.contains("errors") ? "ok" : ""
		logLines.append(LogLine(t: f.string(from: Date()), m: s, k: k)); if logLines.count > 500 { logLines.removeFirst(100) }
	}

	func move(_ album: Album) {
		guard !libraryPath.isEmpty else { sheet = .settings; return }
		// The move writes cover.jpg from the embedded cover: never from a summary thumbnail.
		guard let album = album.full ? album : Scanner.loadAlbum(folder: album.url, files: albumFiles(album.url), minCover: minCover) else { return }
		let lib = URL(fileURLWithPath: libraryPath)
		job = "Moving \(album.title)"
		let del = deleteAfterMove
		library.exclusive = true
		Task {
			defer { job = nil; library.exclusive = false; library.poke() }
			do {
				let lg: Log = { [weak self] l in Task { @MainActor in self?.appendLog(l) } }
				try await Task.detached { try Pipeline.move(album: album, library: lib, deleteSource: false, log: lg) }.value
				appendLog("moved to " + lib.path)
				AppLog.app("moved to the library: \(album.name) (\(album.tracks.count) files)")
				if del { leftover = Leftover(folder: album.url, items: leftoverItems(album.url)) }
				sheet = del ? .leftover : nil
				albums.removeAll { $0.id == album.id }; statuses[album.id] = nil; selection = nil
				notify("Moved to the library", kind: .success)
			} catch { dialogError = error.localizedDescription; AppLog.app("move failed: \(album.name): \(error.localizedDescription)", .error) }
		}
	}

	/// ADR 0023/0083: notes and the year mismatch, for the selected album only (one MusicBrainz lookup, cached).
	func checkMusicBrainz(_ a: Album) async {
		guard !a.mbid.isEmpty, let did = Int(a.discogsID) else { mbCheck[a.id] = nil; return }
		guard let mb = await MusicBrainz.release(a.mbid) else { mbCheck[a.id] = MBCheck(); return }
		var c = MBCheck()
		if !mb.discogsIDs.isEmpty, !mb.discogsIDs.contains(did) { c.notes.append("MusicBrainz links Discogs release \(mb.discogsIDs.map(String.init).joined(separator: ", ")), this album uses \(did).") }
		let dy = a.tracks.first?.tags.first("ALBUM_RELEASE_YEAR", "YEAR", "DATE").prefix(4).description ?? ""
		if !dy.isEmpty, !mb.year.isEmpty, dy != mb.year { c.mismatches.append("Year: Discogs \(dy), MusicBrainz \(mb.year).") }
		if mb.tracks > 0, mb.tracks != a.tracks.count { c.notes.append("The MusicBrainz release has \(mb.tracks) tracks, this album has \(a.tracks.count) files.") }
		mbCheck[a.id] = c
	}

	func leftoverItems(_ dir: URL) -> [(name: String, size: Int64, dir: Bool)] {
		let fm = FileManager.default
		guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return [] }
		return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { u in
			let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
			var size: Int64 = 0
			if isDir, let en = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) { for case let f as URL in en { size += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }
			else { size = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
			return (u.lastPathComponent, size, isDir)
		}
	}

	// MARK: assignments (ADR 0053, 0078)

	/// Clearing an override restores the Discogs value (ADR 0014): format, catalogue number, album and artist come back from the release.
	func restoreFromDiscogs(_ album: Album) {
		guard let id = Int(album.discogsID) else { return }
		Task {
			do {
				let r = try await Discogs.release(id)
				let labels = r["labels"] as? [[String: Any]] ?? []
				let fmt = (r["formats"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.first { !["Box Set", "All Media"].contains($0) }
				let cat = labels.first?["catno"] as? String ?? "none"
				try await Task.sleep(for: .milliseconds(600))
				guard let a = albums.first(where: { $0.id == album.id }) else { return }
				try await Task.detached { try Pipeline.update(a.tracks.map(\.url)) { _, t in
					if t.first("ALBUM_FORMAT_OVERRIDE").isEmpty, let fmt { t["ALBUM_FORMAT"] = [fmt] }
					if t.first("CATALOGNUMBER_OVERRIDE").isEmpty { t["CATALOGNUMBER"] = [cat.isEmpty ? "none" : cat] }
				} }.value
				refresh(a)
				if let b = albums.first(where: { $0.id == album.id }) { try await Assign.fixTags(album: b, log: { _ in }); refresh(b) }
			} catch { notify(error.localizedDescription, kind: .error) }
		}
	}

	func assign(_ album: Album, release: [String: Any], id: Int, items: [Assign.Item], importTitles: Bool) {
		guard job == nil else { return }
		job = "Applying \(album.title)"
		AppLog.app("assigned Discogs release \(id) to \(album.name) (\(items.count) files)")
		nonisolated(unsafe) let r = release
		Task {
			defer { job = nil }
			do {
				var discs: [Int: Int] = [:]
				for i in items { discs[i.disc, default: 0] += 1 }
				try await Assign.apply(album: album, release: r, id: id, items: items, importTitles: importTitles, total: (discs, discs.count))
				refresh(album)
				if let a = albums.first(where: { $0.id == album.id }) {
					do { try await Assign.fixTags(album: a, log: { [weak self] l in Task { @MainActor in self?.appendLog(l) } }) }
					catch { appendLog("Discogs tags not refreshed: \(error.localizedDescription)") }
					refresh(a)
					if let b = albums.first(where: { $0.id == album.id }) { try Pipeline.rename(album: b, log: { [weak self] l in Task { @MainActor in self?.appendLog(l) } }); refresh(b) }
				}
				notify("Tracks assigned", kind: .success)
			} catch { notify(error.localizedDescription, kind: .error) }
		}
	}

	func assignMusicBrainz(_ album: Album, detail d: MusicBrainz.Detail, items: [(Assign.Item, [String])], importTitles: Bool) {
		guard job == nil else { return }
		job = "Applying \(album.title)"
		AppLog.app("assigned MusicBrainz release \(d.id) to \(album.name) (\(items.count) files)")
		var discs: [Int: Int] = [:]
		for (i, _) in items { discs[i.disc, default: 0] += 1 }
		let byURL = Dictionary(uniqueKeysWithValues: items.map { ($0.0.url.path, $0) })
		let urls = album.tracks.map(\.url)
		Task {
			defer { job = nil }
			do {
				try await Task.detached {
					try Pipeline.update(urls) { url, t in
						t["MUSICBRAINZ ALBUM ID"] = nil; t["MUSICBRAINZ_RELEASEGROUPID"] = nil
						t["MUSICBRAINZ_ALBUMID"] = [d.id]; t["MUSICBRAINZ_ALBUM_URL"] = ["https://musicbrainz.org/release/\(d.id)"]
						if !d.groupID.isEmpty { t["MUSICBRAINZ_RELEASE_GROUPID"] = [d.groupID]; t["MUSICBRAINZ_RELEASE_GROUP_URL"] = ["https://musicbrainz.org/release-group/\(d.groupID)"] }
						if !d.artistIDs.isEmpty { t["MUSICBRAINZ_ALBUMARTISTID"] = d.artistIDs; t["MUSICBRAINZ_ALBUMARTIST_URL"] = d.artistIDs.map { "https://musicbrainz.org/artist/\($0)" } }
						for (k, v) in [("BARCODE", d.barcode), ("ASIN", d.asin), ("MUSICBRAINZ_ALBUM_RELEASECOUNTRY", d.country), ("MUSICBRAINZ_ALBUMSTATUS", d.status), ("MUSICBRAINZ_ALBUMTYPE", d.groupTypes)] where !v.isEmpty && t.first(k).isEmpty { t[k] = [v] }
						if let (it, ids) = byURL[url.path] {
							if !ids.isEmpty { t["MUSICBRAINZ_ARTISTID"] = ids; t["MUSICBRAINZ_ARTIST_URL"] = ids.map { "https://musicbrainz.org/artist/\($0)" } }
							if importTitles {
								t["TITLE"] = [it.title]; if !it.track.artist.isEmpty { t["ARTIST"] = [it.track.artist] }
								t["TRACKNUMBER"] = ["\(it.number)"]; t["DISCNUMBER"] = ["\(it.disc)"]
								t["TRACKTOTAL"] = ["\(discs[it.disc] ?? 0)"]; t["TOTALTRACKS"] = ["\(discs[it.disc] ?? 0)"]; t["DISCTOTAL"] = ["\(discs.count)"]; t["TOTALDISCS"] = ["\(discs.count)"]
								if !it.subtitle.isEmpty { t["SET SUBTITLE"] = [it.subtitle] }
							} else {
								if t.first("TITLE").isEmpty { t["TITLE"] = [it.title] }
								if t.first("DISCNUMBER").isEmpty { t["DISCNUMBER"] = ["\(it.disc)"] }
								if t.first("TRACKNUMBER").isEmpty { t["TRACKNUMBER"] = ["\(it.number)"] }
							}
						}
					}
				}.value
				refresh(album)
				if let a = albums.first(where: { $0.id == album.id }) { try Pipeline.rename(album: a, log: { _ in }); refresh(a) }
				notify("MusicBrainz release applied", kind: .success)
			} catch { notify(error.localizedDescription, kind: .error) }
		}
	}

	// MARK: tags

	static let overrideTargets = ["ALBUM_ARTIST_OVERRIDE": "ALBUMARTIST", "ALBUM_TITLE_OVERRIDE": "ALBUM", "ALBUM_FORMAT_OVERRIDE": "ALBUM_FORMAT", "CATALOGNUMBER_OVERRIDE": "CATALOGNUMBER"]

	/// The tag editor's and the album dialog's save (app.py write_album_fields + the track edits): changed album
	/// fields, edited tracks; clearing an override restores the Discogs value; a format, catalogue or edition change
	/// rewrites VERSION. The step circles spin meanwhile (Tags & cover + Filenames, or Filenames).
	func writeAlbumFields(_ album: Album, fields f: [String: String], tracks rows: [String: TrackRow], done: String) {
		let t0 = album.tracks.first?.tags ?? [:]
		let cleared = f.filter { k, v in k != "ALBUM_EDITION" && v.trimmingCharacters(in: .whitespaces).isEmpty && !t0.first(k).isEmpty }.map(\.key)
		let touchedVersion = ["ALBUM_FORMAT_OVERRIDE", "CATALOGNUMBER_OVERRIDE", "ALBUM_EDITION"].contains { f[$0] != nil }
		let dr = album.albumDR
		AppLog.app("tags saved: \(album.name): \(f.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.isEmpty ? "(removed)" : "'\($0.value)'")" }.joined(separator: ", ").isEmpty ? "no album fields" : f.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.isEmpty ? "(removed)" : "'\($0.value)'")" }.joined(separator: ", ")); \(rows.count) track(s) edited")
		for r in rows.values { AppLog.app("track edited: \(r.file): title='\(r.title)' disc=\(r.disc) track=\(r.track) artist='\(r.artist)'", .debug) }
		writeTags(album, steps: touchedVersion ? [.tags, .filenames] : [.filenames], done: done) { url, t in
			for (k, raw) in f {
				let v = raw.trimmingCharacters(in: .whitespaces)
				if k == "ALBUM_EDITION" { t[k] = v.isEmpty ? nil : [v]; continue }
				if v.isEmpty { t[k] = nil; continue }
				t[k] = [v]
				if let target = Self.overrideTargets[k] { t[target] = [v] }
				if k == "CATALOGNUMBER_OVERRIDE" { for alt in ["CATALOG NUMBER", "CATALOG_NUMBER", "CATALOGNO"] { t[alt] = nil } }
			}
			if let r = rows[url.path] {
				t["TITLE"] = [r.title.trimmingCharacters(in: .whitespaces)]; t["DISCNUMBER"] = [r.disc.trimmingCharacters(in: .whitespaces)]; t["TRACKNUMBER"] = [r.track.trimmingCharacters(in: .whitespaces)]
				let ar = r.artist.trimmingCharacters(in: .whitespaces), sub = r.subtitle.trimmingCharacters(in: .whitespaces)
				t["ARTIST"] = ar.isEmpty ? nil : [ar]
				t["SET SUBTITLE"] = sub.isEmpty ? nil : [sub]; t["DISCSUBTITLE"] = sub.isEmpty ? nil : [sub]
			}
			if touchedVersion, !t.first("DISCOGS_RELEASE_ID").isEmpty {
				t["VERSION"] = [Naming.versionString(year: t.first("ALBUM_RELEASE_YEAR", "DATE"), dr: dr, format: t.first("ALBUM_FORMAT"), edition: t.first("ALBUM_EDITION"), catalog: t.first("CATALOGNUMBER", "CATALOG NUMBER"))]
			}
		}
		if !cleared.isEmpty { restoreFromDiscogs(album) }
	}

	func writeTags(_ album: Album, files: [URL]? = nil, steps: Set<StepID> = [], done: String? = nil, _ change: @escaping @Sendable (URL, inout Tags) -> Void) {
		let urls = files ?? album.tracks.map(\.url)
		working[album.id] = steps
		Task {
			defer { working[album.id] = nil }
			do {
				try await Task.detached { try Pipeline.update(urls, change) }.value
				refresh(album)
				if let a = albums.first(where: { $0.id == album.id }) {
					try Pipeline.rename(album: a, log: { _ in }); refresh(a)
				}
				if source == .library { library.refresh(album.url) }
				if let done { notify(done, kind: .success) }
			} catch { notify(error.localizedDescription, kind: .error) }
		}
	}

	/// Album-level artwork write (ADR 0090): only pictures of `type` change; front holds one image, the others several.
	/// `replacing`: the image this one takes the place of (a drop on a shown image, the cover menu's Upload).
	func addArtwork(_ album: Album, data: Data, type: ArtType = .front, replacing: Data? = nil) {
		guard let (d, mime, w, h) = ImageSize.embeddable(data, max: maxCover) else { notify("That is not an image", kind: .error); return }
		let pic = Picture(type: type.rawValue, mime: mime, desc: "", width: UInt32(w), height: UInt32(h), data: d)
		let urls = album.tracks.map(\.url)
		coverBusy = album.id; working[album.id] = [.tags]   // the fields spin and so does Tags & cover (web putCover)
		Task {
			defer { coverBusy = nil; working[album.id] = nil }
			do {
				try await Task.detached {
					for u in urls {
						var f = try AudioFile(url: u)
						if type == .front { f.pictures.removeAll { $0.type == 3 } }
						else if let r = replacing { f.pictures.removeAll { $0.type == type.rawValue && $0.data == r } }
						if type != .front, f.pictures.contains(where: { $0.type == type.rawValue && $0.data == d }) { continue }
						f.pictures.append(pic); try f.save()
					}
				}.value
				refresh(album)
				appendLog("cover artwork added"); notify("Cover updated", kind: .success)
			} catch { notify(error.localizedDescription, kind: .error) }
		}
	}

	func setCover(_ album: Album, data: Data) { addArtwork(album, data: data, type: .front) }

	func removeArtwork(_ album: Album, type: ArtType, data: Data) {
		let urls = album.tracks.map(\.url), dir = album.url
		Task {
			try? await Task.detached {
				for u in urls { var f = try AudioFile(url: u); f.pictures.removeAll { $0.type == type.rawValue && $0.data == data }; try f.save() }
				if type == .front, let c = Scanner.folderImage(dir) { try? FileManager.default.removeItem(at: c) }
			}.value
			refresh(album)
			appendLog("cover artwork removed"); notify("Cover removed", kind: .success)
		}
	}

	func removeCover(_ album: Album) { if let c = album.cover { removeArtwork(album, type: .front, data: c.data) } }

	/// Image data or an image file from the pasteboard (⇧⌘V, Paste buttons).
	func pasteCover(_ album: Album, type: ArtType = .front) {
		let pb = NSPasteboard.general
		if let u = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
			let d = try? Data(contentsOf: u), ImageSize.of(d) != nil { addArtwork(album, data: d, type: type); return }
		if let d = pb.data(forType: .png) ?? pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")) { addArtwork(album, data: d, type: type); return }
		if let t = pb.data(forType: .tiff), let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) { addArtwork(album, data: png, type: type); return }
		notify("No image on the clipboard", kind: .error)
	}

	func dropCover(_ album: Album, providers: [NSItemProvider], type: ArtType = .front, replacing: Data? = nil) -> Bool {
		for p in providers {
			if p.hasItemConformingToTypeIdentifier("public.file-url") {
				_ = p.loadObject(ofClass: URL.self) { u, _ in
					guard let u, let d = try? Data(contentsOf: u) else { return }
					Task { @MainActor in self.addArtwork(album, data: d, type: type, replacing: replacing) }
				}
				return true
			}
			if p.hasItemConformingToTypeIdentifier("public.image") {
				p.loadDataRepresentation(forTypeIdentifier: "public.image") { d, _ in
					guard let d else { return }
					Task { @MainActor in self.addArtwork(album, data: d, type: type, replacing: replacing) }
				}
				return true
			}
		}
		notify("That is not an image", kind: .error)
		return false
	}

	func chooseArtwork(_ album: Album, type: ArtType) {
		let p = NSOpenPanel()
		p.allowedContentTypes = [.jpeg, .png]
		if p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) { addArtwork(album, data: d, type: type) }
	}

	// MARK: playback (ADR 0015, 0068)

	func play(_ t: Track) {
		if playing == t.id { stopPlayback(); return }   // web: the second click stops; the next one starts again
		player?.pause()
		player = AVPlayer(url: t.url)
		player?.play()
		playing = t.id
		NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem, queue: .main) { [weak self] _ in
			Task { @MainActor in self?.stopPlayback() }
		}
	}
	func stopPlayback() { player?.pause(); player = nil; playing = nil }

	func chooseFolder(_ forStaging: Bool) {
		let p = NSOpenPanel()
		p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
		p.prompt = "Choose"
		if p.runModal() == .OK, let u = p.url {
			if forStaging { stagingPath = u.path } else { libraryPath = u.path; library.setRoot(u.path) }
			objectWillChange.send()
			if forStaging == (source == .staging) { rescan() }
		}
	}
}
