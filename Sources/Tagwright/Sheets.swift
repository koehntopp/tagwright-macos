import SwiftUI
import UniformTypeIdentifiers

// The web app's dialogs (dialogs.tsx, releases.tsx, track-table.tsx, subtitle-divider.tsx) on the shared Shell.

// MARK: settings (dialogs.tsx SettingsDialog, ADR 0009, 0045, 0074)

struct SettingsSheet: View {
	@EnvironmentObject var app: AppState
	@Environment(\.dialogMaxHeight) var maxH
	@State private var tab = Int(ProcessInfo.processInfo.environment["TW_TAB"] ?? "") ?? 0
	@State private var draft = LibrarySettings.load()
	@State private var minC = ""
	@State private var maxC = ""
	@State private var del = false
	@State private var key = ""
	@State private var err: String?
	@State private var loaded = false

	var body: some View {
		Shell(title: "Settings", width: tab == 1 ? 896 : 768, err: err, save: save, onClose: { app.sheet = nil }) {
			Spacer()
			Picker("", selection: $tab) { Text("General").tag(0); Text("Library").tag(1) }.pickerStyle(.segmented).labelsHidden().frame(width: 180).padding(.trailing, 24)
		} content: {
			ScrollView {
				if tab == 1 { LibraryTab(lib: app.library, draft: $draft) } else { general }
			}.frame(maxHeight: maxH - 160).fixedSize(horizontal: false, vertical: true)
		}
		.onAppear {
			guard !loaded else { return }
			loaded = true; minC = "\(app.minCover)"; maxC = "\(app.maxCover)"; del = app.deleteAfterMove
		}
	}

	var general: some View {
		VStack(alignment: .leading, spacing: 12) {
			Field(label: "Staging folder", help: "Albums to fix are read from here.") { folder(app.stagingPath, true) }
			Field(label: "Library folder", help: "Fixed albums are placed here in the library layout, and a watcher keeps this folder in that layout (see the Library tab).") { folder(app.libraryPath, false) }
			Field(label: "Minimum cover size (pixels)", help: "An album whose cover is smaller than this on either side, or has none, cannot be moved to the library. 0 turns the check off.") {
				TextField("", text: $minC).font(.system(size: 14, design: .monospaced)).webField().frame(width: 160)
			}
			Field(label: "Maximum cover size (pixels)", help: "A cover larger than this on either side is scaled down to it: when you upload or fetch one, and by Run fixes. Default 1500.") {
				TextField("", text: $maxC).font(.system(size: 14, design: .monospaced)).webField().frame(width: 160)
			}
			HStack(alignment: .top, spacing: 8) {
				Toggle("", isOn: $del).toggleStyle(.checkbox).labelsHidden().padding(.top, 2)
				VStack(alignment: .leading, spacing: 2) {
					Text("Offer to delete the album's folder after a move").font(.system(size: 14, weight: .medium))
					Text("After all songs of an album have moved to the library, a dialog lists what is left in its folder of the staging folder (cover, logs, scans) with the sizes, and deletes the folder only when you press Delete.").font(.system(size: 12)).foregroundStyle(Color.slate(500)).fixedSize(horizontal: false, vertical: true)
				}
			}
			Field(label: "Discogs API key", help: "Leave blank to keep the stored key.") {
				SecureField(Keychain.get("discogs").map { $0.isEmpty ? "Not set" : "••••" + String($0.suffix(4)) } ?? "Not set", text: $key).font(.system(size: 14, design: .monospaced)).webField()
			}
		}.frame(maxWidth: .infinity, alignment: .leading)
	}

	func folder(_ path: String, _ staging: Bool) -> some View {
		HStack(spacing: 8) {
			Text(path.isEmpty ? "Not set" : path).font(.system(size: 14, design: .monospaced)).lineLimit(1).truncationMode(.middle)
				.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
				.background(Color.slate(100).opacity(0.4), in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.slate(200)))
			Button("Choose…") { app.chooseFolder(staging) }.buttonStyle(WebButton(kind: .outline))
		}
	}

	func save() {
		guard let mn = Int(minC.trimmingCharacters(in: .whitespaces)) else { err = "Minimum cover size must be a whole number of pixels"; return }
		guard (0...20000).contains(mn) else { err = "Minimum cover size must be between 0 and 20000 pixels"; return }
		guard let mx = Int(maxC.trimmingCharacters(in: .whitespaces)) else { err = "Maximum cover size must be a whole number of pixels"; return }
		guard (100...20000).contains(mx) else { err = "Maximum cover size must be between 100 and 20000 pixels"; return }
		guard mx >= mn else { err = "Maximum cover size must not be below the minimum cover size"; return }
		let v = LibTemplate.validate(draft.template)
		guard v.errors.isEmpty else { err = v.errors.joined(separator: "; "); return }
		app.minCover = mn; app.maxCover = mx; app.deleteAfterMove = del
		if !key.isEmpty { Keychain.set("discogs", key) }
		app.library.settings = draft
		app.notify("Settings saved", kind: .success); AppLog.app("settings saved")   // never the key itself (ADR 0007)
		app.sheet = nil; app.selection = nil; app.rescan()
	}
}

// MARK: move (page.tsx move dialog, ADR 0037)

struct MoveSheet: View {
	@EnvironmentObject var app: AppState
	var album: Album
	@State private var art: [UInt32: [Picture]]?   // the embedded pictures, read once
	var body: some View {
		let lib = URL(fileURLWithPath: app.libraryPath.isEmpty ? "/missing" : app.libraryPath)
		let plan = Pipeline.movePlan(album: album, library: lib, extra: app.mbCheck[album.id]?.mismatches ?? [])
		let moving = app.job?.hasPrefix("Moving") == true
		let rel = plan.folder.path.replacingOccurrences(of: lib.path + "/", with: "")
		let exists = plan.moves.map { FileManager.default.fileExists(atPath: $0.to.path) }
		let problems = (app.libraryPath.isEmpty ? ["Choose a library folder in Settings first."] : []) + plan.problems + zip(plan.moves, exists).filter(\.1).map { "\($0.0.to.path.replacingOccurrences(of: lib.path + "/", with: "")) already exists in the library; nothing is overwritten" }
		let covers = art.map { Artwork.plan($0, target: plan.folder) } ?? []
		Shell(title: "Move to the library?", width: 640, err: app.dialogError, saveLabel: moving ? "Moving…" : "Move", saveDisabled: !problems.isEmpty || moving || plan.moves.isEmpty, danger: moving, save: { app.dialogError = nil; app.move(album) }, onClose: { app.sheet = nil }) {
			VStack(alignment: .leading, spacing: 8) {
				Text("“\(album.title)” moves \(plan.moves.count) track\(plan.moves.count == 1 ? "" : "s") into the library, each to its place from the layout in Settings.").font(.system(size: 14))
				Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 4) {
					GridRow { k("Library"); mono(lib.path + "/") }
					GridRow { k("Album folder"); mono((rel.isEmpty ? "—" : rel) + "/") }
					GridRow {
						k("File names")
						ScrollView {
							VStack(alignment: .leading, spacing: 2) {
								ForEach(Array(plan.moves.enumerated()), id: \.offset) { i, m in
									mono(m.to.path.replacingOccurrences(of: plan.folder.path + "/", with: "") + (exists[i] ? "  (already exists)" : "")).foregroundStyle(exists[i] ? Color.rose(600) : Color.ink)
								}
							}.frame(maxWidth: .infinity, alignment: .leading)
						}.frame(maxHeight: 192).fixedSize(horizontal: false, vertical: plan.moves.count < 12)
					}
					if !covers.isEmpty { GridRow { k("Cover files"); VStack(alignment: .leading) { ForEach(covers, id: \.self) { mono($0) } } } }
				}
				Text(app.deleteAfterMove ? "Only the audio files move; cover files are recreated from the embedded artwork. When they have moved you are asked whether to delete what is left of the album folder (images, logs) in the staging folder." : "Only the audio files move; cover files are recreated from the embedded artwork. Other files in the album folder (images, logs) stay in the staging folder.")
					.font(.system(size: 12)).foregroundStyle(Color.slate(500)).fixedSize(horizontal: false, vertical: true)
				ForEach(problems, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Color.rose(600)) }
			}
		}
		.onAppear { app.dialogError = nil }
		.task { let urls = album.tracks.map(\.url); art = await Task.detached { Artwork.read(urls) }.value }
	}
	func k(_ s: String) -> some View { Text(s).font(.system(size: 12)).foregroundStyle(Color.slate(500)).frame(width: 88, alignment: .leading) }
	func mono(_ s: String) -> some View { Text(s).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
}

// MARK: album artist and title (dialogs.tsx AlbumEdit)

