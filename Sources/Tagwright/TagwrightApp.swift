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
							if o == "lyrics" { app.lyricsTrack = app.selected?.tracks.first?.id }
							if o == "tracks" { app.editorTab = 1 }
							if o == "list" { app.listView = true }
							app.sheet = ["discogs": .discogs, "musicbrainz": .musicbrainz, "tageditor": .tagEditor, "tracks": .tagEditor, "library": .library, "settings": .settings, "lyrics": .lyrics, "move": .move, "album": .albumEdit, "coverdelete": .coverDelete][o] }
					}
				}
		}
		.defaultSize(width: 1640, height: 960)
		.commands {
			CommandGroup(after: .newItem) {
				Button("Rescan") { app.rescan(fresh: true); app.notify("Rescanned", kind: .success) }.keyboardShortcut("r")
				Button("Paste Cover") { if let a = app.selected { app.pasteCover(a) } }.keyboardShortcut("v", modifiers: [.command, .shift])
				Button("Search Discogs…") { if app.selected != nil { app.sheet = .discogs } }.keyboardShortcut("d")
				Button("Search MusicBrainz…") { if app.selected != nil { app.sheet = .musicbrainz } }.keyboardShortcut("m", modifiers: [.command, .shift])
			}
			CommandGroup(replacing: .appSettings) {   // the app menu, as macOS apps do
				Button("Settings…") { app.sheet = .settings }.keyboardShortcut(",")
			}
		}
	}
}

struct RootView: View {
	@EnvironmentObject var app: AppState
	@FocusState private var searchFocus: Bool
	var body: some View {
		GeometryReader { g in
			let side: CGFloat = g.size.width >= 1600 ? 720 : 600   // web: w-[600px] min-[1600px]:w-[720px]
			VStack(spacing: 0) {
				TopBar(searchFocus: $searchFocus, side: side, wide: g.size.width >= 1600)
				Rectangle().fill(Color.slate(200)).frame(height: 1)
				HStack(spacing: 0) {
					Board()
					Rectangle().fill(Color.slate(200)).frame(width: 1)
					Inspector().frame(width: side)
				}
			}
			.overlay { if let s = app.sheet { DialogHost(sheet: s, maxHeight: g.size.height - 48) } }
			.overlay { if let c = app.fullCover { BigCover(cover: c) } }
			.overlay(alignment: .bottomTrailing) { if let t = app.toast { ToastView(toast: t).padding(24).transition(.move(edge: .bottom).combined(with: .opacity)) } }
			.animation(.easeOut(duration: 0.2), value: app.toast)
		}
		.background(Button("") { searchFocus = true }.keyboardShortcut("k").opacity(0))
		.onChange(of: app.sheet) { _, s in if s != nil { searchFocus = false } }
	}
}

/// The web app's dialogs are modals over a dimmed page (shadcn Dialog), not sheets.
struct DialogHost: View {
	@EnvironmentObject var app: AppState
	var sheet: AppState.Sheet
	var maxHeight: CGFloat
	var body: some View {
		ZStack {
			Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { app.sheet = nil }
			Group {
				switch sheet {
				case .settings: SettingsSheet()
				case .tagEditor: if let a = app.selected { TagEditorSheet(album: a, startTab: app.editorTab) }
				case .discogs: if let a = app.selected { DiscogsSheet(album: a) }
				case .leftover: if let l = app.leftover { LeftoverSheet(left: l) }
				case .musicbrainz: if let a = app.selected { MusicBrainzSheet(album: a) }
				case .lyrics: if let a = app.selected, let t = a.tracks.first(where: { $0.id == app.lyricsTrack }) { LyricsSheet(album: a, track: t) }
				case .move: if let a = app.selected { MoveSheet(album: a) }
				case .library: LibrarySheet(lib: app.library)
				case .albumEdit: if let a = app.selected { AlbumEditSheet(album: a) }
				case .coverDelete: if let a = app.selected { CoverDeleteSheet(album: a) }
				}
			}
			.frame(maxHeight: maxHeight)
		}
		.environment(\.dialogMaxHeight, maxHeight)
	}
}

private struct DialogMaxHeight: EnvironmentKey { static let defaultValue: CGFloat = 800 }
extension EnvironmentValues { var dialogMaxHeight: CGFloat { get { self[DialogMaxHeight.self] } set { self[DialogMaxHeight.self] = newValue } } }

