import AppKit
import AVFoundation
import SwiftUI

enum Filter: String, CaseIterable { case all, needs, ready, fixed
	var label: String { ["All albums", "Needs input", "Incomplete", "Fixed"][Filter.allCases.firstIndex(of: self)!] }
}
enum SortKey: String, CaseIterable { case newest = "Newest", title = "Title", artist = "Artist", status = "Status" }
enum Source { case staging, library }

@MainActor
final class AppState: ObservableObject {
	@AppStorage("staging") var stagingPath = ""
	@AppStorage("library") var libraryPath = ""
	@AppStorage("minCover") var minCover = 1000
	@AppStorage("maxCover") var maxCover = 1500
	@AppStorage("deleteAfterMove") var deleteAfterMove = false
	@AppStorage("listView") var listView = false

	@Published var source = Source.staging
	@Published var albums: [Album] = []
	@Published var scanning = false
	@Published var filter = Filter.all
	@Published var sort = SortKey.newest
	@Published var search = ""
	@Published var selection: String?
	@Published var job: String?
	@Published var logLines: [String] = []
	@Published var runningStep: StepID?
	@Published var toast: String?
	@Published var playing: String?
	@Published var sheet: Sheet?
	@Published var fullCover: Cover?
	@Published var lyricsTrack: String?
	@Published var mbCheck: [String: MBCheck] = [:]
	@Published var leftover: Leftover?

	struct MBCheck { var notes: [String] = []; var mismatches: [String] = [] }
	struct Leftover { var folder: URL; var items: [(name: String, size: Int64, dir: Bool)] }

	enum Sheet: Identifiable {
		case settings, tagEditor, discogs, musicbrainz, move, cover, lyrics, leftover, library
		var id: Int { hashValue }
	}

	let library = LibraryWatcher()
	private var task: Task<Void, Never>?
	private var player: AVPlayer?
	private var thumbs = NSCache<NSString, NSImage>()
	private var mtimes: [String: Date] = [:]

	init() {
		library.setRoot(libraryPath)
		library.onMoved = { [weak self] in if self?.source == .library { self?.rescan() } }
	}

	var root: URL? {
		let p = source == .staging ? stagingPath : libraryPath
		return p.isEmpty ? nil : URL(fileURLWithPath: p)
	}
	var selected: Album? { albums.first { $0.id == selection } }

	var counts: [Filter: Int] {
		[.all: albums.count, .needs: albums.filter { $0.status == .needs }.count,
		 .ready: albums.filter { $0.status == .ready }.count, .fixed: albums.filter { $0.status == .fixed }.count]
	}

	var shown: [Album] {
		var a = albums.filter { filter == .all || $0.status.rawValue == filter.rawValue }
		let q = search.lowercased()
		if !q.isEmpty { a = a.filter { [$0.artist, $0.title, $0.discogsID, $0.mbid, $0.catalog, $0.name].contains { $0.lowercased().contains(q) } } }
		switch sort {
		case .newest: a.sort { (mtimes[$0.id] ?? .distantPast) > (mtimes[$1.id] ?? .distantPast) }
		case .title: a.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
		case .artist: a.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
		case .status: a.sort { $0.status.rawValue < $1.status.rawValue }
		}
		return a
	}

	func cycleSort() {
		let all = SortKey.allCases
		sort = all[(all.firstIndex(of: sort)! + 1) % all.count]
		notify("Sorted by \(sort.rawValue)")
	}