struct AlbumEditSheet: View {
	@EnvironmentObject var app: AppState
	var album: Album
	@State private var artist = ""
	@State private var name = ""
	@State private var loaded = false
	var body: some View {
		Shell(title: "Edit album", width: 640, save: save, onClose: { app.sheet = nil }) {
			VStack(alignment: .leading, spacing: 12) {
				Field(label: "Album artist", help: "Saved as ALBUM_ARTIST_OVERRIDE and used instead of the Discogs artist. Empty removes the override and restores the Discogs artist.") {
					HStack(spacing: 4) { TextField("", text: $artist).webField(); CopyButton(text: artist) }
				}
				Field(label: "Album title", help: "Saved as ALBUM_TITLE_OVERRIDE and used instead of the Discogs title. Empty removes the override and restores the Discogs master title.") {
					HStack(spacing: 4) { TextField("", text: $name).webField(); CopyButton(text: name) }
				}
			}
		}
		.onAppear {
			guard !loaded else { return }
			loaded = true
			let t = album.tracks.first?.tags ?? [:]
			artist = t.first("ALBUM_ARTIST_OVERRIDE").isEmpty ? album.artist : t.first("ALBUM_ARTIST_OVERRIDE")
			name = t.first("ALBUM_TITLE_OVERRIDE").isEmpty ? t.first("ALBUM") : t.first("ALBUM_TITLE_OVERRIDE")
		}
	}
	func save() {
		let t = album.tracks.first?.tags ?? [:]
		let ar = artist.trimmingCharacters(in: .whitespaces), ti = name.trimmingCharacters(in: .whitespaces)
		// unchanged and no override yet: nothing to override
		let fa = ar == album.artist && t.first("ALBUM_ARTIST_OVERRIDE").isEmpty ? "" : ar
		let ft = ti == t.first("ALBUM") && t.first("ALBUM_TITLE_OVERRIDE").isEmpty ? "" : ti
		var changed: [String: String] = [:]
		if fa != t.first("ALBUM_ARTIST_OVERRIDE") { changed["ALBUM_ARTIST_OVERRIDE"] = fa }
		if ft != t.first("ALBUM_TITLE_OVERRIDE") { changed["ALBUM_TITLE_OVERRIDE"] = ft }
		app.sheet = nil
		if !changed.isEmpty { app.writeAlbumFields(album, fields: changed, tracks: [:], done: "Album saved") }
	}
}

// MARK: remove cover (dialogs.tsx CoverDelete)

struct CoverDeleteSheet: View {
	@EnvironmentObject var app: AppState
	var album: Album
	var body: some View {
		Shell(title: "Remove cover?", width: 384, saveLabel: "Remove cover", save: { app.sheet = nil; app.removeCover(album) }, onClose: { app.sheet = nil }) {
			Text("The embedded cover is removed from every file of this album, and a cover.jpg or folder image in the album folder is deleted.").font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
		}
	}
}

// MARK: lyrics (dialogs.tsx LyricsEdit, ADR 0015, 0021)

struct LyricsSheet: View {
	@EnvironmentObject var app: AppState
	@Environment(\.dialogMaxHeight) var maxH
	var album: Album
	var track: Track
	@State private var title = ""
	@State private var artist = ""
	@State private var text = ""
	@State private var res: [Lrc.Hit]?
	@State private var status: String?   // "Searching lrclib.net...", or "!error"
	@State private var used = -1
	@State private var busy = false
	@State private var searchTask: Task<Void, Never>?   // a new search replaces the running one
	@State private var loaded = false

	static let instr = "[00:00.00] [Instrumental]", intro = "[00:00.00](Spoken Intro)"
	var synced: Bool { text.range(of: #"(?m)^\s*\[\d+:\d+(\.\d+)?\]"#, options: .regularExpression) != nil }
	var lines: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : text.replacingOccurrences(of: #"\n+$"#, with: "", options: .regularExpression).split(separator: "\n", omittingEmptySubsequences: false).count }
	var length: Int { Int(track.info.duration.rounded()) }

	var body: some View {
		let h = max(288, min(maxH * 0.6, maxH - 260))
		Shell(title: "Edit lyrics", width: 1152, save: save, onClose: { app.sheet = nil }) {
			HStack(spacing: 6) {
				Text(track.url.lastPathComponent).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.slate(500)).lineLimit(1).truncationMode(.middle)
				if length > 0 { Pill(text: Inspector.mmss(Double(length)), fg: .slate(900), bg: .slate(100)) }
			}
		} content: {
			VStack(alignment: .leading, spacing: 0) {
				HStack(spacing: 8) {
					TextField("title to search for", text: $title).webField(height: 32).onSubmit { search() }
					TextField("artist to search for", text: $artist).webField(height: 32).onSubmit { search() }
					Button { search() } label: { HStack(spacing: 6) { if busy { Spinner(size: 14) } else { AssetIcon(asset: .lrclib, size: 14) }; Text("Search lrclib.net") } }
						.buttonStyle(WebButton(kind: .primary)).help("Search lrclib.net with this title and artist (not saved)")
				}.padding(8).background(Color.slate(100), in: RoundedRectangle(cornerRadius: 12))
				HStack(spacing: 8) {
					Text("Lyrics").font(.system(size: 14, weight: .medium))
					Pill(text: lines == 0 ? "Empty" : synced ? "LRC" : "TXT", fg: lines == 0 ? .slate(900) : synced ? .white : .ink, bg: lines == 0 ? .slate(200) : synced ? .emerald(500) : .amber(400), width: 64)
					Text(lines > 0 ? "\(lines) line\(lines > 1 ? "s" : "")" : "").font(.system(size: 12)).foregroundStyle(Color.slate(500))
					Spacer()
					Button("Instrumental") { text = Self.instr }.buttonStyle(WebButton(kind: .ghost, size: .xs))
					Button("Spoken Intro") { text = Self.intro }.buttonStyle(WebButton(kind: .ghost, size: .xs))
				}.padding(.top, 16).padding(.bottom, 4)
				HStack(alignment: .top, spacing: 12) {
					ZStack(alignment: .topLeading) {
						TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).lineSpacing(3).scrollContentBackground(.hidden).padding(8)
						if text.isEmpty { Text("Plain text (TXT) or synced [mm:ss.xx] lines (LRC). Empty removes the lyrics.").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.slate(400)).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false) }
					}
					.frame(maxWidth: .infinity).frame(height: h)
					.background(.white, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.slate(200)))
					if res != nil || status != nil { results.frame(width: 416, height: h) }
				}
				Text("Title and artist are only used for the search and are not saved (change them in the Tag Editor).").font(.system(size: 12)).foregroundStyle(Color.slate(500)).padding(.top, 8)
			}
		}
		.onAppear {
			guard !loaded else { return }
			loaded = true
			title = track.tags.first("TITLE"); artist = track.tags.first("ARTIST"); text = track.tags.first("LYRICS", "UNSYNCEDLYRICS")
		}
	}

	var results: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
				if let s = status {
					Text(s.hasPrefix("!") ? String(s.dropFirst()) : s).foregroundStyle(s.hasPrefix("!") ? Color.rose(600) : Color.slate(500)).padding(12)
				} else if let r = res, r.isEmpty {
					Text("No results.").foregroundStyle(Color.slate(500)).padding(12)
				} else if let r = res {
					Section {
						ForEach(Array(r.enumerated()), id: \.offset) { i, x in hit(i, x); Rectangle().fill(Color.slate(200)).frame(height: 1) }
					} header: {
						Text("\(r.count) result\(r.count > 1 ? "s" : "") on lrclib.net").fontWeight(.medium).foregroundStyle(Color.slate(600))
							.padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).background(Color.slate(100))
					}
				}
			}.font(.system(size: 12))
		}
		.overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.slate(200)))
		.clipShape(RoundedRectangle(cornerRadius: 8))
	}

	func hit(_ i: Int, _ x: Lrc.Hit) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 8) {
				Pill(text: Inspector.mmss(Double(x.duration)), fg: .slate(900), bg: .slate(100)).frame(minWidth: 40)
				VStack(alignment: .leading, spacing: 0) {
					Text("\(x.artist) - \(x.title)").fontWeight(.medium).lineLimit(1)
					Text(x.album).foregroundStyle(Color.slate(500)).lineLimit(1)
				}
			}
			HStack(spacing: 4) {
				Spacer()
				if !x.synced.isEmpty { Button("LRC") { text = x.synced; used = i }.buttonStyle(ColorPillButton(fg: .white, bg: .emerald(500))) }
				if !x.plain.isEmpty { Button("TXT") { text = x.plain; used = i }.buttonStyle(ColorPillButton(fg: .amber(950), bg: .amber(400))) }
				if x.instrumental { Button("Instrumental") { text = Self.instr; used = i }.buttonStyle(WebButton(kind: .outline, size: .xs)) }
			}
		}
		.padding(8)
		.background(length > 0 && abs(x.duration - length) <= 3 ? Color.emerald(50) : .clear)
		.overlay { if used == i { Rectangle().stroke(Color.slate(400), lineWidth: 2) } }
	}

	func search() {
		searchTask?.cancel()
		busy = true; status = "Searching lrclib.net..."
		let t = title, a = artist, len = length
		searchTask = Task {
			defer { if !Task.isCancelled { busy = false } }
			do {
				var r = try await Lrc.search(title: t, artist: a)
				if Task.isCancelled { return }
				if len > 0 { r.sort { abs($0.duration - len) < abs($1.duration - len) } }
				res = r; used = -1; status = nil
			} catch { if !Task.isCancelled { status = "!" + error.localizedDescription } }
		}
	}

	func save() {
		let t = text
		app.sheet = nil
		AppLog.app(t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "lyrics removed: \(album.name)/\(track.url.lastPathComponent)" : "lyrics edited (\(t.count) chars): \(album.name)/\(track.url.lastPathComponent)")
		app.writeTags(album, files: [track.url], done: "Track saved") { _, tags in
			tags["LYRICS"] = t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : [t]
		}
	}
}

/// A coloured `size="xs"` button (the LRC / TXT result buttons).
struct ColorPillButton: ButtonStyle {
	var fg: Color, bg: Color
	func makeBody(configuration c: Configuration) -> some View {
		c.label.font(.system(size: 12, weight: .medium)).foregroundStyle(fg).padding(.horizontal, 8).frame(height: 24)
			.background(bg, in: RoundedRectangle(cornerRadius: 6)).opacity(c.isPressed ? 0.85 : 1)
	}
}

// MARK: tag editor (dialogs.tsx TagEditor, ADR 0014, 0057, 0080)

struct TagEditorSheet: View {
	@EnvironmentObject var app: AppState
	@Environment(\.dialogMaxHeight) var maxH
	var album: Album
	var startTab = 0

	init(album: Album, startTab: Int = 0) { self.album = album; self.startTab = startTab; _tab = State(initialValue: startTab) }