/// Full-size cover (ADR 0092): dark overlay, a click or Esc closes it.
struct BigCover: View {
	@EnvironmentObject var app: AppState
	var cover: Cover
	var body: some View {
		ZStack {
			Color.slate(900).opacity(0.8).ignoresSafeArea()
			if let i = NSImage(data: cover.data) { Image(nsImage: i).resizable().scaledToFit().shadow(radius: 30).padding(32) }
		}
		.contentShape(Rectangle()).onTapGesture { app.fullCover = nil }
		.onHover { $0 ? NSCursor.closedHand.push() : NSCursor.pop() }
		.background(Button("") { app.fullCover = nil }.keyboardShortcut(.cancelAction).opacity(0))
		.help("Click or press Escape to close")
	}
}

/// sonner toast: white card, coloured icon, 13 pt text.
struct ToastView: View {
	var toast: Toast
	var body: some View {
		HStack(spacing: 8) {
			switch toast.kind {
			case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.ink)
			case .error: Image(systemName: "xmark.circle.fill").foregroundStyle(Color.ink)
			case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.ink)
			case .info: Image(systemName: "info.circle.fill").foregroundStyle(Color.ink)
			case .plain: EmptyView()
			}
			Text(toast.text).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink)
		}
		.padding(.horizontal, 16).frame(minWidth: 356, minHeight: 52, alignment: .leading)
		.background(.white, in: RoundedRectangle(cornerRadius: 8))
		.overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.slate(200)))
		.shadow(color: .black.opacity(0.1), radius: 8, y: 4)
	}
}

struct TopBar: View {
	@EnvironmentObject var app: AppState
	var searchFocus: FocusState<Bool>.Binding
	var side: CGFloat
	var wide: Bool
	@State private var searchOver = false
	var body: some View {
		HStack(spacing: 8) {
			Image(nsImage: Asset.logo.image).resizable().frame(width: 32, height: 32).padding(.trailing, 8)
			HStack(spacing: 4) {
				ForEach(Filter.allCases, id: \.self) { f in FilterButton(f: f) }
			}.fixedSize()
			Spacer(minLength: 8)
			// ADR 0095: Rescan, the view pill, the folder switch and the search as one group
			RoundIcon(icon: .refreshCw, help: "Rescan folder", spinning: app.scanning) { app.rescan(fresh: true); app.notify("Rescanned", kind: .success) }
			HStack(spacing: 2) {
				ViewToggle(icon: .layoutGrid, on: !app.listView, help: "Card view") { app.listView = false }
				ViewToggle(icon: .list, on: app.listView, help: "List view") { app.listView = true }
			}
			.padding(2).frame(height: 36).background(.white, in: Capsule()).overlay(Capsule().stroke(Color.slate(300)))
			SourceSwitch()
			HStack(spacing: 8) {
				LucideIcon(icon: .search, size: 16).foregroundStyle(Color.slate(400))
				TextField("Search", text: $app.search).textFieldStyle(.plain).font(.system(size: 14)).focused(searchFocus)
				if !app.search.isEmpty && (searchOver || searchFocus.wrappedValue) { ClearX { app.search = ""; searchFocus.wrappedValue = true } }
			}
			.onHover { searchOver = $0 }
			.padding(.horizontal, 12).frame(minWidth: 80, idealWidth: 288, maxWidth: 288).frame(height: 36)
			.background(.white, in: Capsule()).overlay(Capsule().stroke(Color.slate(300))).help("Search albums, artists, IDs (⌘K)")
			if app.playing != nil {
				Button { app.stopPlayback() } label: {
					HStack(spacing: 8) { EqBars(); LucideIcon(icon: .square, size: 14).overlay(Rectangle().fill(Color.slate(800)).padding(3)); Text("Stop").font(.system(size: 15)) }
						.foregroundStyle(Color.slate(800)).padding(.horizontal, 12).frame(height: 36)
						.background(Color.yellow(100), in: Capsule()).overlay(Capsule().stroke(Color.yellow(400)))
				}.buttonStyle(.plain).help("Stop playback").padding(.trailing, 4)
			}
			RoundIcon(icon: .settings, size: 20, help: "Settings") { app.sheet = .settings }.padding(.trailing, 12)
			HStack(spacing: 8) {
				LibraryIndicator(lib: app.library) { app.sheet = .library }
				Rectangle().fill(Color.slate(300)).frame(width: 1, height: 32)
				PipelineStatus()
			}
			.padding(.horizontal, 16).frame(width: side).frame(maxHeight: .infinity)
			.overlay(alignment: .leading) { Rectangle().fill(Color.slate(200)).frame(width: 1) }
		}
		.padding(.leading, 24).frame(height: 56).background(Color.topBar)
	}
}

