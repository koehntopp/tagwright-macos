import SwiftUI

@main
struct TagwrightApp: App {
	@StateObject private var app = AppState()
	var body: some Scene {
		WindowGroup("Tagwright") {
			RootView().environmentObject(app).frame(minWidth: 1580, minHeight: 640)
				.onAppear {
					NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); app.rescan()
					// TW_OPEN=discogs|musicbrainz|tageditor opens that dialog on the first album (screenshots, demos)
					if let o = ProcessInfo.processInfo.environment["TW_OPEN"] {
						Task { try? await Task.sleep(for: .seconds(2)); app.search = ""; app.filter = .all; app.selection = app.shown[min(Int(ProcessInfo.processInfo.environment["TW_ALBUM"] ?? "0") ?? 0, max(0, app.shown.count - 1))].id
							app.sheet = ["discogs": .discogs, "musicbrainz": .musicbrainz, "tageditor": .tagEditor, "library": .library, "settings": .settings][o] }
					}
				}
		}
		.defaultSize(width: 1640, height: 960)
		.commands {
			CommandGroup(after: .newItem) {
				Button("Rescan") { app.rescan() }.keyboardShortcut("r")
				Button("Paste Cover") { if let a = app.selected { app.pasteCover(a) } }.keyboardShortcut("v", modifiers: [.command, .shift])
				Button("Search Discogs…") { if app.selected != nil { app.sheet = .discogs } }.keyboardShortcut("d")
				Button("Search MusicBrainz…") { if app.selected != nil { app.sheet = .musicbrainz } }.keyboardShortcut("m", modifiers: [.command, .shift])
				Button("Settings…") { app.sheet = .settings }.keyboardShortcut(",")
			}
		}
	}
}

struct RootView: View {
	@EnvironmentObject var app: AppState
	@FocusState private var searchFocus: Bool
	var body: some View {
		VStack(spacing: 0) {
			TopBar(searchFocus: $searchFocus)
			Divider()
			HStack(spacing: 0) {
				Board()
				Divider()
				Inspector().frame(width: 600)
			}
		}
		.sheet(item: $app.sheet) { s in
			switch s {
			case .settings: SettingsSheet()
			case .tagEditor: if let a = app.selected { TagEditorSheet(album: a) }
			case .discogs: if let a = app.selected { DiscogsSheet(album: a) }
			case .leftover: if let l = app.leftover { LeftoverSheet(left: l) }
			case .musicbrainz: if let a = app.selected { MusicBrainzSheet(album: a) }
			case .lyrics: if let a = app.selected, let t = a.tracks.first(where: { $0.id == app.lyricsTrack }) { LyricsSheet(album: a, track: t) }
			case .move: if let a = app.selected { MoveSheet(album: a) }
			case .cover: if let c = app.fullCover { CoverSheet(cover: c) }
			case .library: LibrarySheet(lib: app.library)
			}
		}
		.overlay(alignment: .bottomTrailing) {
			if let t = app.toast { Text(t).font(.system(size: 13)).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10).background(Color.ink, in: RoundedRectangle(cornerRadius: 10)).padding(20).transition(.opacity) }
		}
		.animation(.default, value: app.toast)
		.background(Button("") { searchFocus = true }.keyboardShortcut("k").opacity(0))
	}
}

struct TopBar: View {
	@EnvironmentObject var app: AppState
	var searchFocus: FocusState<Bool>.Binding
	var body: some View {
		HStack(spacing: 0) {
			HStack(spacing: 10) {
				RoundedRectangle(cornerRadius: 9).fill(Color.brand).frame(width: 32, height: 32)
					.overlay(Image(systemName: "tag.fill").foregroundStyle(.white).font(.system(size: 15)))
				ForEach(Filter.allCases, id: \.self) { f in
					let active = app.filter == f
					Button {
						if active { app.cycleSort() } else { app.filter = f }
					} label: {
						HStack(spacing: 6) {
							Text(f.label).font(.system(size: 14, weight: .medium)).fixedSize()
							Text("\(app.counts[f] ?? 0)").font(.system(size: 13)).foregroundStyle(Color.muted).fixedSize()
						}.padding(.horizontal, 11).frame(height: 34)
							.background(active ? Color.white : .clear, in: Capsule()).shadow(color: .black.opacity(active ? 0.08 : 0), radius: 2, y: 1)
					}.buttonStyle(.plain).help(active ? "Click again to change the sort (\(app.sort.rawValue))" : "")
				}
				Button { app.rescan() } label: { Image(systemName: "arrow.clockwise").symbolEffect(.rotate, isActive: app.scanning).frame(width: 34, height: 34) }.buttonStyle(.plain)
				sourceSwitch
				HStack { Image(systemName: "magnifyingglass").foregroundStyle(Color.muted); TextField("Search", text: $app.search).textFieldStyle(.plain).focused(searchFocus) }
					.padding(.horizontal, 12).frame(width: 130, height: 34).background(.white, in: Capsule()).overlay(Capsule().stroke(Color.black.opacity(0.1)))
				Button { app.listView.toggle() } label: { Image(systemName: app.listView ? "square.grid.2x2" : "list.bullet").frame(width: 34, height: 34) }.buttonStyle(.plain).help(app.listView ? "Card view" : "List view")
				Button { app.sheet = .settings } label: { Image(systemName: "gearshape").frame(width: 34, height: 34) }.buttonStyle(.plain)
			}.padding(.horizontal, 16).layoutPriority(1)
			Spacer(minLength: 0)
			HStack(spacing: 0) {
				LibraryIndicator(lib: app.library) { app.sheet = .library }
				Divider().padding(.vertical, 12)
				HStack {
					status(color: app.job == nil ? Color.ok : Color.info, title: "Pipeline", sub: app.job ?? "Idle")
					if app.job?.hasPrefix("Fixing") == true { Button("Stop") { app.stop() }.buttonStyle(.bordered).tint(Color.bad).controlSize(.small) }
					if app.playing != nil { Button { app.stopPlayback() } label: { Label("Stop playback", systemImage: "stop.fill") }.buttonStyle(.bordered).tint(Color.warn).controlSize(.small) }
				}
			}.frame(width: 600)
		}
		.frame(height: 56).background(Color.topBar)
	}

	var sourceSwitch: some View {
		HStack(spacing: 8) {
			Text("Staging").font(.system(size: 13, weight: app.source == .staging ? .semibold : .regular)).fixedSize()
			Capsule().fill(app.source == .library ? Color.ink : Color.black.opacity(0.15)).frame(width: 36, height: 20)
				.overlay(Circle().fill(.white).padding(2).frame(width: 20, height: 20).frame(maxWidth: .infinity, alignment: app.source == .library ? .trailing : .leading))
				.onTapGesture { app.switchSource(app.source == .staging ? .library : .staging) }
			Text("Library").font(.system(size: 13, weight: app.source == .library ? .semibold : .regular)).fixedSize()
		}.padding(.horizontal, 14).frame(height: 34).background(.white, in: Capsule()).overlay(Capsule().stroke(Color.black.opacity(0.1)))
	}

	func status(color: Color, title: String, sub: String) -> some View {
		HStack(spacing: 8) {
			Circle().fill(color).frame(width: 8, height: 8)
			VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1); Text(sub).font(.system(size: 13)).foregroundStyle(Color.muted).lineLimit(1) }
		}.padding(.horizontal, 20).frame(maxWidth: .infinity, alignment: .leading)
	}
}