	static let overrideKeys = ["ALBUM_ARTIST_OVERRIDE", "ALBUM_TITLE_OVERRIDE", "ALBUM_FORMAT_OVERRIDE", "ALBUM_EDITION", "CATALOGNUMBER_OVERRIDE"]

	@State private var tab: Int
	@State private var fields: [String: String] = [:]
	@State private var rows: [TrackRow] = []
	@State private var err: String?
	@State private var loaded = false
	@State private var contentH: CGFloat = 300

	var t0: Tags { album.tracks.first?.tags ?? [:] }

	var body: some View {
		Shell(title: "Tag editor", width: 1152, err: err, save: save, onClose: { app.sheet = nil }) {
			Spacer()
			Picker("", selection: $tab) { Text("Album").tag(0); Text("Tracks").tag(1); Text("Discogs").tag(2); Text("MusicBrainz").tag(3); Text("Other").tag(4) }
				.pickerStyle(.segmented).labelsHidden().frame(width: 460).padding(.trailing, 24)
		} content: {
			// max-h-[62vh] overflow-y-auto: as tall as the content, scrolling beyond that
			ScrollView { tabContent.background(GeometryReader { g in Color.clear.onAppear { contentH = g.size.height }.onChange(of: g.size.height) { _, h in contentH = h } }) }
				.frame(height: min(max(contentH, 40), max(300, maxH * 0.62)))
		}
		.onAppear { if !loaded { load(); loaded = true } }
	}

	var tabContent: some View {
		Group {
			switch tab {
			case 0: albumTab
			case 1: TrackTable(rows: $rows) { file in app.lyricsTrack = file; app.sheet = .lyrics }
			case 2: readOnly(Self.discogsKeys(t0), note: "Written from the Discogs release, so edit the release choice rather than these values. The overrides on the Album tab take precedence over ALBUM and ALBUMARTIST.", empty: "No Discogs tags yet. Run fixes to write them.")
			case 3: readOnly(Self.mbKeys(t0), note: "Written by the MusicBrainz release choice; the release ID itself is on the Album tab.", empty: "No MusicBrainz tags yet. Choose a MusicBrainz release.")
			default: other
			}
		}.padding(.trailing, 4).frame(maxWidth: .infinity, alignment: .leading)
	}

	func load() {
		for k in Self.overrideKeys { fields[k] = t0.first(k) }
		rows = album.tracks.map { TrackRow(track: $0) }
	}

	// MARK: Album tab

	func small(_ s: String) -> some View { Text(s).font(.system(size: 11)).foregroundStyle(Color.slate(500)) }
	func input(_ k: String) -> some View { TextField("", text: Binding(get: { fields[k] ?? "" }, set: { fields[k] = $0 })).webField() }
	func readOnlyInput(_ v: String) -> some View { Text(v.isEmpty ? " " : v).font(.system(size: 14)).foregroundStyle(Color.slate(600)).padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).background(Color.slate(50), in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.slate(200))) }

	var albumTab: some View {
		let hasID = !t0.first("DISCOGS_RELEASE_ID").isEmpty
		let discogsTitle = t0.first("ALBUM_MASTER_TITLE").isEmpty ? t0.first("ALBUM_RELEASE_TITLE") : t0.first("ALBUM_MASTER_TITLE")
		let q = [album.artist, album.title].filter { !$0.isEmpty }.joined(separator: " ")
		return VStack(alignment: .leading, spacing: 16) {
			Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 16) {
				GridRow {
					Field(label: "Album Artist Override") { input("ALBUM_ARTIST_OVERRIDE"); if hasID && !t0.first("ALBUMARTIST").isEmpty { small("ALBUM ARTIST: \(t0.first("ALBUMARTIST"))") } }
					Field(label: "Album Title Override") { input("ALBUM_TITLE_OVERRIDE"); if hasID && !discogsTitle.isEmpty { small("ALBUM TITLE: \(discogsTitle)") } }
				}
				GridRow {
					Field(label: "Album Format Override", help: "For example CD, SACD, Vinyl. Saved as ALBUM_FORMAT_OVERRIDE and kept when a Discogs release is assigned. Empty restores the Discogs format.") { input("ALBUM_FORMAT_OVERRIDE"); if !t0.first("ALBUM_FORMAT").isEmpty { small("ALBUM FORMAT: \(t0.first("ALBUM_FORMAT"))") } }
					Field(label: "Album Edition", help: "For example Remastered or Gold Disc. Part of the version string.") { input("ALBUM_EDITION") }
				}
			}
			Grid(alignment: .topLeading, horizontalSpacing: 24) {
				GridRow {
					Field(label: "Catalog # Override", help: "Part of the version string. Saved as CATALOGNUMBER_OVERRIDE and kept when a Discogs release is assigned. Empty restores the Discogs number.") { input("CATALOGNUMBER_OVERRIDE"); if !album.catalog.isEmpty { small("CATALOGNUMBER: \(album.catalog)") } }
					Field(label: "Year Release", help: "From Discogs, read-only.") { readOnlyInput(t0.first("ALBUM_RELEASE_YEAR")) }
					Field(label: "Year Master Release", help: "From Discogs, read-only.") { readOnlyInput(t0.first("ALBUM_MASTER_YEAR")) }
				}
			}
			Grid(alignment: .topLeading, horizontalSpacing: 24) {
				GridRow {
					Field(label: "Discogs Release ID") {
						HStack(spacing: 4) {
							IdBadge(service: .discogs, id: album.discogsID, full: true, query: q)
							Button { app.sheet = .discogs } label: { LucideIcon(icon: .pencil, size: 14) }.buttonStyle(IconButton(hover: .slate(100))).help(album.discogsID.isEmpty ? "Choose the Discogs release" : "Change the Discogs release")
						}.padding(.vertical, 4)
					}.frame(maxWidth: .infinity, alignment: .leading)
					Field(label: "Musicbrainz Release ID") {
						HStack(spacing: 4) {
							IdBadge(service: .musicbrainz, id: album.mbid, full: true, query: q)
							Button { app.sheet = .musicbrainz } label: { LucideIcon(icon: .pencil, size: 14) }.buttonStyle(IconButton(hover: .slate(100))).help(album.mbid.isEmpty ? "Choose the MusicBrainz release" : "Change the MusicBrainz release")
						}.padding(.vertical, 4)
					}.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
		}
	}

	// MARK: read-only tabs (ADR 0057)

	static let discogsFixed = ["ALBUM_ARTIST_OVERRIDE", "ALBUM_TITLE_OVERRIDE", "ALBUMARTIST", "ALBUM", "ALBUM_FORMAT", "CATALOGNUMBER", "VERSION", "DATE", "COUNTRY", "COMPOSER", "PRODUCER", "ENGINEER"]
	static func discogsKeys(_ t: Tags) -> [String] {
		let prefixes = ["DISCOGS_", "ALBUM_RELEASE_", "ALBUM_COMPANY_", "ALBUM_CREDIT_", "ALBUM_IDENT_", "ALBUM_MASTER_"]
		return discogsFixed.filter { t[$0] != nil && !["ALBUM_ARTIST_OVERRIDE", "ALBUM_TITLE_OVERRIDE"].contains($0) } + t.keys.filter { k in prefixes.contains { k.hasPrefix($0) } && k != "DISCOGS_RELEASE_ID" }.sorted()
	}
	static func mbKeys(_ t: Tags) -> [String] {
		t.keys.filter { $0.hasPrefix("MUSICBRAINZ") && !["MUSICBRAINZ_ALBUMID", "MUSICBRAINZ ALBUM ID"].contains($0) }.sorted() + ["BARCODE", "ASIN"].filter { t[$0] != nil }
	}
	static let notOther: Set<String> = ["TITLE", "ARTIST", "TRACKNUMBER", "DISCNUMBER", "LYRICS", "UNSYNCEDLYRICS", "SET SUBTITLE", "DISCSUBTITLE", "ALBUM_EDITION", "ALBUM_FORMAT_OVERRIDE", "CATALOGNUMBER_OVERRIDE", "DISCOGS_RELEASE_ID", "MUSICBRAINZ_ALBUMID", "MUSICBRAINZ ALBUM ID"]

	func note(_ s: String) -> some View { Text(s).font(.system(size: 13)).foregroundStyle(Color.slate(600)).padding(.bottom, 12).fixedSize(horizontal: false, vertical: true) }
	func keyCell(_ k: String) -> some View { Text(k).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.slate(700)).frame(width: 288, alignment: .topLeading) }

	func readOnly(_ keys: [String], note n: String, empty: String) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			note(n)
			if keys.isEmpty { Text(empty).font(.system(size: 14)).foregroundStyle(Color.slate(500)) }
			ForEach(keys, id: \.self) { k in
				HStack(alignment: .top, spacing: 0) {
					keyCell(k)
					Text((t0[k] ?? []).joined(separator: " / ")).font(.system(size: 14)).foregroundStyle(Color.slate(700)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
				}.padding(.vertical, 4).overlay(alignment: .bottom) { Rectangle().fill(Color.slate(200)).frame(height: 1) }
			}
		}
	}

	var other: some View {
		let all = album.tracks.map(\.tags)
		let shown = Set(Self.discogsKeys(t0) + Self.mbKeys(t0)).union(Self.notOther)
		let keys = Set(all.flatMap(\.keys)).subtracting(shown).sorted()
		return VStack(alignment: .leading, spacing: 0) {
			note("Every other tag in the files, as the first file has it. Lyrics are edited per track. These are read-only.")
			if keys.isEmpty { Text("No other tags.").font(.system(size: 14)).foregroundStyle(Color.slate(500)) }
			ForEach(keys, id: \.self) { k in
				let vals = all.map { ($0[k] ?? []).joined(separator: " / ") }
				let have = vals.filter { !$0.isEmpty }
				let v = (t0[k] ?? []).joined(separator: " / ")
				HStack(alignment: .top, spacing: 0) {
					keyCell(k)
					Text(v).font(.system(size: 14)).foregroundStyle(Color.slate(700)).lineLimit(2).help(v).frame(maxWidth: .infinity, alignment: .leading)
					Text([have.count < all.count ? "\(have.count) of \(all.count) files" : "", Set(have).count > 1 ? "differs" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
						.font(.system(size: 12)).foregroundStyle(Color.slate(500)).frame(width: 144, alignment: .trailing)
				}.padding(.vertical, 4).overlay(alignment: .bottom) { Rectangle().fill(Color.slate(200)).frame(height: 1) }
			}
		}
	}

	// MARK: save (the dialog closes at once; the step circles spin until it is written)

	func save() {
		var changed: [String: String] = [:]
		for k in Self.overrideKeys where (fields[k] ?? "").trimmingCharacters(in: .whitespaces) != t0.first(k) { changed[k] = fields[k] ?? "" }
		var edited: [String: TrackRow] = [:]
		for r in rows { if let o = album.tracks.first(where: { $0.id == r.id }), TrackRow(track: o) != r { edited[r.id] = r } }
		if changed.isEmpty && edited.isEmpty { app.sheet = nil; return }
		if edited.values.contains(where: { [$0.title, $0.disc, $0.track].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty } }) { err = "Title, disc and track must not be empty."; return }
		app.sheet = nil
		app.writeAlbumFields(album, fields: changed, tracks: edited, done: "Tags saved")
	}
}