struct FilterButton: View {
	@EnvironmentObject var app: AppState
	var f: Filter
	@State private var over = false
	var body: some View {
		let active = app.filter == f
		Button {
			if active { app.cycleSort() } else { app.filter = f }
			app.tableSort = nil
		} label: {
			HStack(spacing: 8) {
				Text(f.label).font(.system(size: 15, weight: .medium)).foregroundStyle(active ? Color.slate(900) : Color.slate(600))
				Text("\(app.counts[f] ?? 0)").font(.system(size: 15)).foregroundStyle(Color.slate(400))
			}
			.padding(.horizontal, 16).frame(height: 36)
			.background(active ? Color.white : over ? Color.white.opacity(0.6) : .clear, in: Capsule())
			.shadow(color: .black.opacity(active ? 0.06 : 0), radius: 1, y: 1)
			.contentShape(Capsule())
		}
		.buttonStyle(.plain).onHover { over = $0 }
		.help(active ? "Sorted by \(app.sort.rawValue); click again to change" : "")
	}
}

/// `grid size-9 place-items-center rounded-full text-slate-600 hover:bg-white/60`
struct RoundIcon: View {
	var icon: Lucide
	var size: CGFloat = 16
	var help: String
	var spinning = false
	var action: () -> Void
	@State private var over = false
	var body: some View {
		Button(action: action) {
			Group { if spinning { Spinner(icon: icon, size: size) } else { LucideIcon(icon: icon, size: size) } }
				.foregroundStyle(Color.slate(600)).frame(width: 36, height: 36)
				.background(over ? Color.white.opacity(0.6) : .clear, in: Circle()).contentShape(Circle())
		}.buttonStyle(.plain).onHover { over = $0 }.help(help)
	}
}

struct ViewToggle: View {
	var icon: Lucide, on: Bool, help: String, action: () -> Void
	@State private var over = false
	var body: some View {
		Button(action: action) {
			LucideIcon(icon: icon, size: 16).foregroundStyle(on ? Color.slate(900) : over ? Color.slate(700) : Color.slate(400)).frame(width: 36, height: 30)
				.background(on ? Color.slate(200) : .clear, in: Capsule()).contentShape(Capsule())
		}.buttonStyle(.plain).onHover { over = $0 }.help(help)
	}
}

/// The Staging / Library switch: w-48, the whole control toggles.
struct SourceSwitch: View {
	@EnvironmentObject var app: AppState
	var body: some View {
		let lib = app.source == .library
		Button { app.switchSource(lib ? .staging : .library) } label: {
			HStack(spacing: 8) {
				Text("Staging").foregroundStyle(lib ? Color.slate(400) : Color.slate(900))
				Capsule().fill(lib ? Color.slate(700) : Color.slate(300)).frame(width: 36, height: 20)
					.overlay(alignment: lib ? .trailing : .leading) { Circle().fill(.white).frame(width: 16, height: 16).shadow(radius: 1).padding(2) }
				Text("Library").foregroundStyle(lib ? Color.slate(900) : Color.slate(400))
			}
			.font(.system(size: 15, weight: .medium)).padding(.horizontal, 16).frame(width: 192, height: 36)
			.background(.white, in: Capsule()).overlay(Capsule().stroke(Color.slate(300))).contentShape(Capsule())
			.animation(.easeOut(duration: 0.15), value: lib)
		}
		.buttonStyle(.plain)
		.help(lib ? "Showing the library; click for the staging folder" : "Showing the staging folder; click for the library")
	}
}

/// Pipeline state in the top bar (page.tsx): dot, "Pipeline", what it does, Stop while running.
struct PipelineStatus: View {
	@EnvironmentObject var app: AppState
	@State private var pulse = false
	var body: some View {
		let running = app.jobState == .running
		HStack(spacing: 8) {
			Circle().fill(running ? Color.sky(500) : app.jobState == .failed ? .rose(500) : app.jobState == .stopped ? .amber(500) : .emerald(500))
				.frame(width: 8, height: 8).opacity(running && pulse ? 0.4 : 1)
				.animation(running ? .easeInOut(duration: 1).repeatForever() : .default, value: pulse).onAppear { pulse = true }
			VStack(alignment: .leading, spacing: 0) {
				Text("Pipeline").font(.system(size: 15, weight: .medium))
				Text(running ? "Running: \(app.job.map { $0.replacingOccurrences(of: "Fixing ", with: "") } ?? "…")" : app.jobState == .failed ? "Last run failed" : app.jobState == .stopped ? "Last run stopped" : "Idle")
					.font(.system(size: 15)).foregroundStyle(Color.slate(500)).lineLimit(1).truncationMode(.tail)
			}.frame(maxWidth: .infinity, alignment: .leading)
			if app.job?.hasPrefix("Fixing") == true {
				Button { app.stop(); app.notify("Stopping…", kind: .warning) } label: {
					Text("Stop").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.rose(600)).padding(.horizontal, 16).frame(height: 36)
						.background(.white, in: Capsule()).overlay(Capsule().stroke(Color.rose(300)))
				}.buttonStyle(.plain)
			}
		}
	}
}