	func notify(_ s: String) {
		toast = s
		Task { try? await Task.sleep(for: .seconds(3)); if toast == s { toast = nil } }
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

	func rescan() {
		guard let root, !scanning else { if root == nil { sheet = .settings }; return }
		scanning = true
		let staging = source == .staging, minC = minCover
		Task {
			let result = await Task.detached(priority: .userInitiated) { () -> ([Album], [String: Date]) in
				let folders = Scanner.albumFolders(root: root, staging: staging)
				var out = [Album?](repeating: nil, count: folders.count)
				var dates: [String: Date] = [:]
				let lock = NSLock()
				DispatchQueue.concurrentPerform(iterations: folders.count) { i in
					let (dir, extra) = folders[i]
					let files = staging ? extra : Scanner.flacs(in: dir, recursive: false) + extra
					let a = Scanner.loadAlbum(folder: dir, files: files, minCover: minC)
					let d = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
					lock.lock(); out[i] = a; dates[dir.path] = d; lock.unlock()
				}
				return (out.compactMap { $0 }, dates)
			}.value
			albums = result.0; mtimes = result.1; scanning = false
			if selected == nil { selection = shown.first?.id }
		}
	}

	func switchSource(_ s: Source) {
		source = s; selection = nil; albums = []; rescan()
	}

	func refresh(_ a: Album) {
		guard let i = albums.firstIndex(where: { $0.id == a.id }) else { return }
		let files = source == .staging ? Scanner.flacs(in: a.url, recursive: true) : Scanner.flacs(in: a.url, recursive: false) + Scanner.flacs(in: a.url, recursive: false, discsOnly: true)
		if let n = Scanner.loadAlbum(folder: a.url, files: files, minCover: minCover) { albums[i] = n } else { albums.remove(at: i) }
	}

	// MARK: pipeline jobs (ADR 0008, 0051)

	func run(_ album: Album, steps: [StepID]? = nil) {
		guard job == nil else { return }
		let want = steps ?? [.dr, .replaygain, .fingerprints, .tags, .lyrics, .filenames]
		job = "Fixing \(album.title)"
		logLines = []
		task = Task {
			defer { job = nil; runningStep = nil; refresh(selected ?? album); task = nil }
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
				} catch is CancellationError { appendLog("stopped"); break
				} catch { appendLog("error: \(error.localizedDescription)"); if want.count == 1 { notify(error.localizedDescription) } }
			}
			appendLog("done")
		}
	}

	func stop() { task?.cancel() }

	func appendLog(_ s: String) { logLines.append(s); if logLines.count > 500 { logLines.removeFirst(100) } }

	func move(_ album: Album) {
		guard !libraryPath.isEmpty else { sheet = .settings; return }
		let lib = URL(fileURLWithPath: libraryPath)
		job = "Moving \(album.title)"
		let del = deleteAfterMove
		library.exclusive = true
		Task {
			defer { job = nil; library.exclusive = false; library.poke() }
			do {
				let lg: Log = { [weak self] l in Task { @MainActor in self?.appendLog(l) } }
				try await Task.detached { try Pipeline.move(album: album, library: lib, deleteSource: false, log: lg) }.value
				if del { leftover = Leftover(folder: album.url, items: leftoverItems(album.url)); sheet = .leftover }
				albums.removeAll { $0.id == album.id }; selection = nil
				notify("Moved to the library")
			} catch { notify(error.localizedDescription) }
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
			} catch { notify(error.localizedDescription) }
		}
	}

	func assign(_ album: Album, release: [String: Any], id: Int, items: [Assign.Item], importTitles: Bool) {
		guard job == nil else { return }
		job = "Applying \(album.title)"; logLines = []
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
				notify("Release assigned")
			} catch { notify(error.localizedDescription) }
		}
	}

	func assignMusicBrainz(_ album: Album, detail d: MusicBrainz.Detail, items: [(Assign.Item, [String])], importTitles: Bool) {
		guard job == nil else { return }
		job = "Applying \(album.title)"
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
				notify("MusicBrainz release assigned")
			} catch { notify(error.localizedDescription) }
		}
	}

	// MARK: tags

	func writeTags(_ album: Album, files: [URL]? = nil, _ change: @escaping @Sendable (URL, inout Tags) -> Void) {
		let urls = files ?? album.tracks.map(\.url)
		Task {
			do {
				try await Task.detached { try Pipeline.update(urls, change) }.value
				refresh(album)
				if let a = albums.first(where: { $0.id == album.id }) {
					try Pipeline.rename(album: a, log: { _ in }); refresh(a)
				}
				if source == .library { library.refresh(album.url) }
			} catch { notify(error.localizedDescription) }
		}
	}

	/// Album-level artwork write (ADR 0090): only pictures of `type` change; front holds one image, the others several.
	func addArtwork(_ album: Album, data: Data, type: ArtType = .front) {
		guard let (d, mime, w, h) = ImageSize.embeddable(data, max: maxCover) else { notify("Not an image"); return }
		let pic = Picture(type: type.rawValue, mime: mime, desc: "", width: UInt32(w), height: UInt32(h), data: d)
		let urls = album.tracks.map(\.url)
		Task {
			do {
				try await Task.detached {
					for u in urls {
						var f = try FlacFile(url: u)
						if type == .front { f.pictures.removeAll { $0.type == 3 } }
						else if f.pictures.contains(where: { $0.type == type.rawValue && $0.data == d }) { continue }
						f.pictures.append(pic); try f.save()
					}
				}.value
				refresh(album)
			} catch { notify(error.localizedDescription) }
		}
	}

	func setCover(_ album: Album, data: Data) { addArtwork(album, data: data, type: .front) }

	func removeArtwork(_ album: Album, type: ArtType, data: Data) {
		let urls = album.tracks.map(\.url), dir = album.url
		Task {
			try? await Task.detached {
				for u in urls { var f = try FlacFile(url: u); f.pictures.removeAll { $0.type == type.rawValue && $0.data == data }; try f.save() }
				if type == .front, let c = Scanner.folderImage(dir) { try? FileManager.default.removeItem(at: c) }
			}.value
			refresh(album)
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
		notify("No image on the clipboard")
	}

	func dropCover(_ album: Album, providers: [NSItemProvider], type: ArtType = .front) -> Bool {
		for p in providers {
			if p.hasItemConformingToTypeIdentifier("public.file-url") {
				_ = p.loadObject(ofClass: URL.self) { u, _ in
					guard let u, let d = try? Data(contentsOf: u) else { return }
					Task { @MainActor in self.addArtwork(album, data: d, type: type) }
				}
				return true
			}
			if p.hasItemConformingToTypeIdentifier("public.image") {
				p.loadDataRepresentation(forTypeIdentifier: "public.image") { d, _ in
					guard let d else { return }
					Task { @MainActor in self.addArtwork(album, data: d, type: type) }
				}
				return true
			}
		}
		notify("Drop an image file")
		return false
	}

	func chooseArtwork(_ album: Album, type: ArtType) {
		let p = NSOpenPanel()
		p.allowedContentTypes = [.jpeg, .png]
		if p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) { addArtwork(album, data: d, type: type) }
	}

	// MARK: playback (ADR 0015, 0068)

	func play(_ t: Track) {
		if playing == t.id { stopPlayback(); return }
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