/// One row of the tag editor's track table.
struct TrackRow: Equatable, Identifiable {
	var id: String, file: String, disc: String, track: String, title: String, artist: String, subtitle: String
	var length: Double, format: String, formatHelp: String, channels: Int, lyrics: LyricsKind
	init(track t: Track) {
		id = t.id; file = t.url.lastPathComponent
		disc = t.tags.first("DISCNUMBER"); track = t.tags.first("TRACKNUMBER"); title = t.tags.first("TITLE"); artist = t.tags.first("ARTIST"); subtitle = t.tags.first("SET SUBTITLE")
		length = t.info.duration; format = t.formatLabel; formatHelp = t.formatHelp; channels = t.info.channels; lyrics = t.lyricsKind
	}
	static func == (a: TrackRow, b: TrackRow) -> Bool { a.id == b.id && a.disc == b.disc && a.track == b.track && a.title == b.title && a.artist == b.artist && a.subtitle == b.subtitle }
}

/// track-table.tsx: shift-click selects a range, bulk set and renumber act on the selection, dragging a row (or the
/// selection) reorders; disc and track numbers and the subtitle stay with the positions; subtitle dividers (ADR 0081).
struct TrackTable: View {
	@Binding var rows: [TrackRow]
	var openLyrics: (String) -> Void
	@State private var sel = Set<String>()
	@State private var anchor: Int?
	@State private var field = "disc"
	@State private var value = ""
	@State private var start = "1"
	@State private var drag: String?
	@State private var over: Int?
	@State private var editing: (id: String, add: Bool)?

	var chosen: Int { rows.filter { sel.contains($0.id) }.count }
	var multi: Bool { Set(rows.map(\.disc)).count > 1 }
	func same(_ a: TrackRow, _ b: TrackRow) -> Bool { a.disc == b.disc && a.subtitle == b.subtitle }
	func runEnd(_ i: Int) -> Int { var j = i; while j + 1 < rows.count && same(rows[j + 1], rows[i]) { j += 1 }; return j }
	func setRun(_ i: Int, _ text: String, to: Int? = nil) { let e = to ?? runEnd(i); for k in i...e { rows[k].subtitle = text.trimmingCharacters(in: .whitespaces) } }

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			bar
			VStack(spacing: 0) {
				header
				ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
					let discStart = i == 0 || r.disc != rows[i - 1].disc
					let change = !discStart && r.subtitle != rows[i - 1].subtitle
					let end = runEnd(i)
					if change || (discStart && (multi || !r.subtitle.isEmpty)) {
						SubtitleDivider(disc: discStart && multi ? r.disc : nil, inside: change, subtitle: r.subtitle, count: end - i + 1,
							editing: editing?.id == r.id && editing?.add == false, onEdit: { editing = (r.id, false) },
							onSet: { t in setRun(i, t); editing = nil }, onCancel: { editing = nil },
							onRemove: change ? { setRun(i, rows[i - 1].subtitle) } : nil)
					}
					if !discStart && !change {
						if editing?.id == r.id && editing?.add == true {
							SubtitleDivider(inside: true, subtitle: "", count: end - i + 1, editing: true, onEdit: {}, onSet: { t in if !t.trimmingCharacters(in: .whitespaces).isEmpty { setRun(i, t) }; editing = nil }, onCancel: { editing = nil })
						} else { DividerGap { editing = (r.id, true) } }
					}
					row(i, r)
				}
				Color.clear.frame(height: 16).overlay(alignment: .top) { if over == rows.count { Rectangle().fill(Color.slate(800)).frame(height: 2) } }
					.onDrop(of: [.text], isTargeted: Binding(get: { over == rows.count }, set: { if $0 { over = rows.count } })) { _ in move(rows.count); return true }
			}
		}
	}

	var bar: some View {
		HStack(spacing: 8) {
			Text(chosen > 0 ? "\(chosen) selected" : "Click the boxes (shift-click for a range) to select tracks").foregroundStyle(Color.slate(600)).padding(.horizontal, 4)
			if chosen > 0 {
				Picker("", selection: $field) { Text("Disc").tag("disc"); Text("Artist").tag("artist"); Text("Track").tag("track") }.labelsHidden().frame(width: 90)
				TextField("value for all selected", text: $value).webField(height: 32).frame(width: 192)
				Button("Set") { for k in rows.indices where sel.contains(rows[k].id) { switch field { case "disc": rows[k].disc = value; case "artist": rows[k].artist = value; default: rows[k].track = value } } }.buttonStyle(WebButton(kind: .outline))
				Text("Renumber from").foregroundStyle(Color.slate(600)).padding(.leading, 8)
				TextField("", text: $start).webField(height: 32).frame(width: 64)
				Button("Renumber") { guard var n = Int(start) else { return }; for k in rows.indices where sel.contains(rows[k].id) { rows[k].track = "\(n)"; n += 1 } }.buttonStyle(WebButton(kind: .outline))
				Button("Clear") { sel = [] }.buttonStyle(WebButton(kind: .ghost))
			}
			Spacer(minLength: 0)
		}
		.font(.system(size: 14)).padding(8).frame(minHeight: 48).background(Color.slate(100), in: RoundedRectangle(cornerRadius: 12))
	}

	var header: some View {
		HStack(spacing: 8) {
			Color.clear.frame(width: 20)
			Toggle("", isOn: Binding(get: { !rows.isEmpty && sel.count == rows.count }, set: { sel = $0 ? Set(rows.map(\.id)) : [] })).toggleStyle(.checkbox).labelsHidden().frame(width: 20).help("Select all")
			Text("Disc").frame(width: 56, alignment: .leading); Text("Track").frame(width: 56, alignment: .leading)
			Text("Title").frame(minWidth: 160, maxWidth: .infinity, alignment: .leading); Text("Artist").frame(minWidth: 128, maxWidth: .infinity, alignment: .leading)
			Text("Time").frame(width: 40, alignment: .trailing); Text("Rate/bits").frame(width: 72, alignment: .leading); Text("Channels").frame(width: 56, alignment: .leading); Text("Lyrics").frame(width: 44, alignment: .leading); Color.clear.frame(width: 20)
		}.font(.system(size: 12, weight: .medium)).foregroundStyle(Color.slate(500)).padding(.bottom, 4)
	}

	func cell(_ i: Int, _ kp: WritableKeyPath<TrackRow, String>) -> some View {
		TextField("", text: Binding(get: { rows[i][keyPath: kp] }, set: { rows[i][keyPath: kp] = $0 })).webField(height: 28)
	}

	func row(_ i: Int, _ r: TrackRow) -> some View {
		HStack(spacing: 8) {
			LucideIcon(icon: .gripVertical, size: 16).foregroundStyle(Color.slate(400)).frame(width: 20).contentShape(Rectangle())
				.onHover { $0 ? NSCursor.openHand.push() : NSCursor.pop() }
				.onDrag { drag = r.id; return NSItemProvider(object: r.id as NSString) }.help("Drag to reorder")
			Toggle("", isOn: Binding(get: { sel.contains(r.id) }, set: { _ in click(i) })).toggleStyle(.checkbox).labelsHidden().frame(width: 20)
			cell(i, \.disc).frame(width: 56); cell(i, \.track).frame(width: 56)
			cell(i, \.title).frame(minWidth: 160, maxWidth: .infinity); cell(i, \.artist).frame(minWidth: 128, maxWidth: .infinity)
			Text(Inspector.mmss(r.length)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.slate(500)).frame(width: 40, alignment: .trailing)
			Pill(text: r.format, fg: .slate(700), bg: .white, border: true, width: 72).monospacedDigit().help(r.formatHelp)
			ChannelBadge(n: r.channels).frame(width: 56, alignment: .leading)
			LyricsBadge(kind: r.lyrics).frame(width: 44, alignment: .leading)
			Button { openLyrics(r.id) } label: { LucideIcon(icon: .pencil, size: 12) }.buttonStyle(IconButton(hover: .slate(100))).help("Edit lyrics").frame(width: 20)
		}
		.padding(.vertical, 2)
		.background(sel.contains(r.id) ? Color.sky(50) : .clear)
		.opacity(drag == r.id || (drag != nil && sel.contains(r.id) && sel.contains(drag!) && sel.count > 1) ? 0.5 : 1)
		.overlay(alignment: .top) { if over == i { Rectangle().fill(Color.slate(800)).frame(height: 2) } }
		.onDrop(of: [.text], isTargeted: Binding(get: { over == i }, set: { if $0 { over = i } else if over == i { over = nil } })) { _ in move(i); return true }
	}

	func click(_ i: Int) {
		let shift = NSEvent.modifierFlags.contains(.shift)
		if shift, let a = anchor {
			let on = !sel.contains(rows[i].id)
			for k in min(a, i)...max(a, i) { if on { sel.insert(rows[k].id) } else { sel.remove(rows[k].id) } }
		} else {
			if sel.contains(rows[i].id) { sel.remove(rows[i].id) } else { sel.insert(rows[i].id) }
			anchor = i
		}
	}

	/// The moved rows (the selection when the dragged row is part of it) go before row `at`; numbers and subtitles
	/// stay with the positions.
	func move(_ at: Int) {
		defer { drag = nil; over = nil }
		guard let d = drag else { return }
		let moving = sel.contains(d) ? sel : [d]
		if at < rows.count, moving.contains(rows[at].id) { return }
		let rest = rows.filter { !moving.contains($0.id) }, moved = rows.filter { moving.contains($0.id) }
		let pos = at < rows.count ? rest.firstIndex(where: { $0.id == rows[at].id }) ?? rest.count : rest.count
		var order = Array(rest[..<pos]) + moved + Array(rest[pos...])
		for k in order.indices { order[k].disc = rows[k].disc; order[k].track = rows[k].track; order[k].subtitle = rows[k].subtitle }
		rows = order
	}
}

/// A divider band of a track list (subtitle-divider.tsx, ADR 0081): the subtitle of the run below it, with a pen to
/// change it; "Disc N" chip for multi-disc albums; `inside` indents it and `onRemove` adds the ×. The import dialogs
/// add `keep` (Release / Keep mine), `was` and `differs`.
struct SubtitleDivider: View {
	var disc: String? = nil
	var inside = false
	var subtitle: String
	var count: Int
	var editing: Bool
	var onEdit: () -> Void
	var onSet: (String) -> Void
	var onCancel: () -> Void
	var onRemove: (() -> Void)? = nil
	var keep: Bool? = nil
	var onKeep: ((Bool) -> Void)? = nil
	var was: String? = nil
	var differs = false
	var disabled = false
	@State private var text = ""
	@FocusState private var focus: Bool

	var body: some View {
		let grey = keep == true || disabled
		HStack(spacing: 8) {
			if let disc { Text("Disc \(disc)").font(.system(size: 11, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 2).background(Color.sky(900), in: Capsule()) }
			if editing {
				TextField("", text: $text).webField(height: 28, border: .sky(400)).focused($focus).onSubmit { onSet(text) }.onExitCommand { onCancel() }
				Button("Set") { onSet(text) }.buttonStyle(WebButton(kind: .primary, size: .xs))
				Button("Cancel", action: onCancel).buttonStyle(WebButton(kind: .outline, size: .xs))
			} else {
				VStack(alignment: .leading, spacing: 0) {
					HStack(spacing: 8) {
						Text(subtitle.isEmpty ? "No subtitle" : subtitle).font(.system(size: 14)).italic(subtitle.isEmpty).lineLimit(1)
							.foregroundStyle(keep == true ? Color.slate(400) : subtitle.isEmpty ? .slate(400) : .sky(950)).help(subtitle)
						if differs && !disabled { Text("differs from your subtitles").font(.system(size: 11)).foregroundStyle(Color.yellow(800)).padding(.horizontal, 8).background(Color.yellow(100), in: Capsule()) }
					}
					if let was { Text("Was: \(was.isEmpty ? "(none)" : was)").font(.system(size: 11)).foregroundStyle(Color.slate(400)).lineLimit(1).help(was) }
				}.frame(maxWidth: .infinity, alignment: .leading)
				if let onKeep, !disabled {
					HStack(spacing: 0) {
						Button("Release") { onKeep(false) }.buttonStyle(SegmentButton(on: keep != true))
						Button("Keep mine") { onKeep(true) }.buttonStyle(SegmentButton(on: keep == true))
					}.overlay(Capsule().stroke(Color.slate(300))).clipShape(Capsule())
				}
				Text("\(count) \(count == 1 ? "file" : "files")").font(.system(size: 12)).foregroundStyle(Color.slate(500))
				if !disabled { Button(action: onEdit) { LucideIcon(icon: .pencil, size: 12) }.buttonStyle(IconButton(color: .slate(600))).help("Edit the subtitle") }
				if let onRemove, !disabled { Button(action: onRemove) { LucideIcon(icon: .x, size: 12) }.buttonStyle(IconButton(color: .slate(400), hoverText: .slate(700))).help("Remove this divider") }
			}
		}
		.padding(.horizontal, 8).padding(.vertical, 4).frame(minHeight: 36)
		.background(grey ? Color.slate(100) : .sky(50))
		.overlay(alignment: .top) { Rectangle().fill(grey ? Color.slate(200) : .sky(200)).frame(height: 1) }
		.overlay(alignment: .bottom) { Rectangle().fill(grey ? Color.slate(200) : .sky(200)).frame(height: 1) }
		.overlay(alignment: .leading) { if inside { Rectangle().fill(grey ? Color.slate(300) : .sky(300)).frame(width: 4) } }
		.opacity(disabled ? 0.6 : 1)
		.padding(.leading, inside ? 16 : 0).padding(.top, 8)
		.onAppear { if editing { text = subtitle; DispatchQueue.main.async { focus = true } } }
		.onChange(of: editing) { _, e in if e { text = subtitle; DispatchQueue.main.async { focus = true } } }
	}
}

struct SegmentButton: ButtonStyle {
	var on: Bool
	func makeBody(configuration c: Configuration) -> some View {
		c.label.font(.system(size: 11)).foregroundStyle(on ? .white : Color.slate(600)).padding(.horizontal, 10).padding(.vertical, 2)
			.background(on ? Color.slate(800) : .clear).contentShape(Rectangle())
	}
}

/// The gap between two tracks: a dashed line and "+ divider here" while the pointer is near.
struct DividerGap: View {
	var onAdd: () -> Void
	@State private var over = false
	var body: some View {
		Color.clear.frame(height: 4)
			.overlay {
				Button(action: onAdd) {
					ZStack {
						Line().stroke(Color.sky(300), style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(height: 1).padding(.horizontal, 4)
						HStack(spacing: 4) { LucideIcon(icon: .plus, size: 12); Text("divider here") }.font(.system(size: 11)).foregroundStyle(Color.sky(700)).padding(.horizontal, 8).background(.white)
					}.frame(height: 20).contentShape(Rectangle())
				}.buttonStyle(.plain).opacity(over ? 1 : 0).onHover { over = $0 }.help("Add a divider here")
			}
			.zIndex(1)
	}
	struct Line: Shape { func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: r.minX, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } } }
}

// MARK: release search and assignment (releases.tsx, ADR 0013, 0053, 0078, 0081, 0089)

/// One file of the assignment, as the web dialog keeps it: `rel` the release track, `d` / `t` / `nt` the owner's
/// overrides of disc, track and title, `ad` / `at` the default numbering.
struct AFile { var i: Int; var key: String; var rel: Int?; var conf: Double; var d: Int?; var t: Int?; var nt: String?; var ad = 0, at = 0 }
struct Ovr { var text: String?; var keep: Bool?; var split = false; var merge = false }
struct ARun { var start: Int, key: String, disc: Int, relSub: String, inside: Bool, idx: [Int], text = "", keep = false, was = "", differs = false }

struct Assignment {
	var tracks: [DTrack] = []
	var files: [AFile] = []
	var ovr: [String: Ovr] = [:]

	init() {}
	init(album: Album, tracks: [DTrack]) {
		self.tracks = tracks
		let p = Assign.proposeScored(files: album.tracks, release: tracks)
		files = album.tracks.enumerated().map { i, t in AFile(i: i, key: t.id, rel: p[i].0, conf: p[i].1) }
		// the dividers name the release's disc, so the files are listed in that order too (ADR 0089)
		files.sort { a, b in (a.rel == nil ? 1 : 0, a.rel ?? 0, a.i) < (b.rel == nil ? 1 : 0, b.rel ?? 0, b.i) }
		number()
	}

	/// Default numbering (the server's rule): 1..n per disc in release order.
	mutating func number() {
		let sel = files.indices.filter { files[$0].rel != nil }.sorted { files[$0].rel! < files[$1].rel! }
		let discs = Array(Set(sel.map { tracks[files[$0].rel!].disc })).sorted()
		var seen: [Int: Int] = [:]
		for k in sel { let d = tracks[files[k].rel!].disc; seen[d, default: 0] += 1; files[k].ad = (discs.firstIndex(of: d) ?? 0) + 1; files[k].at = seen[d]! }
	}
	var used: [Int: Int] { var u: [Int: Int] = [:]; for f in files { if let r = f.rel { u[r, default: 0] += 1 } }; return u }
	var dup: Bool { used.values.contains { $0 > 1 } }
	var n: Int { used.count }

	/// Runs of the subtitle dividers: neighbouring assigned files whose release tracks share a disc and a subtitle.
	func runs(_ album: Album) -> (runs: [ARun], subOf: [String: String?], multi: Bool) {
		var out: [ARun] = []
		var lastSub = ""
		for (i, f) in files.enumerated() {
			guard let r = f.rel else { continue }
			let t = tracks[r], relSub = t.subtitle, o = ovr[f.key]
			let discStart = out.last == nil || t.disc != out.last!.disc
			if out.isEmpty || discStart || ((relSub != lastSub || o?.split == true) && o?.merge != true) {
				out.append(ARun(start: i, key: f.key, disc: t.disc, relSub: relSub, inside: !discStart, idx: []))
			}
			out[out.count - 1].idx.append(i); lastSub = relSub
		}
		var subOf: [String: String?] = [:]
		for k in out.indices {
			let o = ovr[out[k].key]
			let was = Array(NSOrderedSet(array: out[k].idx.map { album.tracks[files[$0].i].tags.first("SET SUBTITLE", "DISCSUBTITLE") }.filter { !$0.isEmpty })) as? [String] ?? []
			out[k].text = o?.text ?? out[k].relSub
			out[k].differs = was.contains { $0 != out[k].relSub }
			out[k].keep = o?.keep ?? out[k].differs
			out[k].was = was.joined(separator: " · ")
			let v = out[k].text.trimmingCharacters(in: .whitespaces)
			for i in out[k].idx { subOf.updateValue(out[k].keep || v.isEmpty ? nil : v, forKey: files[i].key) }
		}
		return (out, subOf, Set(out.map(\.disc)).count > 1)
	}

	func items(_ album: Album) -> [(Assign.Item, Int)] {
		let s = runs(album).subOf
		return files.compactMap { f in
			guard let r = f.rel else { return nil }
			let t = album.tracks[f.i]
			return (Assign.Item(url: t.url, track: tracks[r], disc: f.d ?? f.ad, number: f.t ?? f.at, title: f.nt ?? tracks[r].title, subtitle: (s[f.key] ?? nil) ?? ""), r)
		}
	}
}

/// The file -> release track table of both dialogs.
struct AssignTable: View {
	var album: Album
	@Binding var a: Assignment
	var numbers: Bool
	@State private var editing: String?

	var body: some View {
		let r = a.runs(album), used = a.used
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 8) {
				Text("File and title").frame(maxWidth: .infinity, alignment: .leading); Text("Disc").frame(width: 64, alignment: .leading); Text("Track").frame(width: 64, alignment: .leading)
				Text("Release track").frame(width: 288, alignment: .leading); Color.clear.frame(width: 72)
			}.font(.system(size: 12)).foregroundStyle(Color.slate(500)).padding(.bottom, 4)
			ForEach(Array(a.files.enumerated()), id: \.element.key) { k, f in
				let run = r.runs.first { $0.start == k }
				let o = run.flatMap { a.ovr[$0.key] }
				if let run, run.inside || r.multi || !run.relSub.isEmpty || o?.text != nil {
					SubtitleDivider(disc: !run.inside && r.multi ? "\(run.disc)" : nil, inside: run.inside, subtitle: run.text, count: run.idx.count,
						editing: editing == run.key, onEdit: { editing = run.key },
						onSet: { t in editing = nil; if t.trimmingCharacters(in: .whitespaces).isEmpty && o?.split == true && o?.text == nil { a.ovr[run.key] = nil } else { var n = o ?? Ovr(); n.text = t.trimmingCharacters(in: .whitespaces); n.keep = false; a.ovr[run.key] = n } },
						onCancel: { editing = nil; if o?.split == true && o?.text == nil { a.ovr[run.key] = nil } },
						onRemove: run.inside ? { if o?.split == true { a.ovr[run.key] = nil } else { var n = o ?? Ovr(); n.merge = true; a.ovr[run.key] = n } } : nil,
						keep: run.keep, onKeep: { v in var n = o ?? Ovr(); n.keep = v; a.ovr[run.key] = n }, was: run.was, differs: run.differs, disabled: !numbers)
				}
				if numbers, f.rel != nil, run == nil, a.files[..<k].contains(where: { $0.rel != nil }) {
					DividerGap { var n = Ovr(); n.split = true; n.text = ""; a.ovr[f.key] = n; editing = f.key }
				}
				row(k, f, used: used)
				Rectangle().fill(Color.slate(200)).frame(height: 1)
			}
		}
	}

	func row(_ k: Int, _ f: AFile, used: [Int: Int]) -> some View {
		let t = album.tracks[f.i]
		return HStack(alignment: .center, spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				Text("File: \(t.url.lastPathComponent) · \(Inspector.mmss(t.info.duration))").font(.system(size: 12)).foregroundStyle(Color.slate(400)).lineLimit(1).help(t.url.lastPathComponent)
				if numbers, let r = f.rel {
					HStack(spacing: 8) {
						TextField("", text: Binding(get: { a.files[k].nt ?? a.tracks[r].title }, set: { a.files[k].nt = $0 })).webField(height: 28, tint: .sky(50), border: .sky(300)).help("New title from the release; editable")
						ChannelBadge(n: t.info.channels)
					}
					HStack(spacing: 2) { Text("Was: \(t.title)").lineLimit(1); CopyButton(text: t.title, title: "Copy the old title") }.font(.system(size: 12)).foregroundStyle(Color.slate(400))
				} else {
					HStack(spacing: 8) { Text(t.title).foregroundStyle(Color.slate(400)).lineLimit(1).frame(maxWidth: 320, alignment: .leading).help(t.url.lastPathComponent); ChannelBadge(n: t.info.channels) }
				}
			}.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
			num(k, \.d, f.ad, f.rel != nil).frame(width: 64, alignment: .leading)
			num(k, \.t, f.at, f.rel != nil).frame(width: 64, alignment: .leading)
			Picker("", selection: Binding(get: { f.rel ?? -1 }, set: { v in a.files[k].rel = v < 0 ? nil : v; a.files[k].conf = 1; a.files[k].d = nil; a.files[k].t = nil; a.files[k].nt = nil; a.number() })) {
				Text("Skip (leave as is)").tag(-1)
				ForEach(a.tracks) { r in Text("\(r.number)  \(r.title)\(r.seconds > 0 ? " (\(Inspector.mmss(Double(r.seconds))))" : "")").tag(r.id) }
			}.labelsHidden().frame(width: 288)
			.overlay { if let r = f.rel, (used[r] ?? 0) > 1 { RoundedRectangle(cornerRadius: 6).stroke(Color.rose(500)) } }
			Group {
				if f.rel == nil { Pill(text: "skip", fg: .slate(900), bg: .slate(100)) }
				else if f.conf >= 0.6 { Pill(text: "match", fg: .emerald(800), bg: .emerald(100)) }
				else { Pill(text: "check", fg: .amber(800), bg: .amber(100)) }
			}.frame(width: 72, alignment: .trailing).padding(.trailing, 12)
		}
	}

	@ViewBuilder func num(_ k: Int, _ kp: WritableKeyPath<AFile, Int?>, _ def: Int, _ on: Bool) -> some View {
		if on {
			TextField("", text: Binding(get: { "\(a.files[k][keyPath: kp] ?? def)" }, set: { a.files[k][keyPath: kp] = Int($0) })).webField(height: 28, tint: numbers ? .white : .slate(50))
				.foregroundStyle(numbers ? Color.ink : .slate(400)).disabled(!numbers).frame(width: 56)
		}
	}
}

/// Search result rows of both dialogs (releases.tsx Results).
struct ResultRow: Identifiable { var id: String, thumb: URL?, title: String, match: String, matchHelp: String, sub: String, year: String, catno: String, tracks: String, n: Int }

struct ReleaseResults: View {
	var rows: [ResultRow]
	var pick: (String) -> Void
	@State private var sortKey = ""
	@State private var dir = 1
	var sorted: [ResultRow] {
		guard !sortKey.isEmpty else { return rows }
		func v(_ r: ResultRow) -> Int { sortKey == "year" ? Int(r.year.prefix(4)) ?? 0 : r.n }
		return rows.sorted { a, b in let x = v(a), y = v(b); if (x == 0) != (y == 0) { return y == 0 }; return dir > 0 ? x < y : x > y }
	}
	var body: some View {
		if rows.isEmpty { Text("No releases found.").font(.system(size: 14)).foregroundStyle(Color.slate(500)) } else {
			LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
				Section {
					ForEach(sorted) { r in ResultLine(r: r) { pick(r.id) } }
				} header: {
					HStack(spacing: 8) {
						Color.clear.frame(width: 48)
						Text("Release").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
						th("year", "Year").frame(width: 80, alignment: .leading)
						Text("Cat. no.").font(.system(size: 12, weight: .medium)).frame(width: 144, alignment: .leading)
						th("tracks", "Tracks").frame(width: 96, alignment: .leading)
						Color.clear.frame(width: 64)
					}.padding(.vertical, 4).background(.white)
				}
			}.font(.system(size: 14))
		}
	}
	func th(_ k: String, _ l: String) -> some View {
		Button { if sortKey == k { dir = -dir } else { sortKey = k; dir = 1 } } label: { Text(l + (sortKey == k ? (dir > 0 ? " ▲" : " ▼") : "")).font(.system(size: 12)).padding(.horizontal, 4).padding(.vertical, 2) }
			.buttonStyle(WebButton(kind: .ghost, size: .xs))
	}
}

struct ResultLine: View {
	var r: ResultRow
	var pick: () -> Void
	@State private var over = false
	var body: some View {
		HStack(spacing: 8) {
			AsyncImage(url: r.thumb) { $0.resizable().scaledToFill() } placeholder: { Color.slate(100) }.frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 4)).frame(width: 48)
			VStack(alignment: .leading, spacing: 0) {
				HStack(spacing: 4) {
					Text(r.title).fontWeight(.medium).lineLimit(1)
					if !r.match.isEmpty { Pill(text: "\(r.match) match", fg: .emerald(800), bg: .emerald(100)).help(r.matchHelp) }
				}
				Text(r.sub).font(.system(size: 12)).foregroundStyle(Color.slate(500)).lineLimit(1)
			}.frame(maxWidth: .infinity, alignment: .leading)
			Text(r.year).monospacedDigit().frame(width: 80, alignment: .leading)
			Text(r.catno).font(.system(size: 12, design: .monospaced)).lineLimit(2).frame(width: 144, alignment: .leading)
			Text(r.tracks).font(.system(size: 12)).foregroundStyle(Color.slate(500)).frame(width: 96, alignment: .leading)
			Button("Select", action: pick).buttonStyle(WebButton(kind: .outline, size: .xs)).frame(width: 64, alignment: .trailing)
		}
		.padding(.vertical, 4).background(over ? Color.slate(50) : .clear)
		.overlay(alignment: .top) { Rectangle().fill(Color.slate(200)).frame(height: 1) }
		.contentShape(Rectangle()).onHover { over = $0 }.onTapGesture(perform: pick).pointer()
	}
}

/// Spinner pill over a dialog's result area while a request runs.
struct BusyOverlay: View {
	var text: String
	var body: some View {
		HStack(spacing: 8) { Spinner(size: 16); Text(text) }.font(.system(size: 14)).foregroundStyle(Color.slate(700))
			.padding(.horizontal, 16).padding(.vertical, 8).background(.white, in: Capsule()).overlay(Capsule().stroke(Color.slate(200))).shadow(radius: 3)
	}
}

/// Artist / Album / Year / Catalog # with copy buttons, for searching by hand.
struct AlbumFacts: View {
	var album: Album
	var body: some View {
		HStack(spacing: 12) {
			ForEach([("Artist", album.artist), ("Album", album.tracks.first?.tags.first("ALBUM") ?? ""), ("Year", album.dateYear), ("Catalog #", album.catalog)].filter { !$0.1.isEmpty }, id: \.0) { k, v in
				HStack(spacing: 0) { Text("\(k): \(v)"); CopyButton(text: v) }
			}
		}.font(.system(size: 12)).foregroundStyle(Color.slate(500)).padding(.top, 4)
	}
}

func titlesHint(_ on: Bool) -> some View {
	VStack(alignment: .leading, spacing: 4) {
		Text("Off: only the album data is imported (release IDs, CATALOGNUMBER, year and country); the files keep their TITLE, ARTIST, TRACKNUMBER, DISCNUMBER and DISCSUBTITLE.\nOn: the files also get the release's TITLE, ARTIST, TRACKNUMBER, DISCNUMBER and DISCSUBTITLE.")
		if on { Text("Blue fields: data from the release that will be written (editable). Grey text: what the file has now. “Keep mine” writes no subtitle for that part.") }
	}.font(.system(size: 12)).foregroundStyle(Color.slate(500)).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
}

struct DiscogsSheet: View {
	@EnvironmentObject var app: AppState
	@Environment(\.dialogMaxHeight) var maxH
	var album: Album
	@AppStorage("importTitles_discogs") private var titles = true
	@State private var q = ""
	@State private var rows: [DiscogsHit]?
	@State private var raw: [String: Any]?
	@State private var rid = 0
	@State private var a = Assignment()
	@State private var busy = false
	@State private var what = ""
	@State private var err: String?
	@State private var searchTask: Task<Void, Never>?
	@State private var mb: MBRelease?
	@State private var loaded = false

	var applying: Bool { app.job?.hasPrefix("Applying") == true }

	var body: some View {
		Shell(title: "Assign tracks to a release", width: 1024, err: a.dup ? "A release track is assigned to more than one file." : err,
			saveLabel: applying ? "Applying…" : raw != nil ? "Apply (\(a.n) of \(album.tracks.count))" : "Apply", saveDisabled: raw == nil || a.dup || a.n == 0 || busy || applying, danger: applying, save: apply, onClose: { app.sheet = nil }) {
			VStack(alignment: .leading, spacing: 0) {
				HStack(spacing: 8) {
					TextField("Artist and album, or a Discogs release ID", text: $q).webField().onSubmit { search() }
					Button { search() } label: { HStack(spacing: 6) { if busy { Spinner(size: 14) }; Text("Search Discogs") } }.buttonStyle(WebButton(kind: .primary))
						.help(busy ? "Stops the running request and starts a new search" : "")
				}
				AlbumFacts(album: album)
				ZStack {
					ScrollView {
						Group {
							if raw != nil { assignView } else if let rows { ReleaseResults(rows: rows.map(row), pick: { if let id = Int($0) { pick(id) } }) }
						}.frame(maxWidth: .infinity, alignment: .leading)
					}
					.frame(height: max(192, maxH * 0.6)).opacity(busy ? 0.5 : 1).allowsHitTesting(!busy)
					if busy { BusyOverlay(text: what) }
				}.padding(.top, 16)
			}
		}
		.onAppear {
			guard !loaded else { return }
			loaded = true
			q = [album.artist, album.tracks.first?.tags.first("ALBUM") ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
			if let id = Int(album.discogsID) { pick(id) }
			Task { if !album.mbid.isEmpty { mb = await MusicBrainz.release(album.mbid) } }
		}
	}

	func row(_ h: DiscogsHit) -> ResultRow {
		let m = mb?.discogsIDs.contains(h.id) == true ? "MusicBrainz" : h.match
		return ResultRow(id: "\(h.id)", thumb: URL(string: h.thumb), title: h.title, match: m, matchHelp: m == "MusicBrainz" ? "Linked from the MusicBrainz release of this album" : "Same as the Discogs release of this album",
			sub: [h.country, h.format, h.label].filter { !$0.isEmpty }.joined(separator: " · "), year: h.year, catno: h.catno,
			tracks: h.tracks.map { $0 < 0 ? "?" : "\($0) tracks" } ?? "…", n: max(0, h.tracks ?? 0))
	}

	var assignView: some View {
		let r = raw ?? [:]
		let artists = Discogs.artistNames(r["artists"] as? [[String: Any]] ?? [])
		let used = a.used
		return VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 12) {
				(Text("\(artists) - \(r["title"] as? String ?? "")").fontWeight(.medium) + Text("  \((r["year"] as? Int).map(String.init) ?? "") · \(a.tracks.count) tracks on release · \(album.tracks.count) files").foregroundStyle(Color.slate(500)))
					.frame(maxWidth: .infinity, alignment: .leading)
				Toggle("Import song titles", isOn: $titles).toggleStyle(.checkbox)
			}.font(.system(size: 14)).padding(.bottom, 12)
			AssignTable(album: album, a: $a, numbers: titles)
			titlesHint(titles)
			Text(verbatim: "Always written from Discogs: DISCOGS_RELEASE_ID, ALBUMARTIST, ALBUM, CATALOGNUMBER, ALBUM_FORMAT (each unless its _OVERRIDE tag is set), COMPOSER, PRODUCER, ENGINEER, the other credit tags and the DISCOGS_* tags.\nWritten only where a file has none: a cover, and ARTIST while “Import song titles” is off.")
				.font(.system(size: 12)).foregroundStyle(Color.slate(500)).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
			let rest = a.tracks.filter { used[$0.id] == nil }.map(\.title)
			Text("Not in this album: \(rest.isEmpty ? "none" : rest.joined(separator: ", "))").font(.system(size: 12)).foregroundStyle(Color.slate(500)).padding(.top, 4)
		}
	}

	func search() {
		guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
		searchTask?.cancel()
		busy = true; what = "Searching Discogs…"; err = nil
		let query = q.trimmingCharacters(in: .whitespaces)
		searchTask = Task {
			do {
				let found = try await Discogs.search(query: query)
				if Task.isCancelled { return }
				raw = nil; rows = found; busy = false
				await counts(found)
			} catch { if !Task.isCancelled { err = error.localizedDescription; busy = false } }
		}
	}

	/// Track counts, three requests at a time.
	func counts(_ found: [DiscogsHit]) async {
		var queue = found.filter { $0.tracks == nil }.map(\.id)
		await withTaskGroup(of: (Int, Int?).self) { g in
			for _ in 0..<3 { if !queue.isEmpty { let id = queue.removeFirst(); g.addTask { (id, await Discogs.trackCount(id)) } } }
			for await (id, n) in g {
				if Task.isCancelled { g.cancelAll(); return }
				if let i = rows?.firstIndex(where: { $0.id == id }) { rows?[i].tracks = n ?? -1 }
				if !queue.isEmpty { let id = queue.removeFirst(); g.addTask { (id, await Discogs.trackCount(id)) } }
			}
		}
	}

	func pick(_ id: Int) {
		searchTask?.cancel()
		busy = true; what = "Loading the release from Discogs…"; err = nil
		searchTask = Task {
			do {
				let r = try await Discogs.release(id)
				if Task.isCancelled { return }
				rid = id; raw = r; a = Assignment(album: album, tracks: Discogs.tracklist(r))
			} catch { if !Task.isCancelled { err = error.localizedDescription } }
			if !Task.isCancelled { busy = false }
		}
	}

	func apply() {
		guard let r = raw else { return }
		app.assign(album, release: r, id: rid, items: a.items(album).map(\.0), importTitles: titles)
		app.sheet = nil
	}
}

struct MusicBrainzSheet: View {
	@EnvironmentObject var app: AppState
	@Environment(\.dialogMaxHeight) var maxH
	var album: Album
	@AppStorage("importTitles_musicbrainz") private var titles = false
	@State private var q = ""
	@State private var rows: [MBHit]?
	@State private var detail: MusicBrainz.Detail?
	@State private var a = Assignment()
	@State private var busy = false
	@State private var what = ""
	@State private var err: String?
	@State private var searchTask: Task<Void, Never>?
	@State private var loaded = false

	var applying: Bool { app.job?.hasPrefix("Applying") == true }

	var body: some View {
		Shell(title: "Choose a MusicBrainz release", width: 1024, err: a.dup ? "A release track is assigned to more than one file." : err,
			saveLabel: applying ? "Applying…" : detail != nil ? "Apply (\(a.n) of \(album.tracks.count))" : "Apply", saveDisabled: detail == nil || a.dup || busy || applying, danger: applying, save: apply, onClose: { app.sheet = nil }) {
			VStack(alignment: .leading, spacing: 0) {
				HStack(spacing: 8) {
					TextField("Artist and album, or a MusicBrainz release ID", text: $q).webField().onSubmit { search() }
					Button { search() } label: { HStack(spacing: 6) { if busy { Spinner(size: 14) }; Text("Search MusicBrainz") } }.buttonStyle(WebButton(kind: .primary))
						.help(busy ? "Stops the running request and starts a new search" : "")
				}
				AlbumFacts(album: album)
				ZStack {
					ScrollView {
						Group {
							if detail != nil { assignView } else if let rows { ReleaseResults(rows: rows.map(row), pick: pick) }
						}.frame(maxWidth: .infinity, alignment: .leading)
					}
					.frame(height: max(192, maxH * 0.6)).opacity(busy ? 0.5 : 1).allowsHitTesting(!busy)
					if busy { BusyOverlay(text: what) }
				}.padding(.top, 16)
			}
		}
		.onAppear {
			guard !loaded else { return }
			loaded = true
			q = [album.artist, album.tracks.first?.tags.first("ALBUM") ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
			if !album.mbid.isEmpty { pick(album.mbid) }
		}
	}

	func row(_ h: MBHit) -> ResultRow {
		ResultRow(id: h.id, thumb: URL(string: "https://coverartarchive.org/release/\(h.id)/front-250"), title: "\(h.artist) - \(h.title)", match: h.match.replacingOccurrences(of: " match", with: ""), matchHelp: "Same as the Discogs release of this album",
			sub: [h.country, h.format, h.label, h.barcode].filter { !$0.isEmpty }.joined(separator: " · "), year: String(h.date.prefix(4)), catno: h.catno, tracks: h.tracks > 0 ? "\(h.tracks) tracks" : "", n: h.tracks)
	}

	func link(_ kind: String, _ id: String, _ text: String) -> some View {
		Button(text) { if let u = URL(string: "https://musicbrainz.org/\(kind)/\(id)") { NSWorkspace.shared.open(u) } }.buttonStyle(.plain).foregroundStyle(Color.sky(700)).underline().pointer()
	}

	var assignView: some View {
		let d = detail!
		return VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 12) {
				(Text("\(d.artist) - \(d.title)").fontWeight(.medium) + Text("  \([d.year, d.country, d.format, d.label, d.catno].filter { !$0.isEmpty }.joined(separator: " · ")) · \(a.tracks.count) tracks on release · \(album.tracks.count) files").foregroundStyle(Color.slate(500)))
					.frame(maxWidth: .infinity, alignment: .leading)
				Toggle("Import song titles", isOn: $titles).toggleStyle(.checkbox)
			}.font(.system(size: 14)).padding(.bottom, 12)
			VStack(alignment: .leading, spacing: 0) {
				mbRow("Release") { link("release", d.id, d.id).font(.system(size: 12, design: .monospaced)) }
				mbRow("Release group (master)") {
					if d.groupID.isEmpty { Text("none").foregroundStyle(Color.slate(500)) } else {
						HStack(spacing: 4) { link("release-group", d.groupID, d.groupTitle.isEmpty ? d.groupID : d.groupTitle); Text([d.groupTypes.split(separator: ",").first.map(String.init) ?? "", d.groupFirst].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Color.slate(500)) }
					}
				}
				mbRow("Album artist", last: true) {
					if d.artists.isEmpty { Text("none").foregroundStyle(Color.slate(500)) } else {
						HStack(spacing: 0) { ForEach(Array(d.artists.enumerated()), id: \.offset) { i, x in if i > 0 { Text(", ") }; link("artist", x.id, x.name) } }
					}
				}
			}.font(.system(size: 14)).padding(.bottom, 12)
			AssignTable(album: album, a: $a, numbers: titles)
			titlesHint(titles)
			Text(verbatim: "Apply writes MUSICBRAINZ_ALBUMID, the release group and album artist IDs and links to every file, and MUSICBRAINZ_ARTISTID and its link to each assigned file. With “Import song titles” on, assigned files also get the release's TITLE, ARTIST, TRACKNUMBER, DISCNUMBER and DISCSUBTITLE and are renamed. BARCODE, ASIN, MUSICBRAINZ_ALBUM_RELEASECOUNTRY, MUSICBRAINZ_ALBUMSTATUS, MUSICBRAINZ_ALBUMTYPE and MUSICBRAINZ_ALBUM_DISAMBIGUATION are filled only where the file has none yet.")
				.font(.system(size: 12)).foregroundStyle(Color.slate(500)).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
		}
	}

	func mbRow<V: View>(_ k: String, last: Bool = false, @ViewBuilder _ v: () -> V) -> some View {
		HStack(spacing: 0) { Text(k).foregroundStyle(Color.slate(500)).frame(width: 160, alignment: .leading); v(); Spacer(minLength: 0) }
			.padding(.vertical, 4).overlay(alignment: .bottom) { if !last { Rectangle().fill(Color.slate(200)).frame(height: 1) } }
	}

	func search() {
		guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
		searchTask?.cancel()
		busy = true; what = "Searching MusicBrainz…"; err = nil
		let barcode = album.tracks.first?.tags.first("BARCODE", "UPC") ?? "", query = q.trimmingCharacters(in: .whitespaces)
		searchTask = Task {
			do {
				let found = try await MusicBrainz.search(query: query, discogsID: album.discogsID, barcode: barcode, catno: album.catalog)
				if Task.isCancelled { return }
				detail = nil; rows = found
			} catch { if !Task.isCancelled { err = error.localizedDescription } }
			if !Task.isCancelled { busy = false }
		}
	}

	func pick(_ id: String) {
		searchTask?.cancel()
		busy = true; what = "Loading the release from MusicBrainz…"; err = nil
		searchTask = Task {
			do {
				let d = try await MusicBrainz.detail(id)
				if Task.isCancelled { return }
				detail = d; a = Assignment(album: album, tracks: d.tracks)
			} catch { if !Task.isCancelled { err = error.localizedDescription } }
			if !Task.isCancelled { busy = false }
		}
	}

	func apply() {
		guard let d = detail else { return }
		app.assignMusicBrainz(album, detail: d, items: a.items(album).map { ($0.0, d.trackArtistIDs[$0.1]) }, importTitles: titles)
		app.sheet = nil
	}
}

// MARK: leftover staging folder (dialogs.tsx CleanupDialog, ADR 0072)

struct LeftoverSheet: View {
	@EnvironmentObject var app: AppState
	var left: AppState.Leftover
	@State private var busy = false
	@State private var err: String?
	var body: some View {
		let d = Self.scan(left.folder)
		Shell(title: "Delete the folder?", width: 640, err: err, saveLabel: busy ? "Deleting…" : "Delete", saveDisabled: busy || d.audio > 0, danger: true, save: delete, onClose: { app.sheet = nil }) {
			VStack(alignment: .leading, spacing: 12) {
				let s1 = "The songs of this album are in the library. "
				let s2 = " in the staging folder still holds \(d.files.isEmpty ? "no files" : "\(d.files.count) file\(d.files.count == 1 ? "" : "s") (\(ArtworkField.bytes(Int(d.bytes))))")\(d.dirs.isEmpty ? "" : " and \(d.dirs.count) subfolder\(d.dirs.count == 1 ? "" : "s")"). Delete deletes the folder, \(d.dirs.isEmpty ? "" : "its subfolders ")and everything in \(d.dirs.isEmpty ? "it" : "them")."
				(Text(s1) + Text(left.folder.lastPathComponent).font(.system(size: 14, design: .monospaced)) + Text(s2)).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
				if d.audio > 0 { Text("\(d.audio) song\(d.audio == 1 ? " is" : "s are") still in this folder, so it cannot be deleted.").foregroundStyle(Color.rose(800)).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.rose(50), in: RoundedRectangle(cornerRadius: 6)) }
				if !d.files.isEmpty || !d.dirs.isEmpty {
					ScrollView {
						VStack(spacing: 0) {
							ForEach(d.dirs, id: \.self) { f in line(f + "/", "subfolder") }
							ForEach(Array(d.files.prefix(200).enumerated()), id: \.offset) { _, f in line(f.0, ArtworkField.bytes(Int(f.1))) }
							if d.files.count > 200 { Text("and \(d.files.count - 200) more files").font(.system(size: 12)).foregroundStyle(Color.slate(500)).padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading) }
						}
					}.frame(maxHeight: 288).fixedSize(horizontal: false, vertical: d.files.count + d.dirs.count < 12)
					.overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.slate(200)))
				}
			}
		}
	}
	func line(_ a: String, _ b: String) -> some View {
		HStack { Text(a).font(.system(size: 12, design: .monospaced)); Spacer(); Text(b).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.slate(500)) }
			.padding(.horizontal, 8).padding(.vertical, 4).overlay(alignment: .bottom) { Rectangle().fill(Color.slate(200)).frame(height: 1) }
	}
	static func scan(_ dir: URL) -> (files: [(String, Int64)], dirs: [String], bytes: Int64, audio: Int) {
		var files: [(String, Int64)] = [], dirs: [String] = [], bytes: Int64 = 0, audio = 0
		let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
		while let u = e?.nextObject() as? URL {
			let rel = u.path.replacingOccurrences(of: dir.path + "/", with: "")
			let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
			if v?.isDirectory == true { dirs.append(rel); continue }
			let n = Int64(v?.fileSize ?? 0); files.append((rel, n)); bytes += n
			if ["flac", "mp3", "m4a", "wav", "aiff", "ogg"].contains(u.pathExtension.lowercased()) { audio += 1 }
		}
		return (files.sorted { $0.0 < $1.0 }, dirs.sorted(), bytes, audio)
	}
	func delete() {
		busy = true
		let d = Self.scan(left.folder)
		do {
			try FileManager.default.removeItem(at: left.folder)
			app.notify("Folder deleted (\(d.files.count) file\(d.files.count == 1 ? "" : "s"), \(ArtworkField.bytes(Int(d.bytes))))", kind: .success)
			app.sheet = nil; app.rescan()
		} catch { err = error.localizedDescription; busy = false }
	}
}
