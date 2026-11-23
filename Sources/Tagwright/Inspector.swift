import SwiftUI
import UniformTypeIdentifiers

/// The inspector (inspector.tsx): header, artwork, actions, notes, folders, pipeline, tracks and log.
struct Inspector: View {
	@EnvironmentObject var app: AppState
	@State private var stepSel: StepID?
	@State private var tracksOpen = true
	@State private var logOpen = false

	var body: some View {
		Group {
			if let a = app.selected {
				ScrollView {
					VStack(alignment: .leading, spacing: 20) {
						header(a)
						VStack(alignment: .leading, spacing: 8) {
							let disc = app.coverDisc(a)
							if a.discs.count > 1 {   // ADR 0098: the artwork of one disc
								DiscSwitch(discs: a.discs, disc: disc) { d in app.discSel = d.map { (a.id, $0) } }
							}
							LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4), spacing: 8) {
								// on a multi-disc album, All discs edits the box-set cover in the first field (ADR 0099)
								ForEach(ArtType.allCases) { t in ArtworkField(album: a, type: t, disc: disc, box: t == .front && a.discs.count > 1 && disc == nil) }
							}
						}
						actions(a)
						notes(a)
						folderBox(a)
						pipeline(a)
						tracks(a)
						logBox
					}
					.padding(24)
				}
				.task(id: a.id + a.mbid + a.discogsID) { await app.checkMusicBrainz(a) }
				.onChange(of: a.id) { stepSel = nil }
			} else {
				Text("Select an album.").foregroundStyle(Color.slate(500)).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			}
		}
		.background(.white)
	}

	var running: Bool { app.job?.hasPrefix("Fixing") == true }

	// MARK: header

	func pen(_ help: String, size: CGFloat = 12, _ action: @escaping () -> Void) -> some View {
		Button(action: action) { LucideIcon(icon: .pencil, size: size).foregroundStyle(Color.ink) }.buttonStyle(.plain).pointer().help(help)
	}

	func header(_ a: Album) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 4) {
				Text(a.artist.isEmpty ? "No artist" : a.artist).lineLimit(1).help(a.tracks.first?.tags.first("ALBUMARTIST").isEmpty == false ? "" : "from ARTIST tag")
				pen("Edit album artist and title") { app.sheet = .albumEdit }
				if !a.artist.isEmpty { CopyButton(text: a.artist) }
			}.font(.system(size: 12)).foregroundStyle(Color.slate(500))
			HStack(spacing: 4) {
				Text(a.title).font(.system(size: 20, weight: .semibold)).textSelection(.enabled)
				pen("Edit album artist and title") { app.sheet = .albumEdit }.padding(.leading, 2)
				CopyButton(text: a.title)
			}
			HStack(spacing: 2) {
				let flag = Flag.of(a.country)
				// the version string already holds year, DR, format and catalogue number: nothing is shown twice
				Text((flag.isEmpty ? "" : flag + " ") + (a.version.isEmpty ? [a.dateYear, a.format.isEmpty ? "CD" : a.format, a.catalog].filter { !$0.isEmpty }.joined(separator: " · ") : a.version))
					.font(.system(size: 12)).foregroundStyle(Color.slate(500)).textSelection(.enabled).help(a.country)
				if !a.catalog.isEmpty, a.catalog.lowercased() != "none" { CopyButton(text: a.catalog, title: "Copy the catalogue number") }
			}.padding(.top, 2)
			let q = [a.artist, a.title].filter { !$0.isEmpty }.joined(separator: " ")
			HStack(spacing: 4) {
				IdBadge(service: .discogs, id: a.discogsID, query: q)
				pen("Change the Discogs release") { app.sheet = .discogs }.padding(.trailing, 4)
				IdBadge(service: .musicbrainz, id: a.mbid, query: q)
				pen("Choose the MusicBrainz release") { app.sheet = .musicbrainz }.padding(.trailing, 4)
				if !a.albumDR.isEmpty { DRBadge(value: a.albumDR) }
			}.padding(.top, 8)
		}
	}

	// MARK: actions

	func actions(_ a: Album) -> some View {
		let mismatch = app.mbCheck[a.id]?.mismatches ?? []
		let inLibrary = app.source == .library
		return HStack(spacing: 8) {
			Button("Tag Editor") { app.editorTab = 0; app.sheet = .tagEditor }.buttonStyle(WebButton(kind: .primary, size: .md, full: true))
			Button(running ? "Running…" : "Run fixes") { app.run(a) }
				.buttonStyle(WebButton(kind: running ? .danger : .outline, size: .md, full: true))
				.disabled(a.status == .needs || app.job != nil).opacity(running ? 2 : 1)
			Button("Move to library") { app.sheet = .move }
				.buttonStyle(WebButton(kind: .outline, size: .md, full: true))
				.disabled(inLibrary || a.status != .fixed || a.issues.contains { $0.level == .ingest } || !mismatch.isEmpty || app.job != nil)
				.help(inLibrary ? "This album is already in the library" : mismatch.first.map { "\($0) Fix the release before moving." } ?? "")
		}
	}

	// MARK: notes (one box per note: type at the left, lines beside it, the action at the right)

	enum Tone { case error, warn, info
		var box: (border: Color, bg: Color, fg: Color, head: Color) {
			switch self {
			case .error: (.rose(200), .rose(50), .rose(900), .rose(700))
			case .warn: (.amber(200), .amber(50), .amber(900), .amber(700))
			case .info: (.sky(200), .sky(50), .sky(900), .sky(700))
			}
		}
	}

	func noteBox<Lines: View>(_ tone: Tone, _ label: String, action: (String, Bool, String, () -> Void)? = nil, @ViewBuilder lines: () -> Lines) -> some View {
		let c = tone.box
		return HStack(alignment: .top, spacing: 12) {
			HStack(spacing: 6) {
				LucideIcon(icon: tone == .error ? .octagonX : .triangleAlert, size: 14)
				Text(label.uppercased()).font(.system(size: 12, weight: .medium)).tracking(0.6)
			}.foregroundStyle(c.head).frame(width: 128, height: 20, alignment: .leading)
			VStack(alignment: .leading, spacing: 2) { lines() }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 1)
			if let b = action { Button(b.0, action: b.3).buttonStyle(WebButton(kind: .outline, size: .xs)).disabled(!b.1).help(b.2) }
		}
		.foregroundStyle(c.fg).padding(.horizontal, 12).padding(.vertical, 6)
		.background(c.bg, in: RoundedRectangle(cornerRadius: 12))
		.overlay(RoundedRectangle(cornerRadius: 12).stroke(c.border))
	}

	@ViewBuilder func notes(_ a: Album) -> some View {
		let canRun = a.status != .needs && app.job == nil
		ForEach(a.issues) { i in
			let tone: Tone = i.level == .error ? .error : i.level == .info ? .info : .warn
			let act: (String, Bool, String, () -> Void)? = switch i.action {
			case "search": ("Search", true, "", { app.sheet = .discogs })
			case "album": ("Tag Editor", true, "", { app.editorTab = 0; app.sheet = .tagEditor })
			case "tracks": ("Tag Editor", true, "", { app.editorTab = 1; app.sheet = .tagEditor })
			case "cover": ("Upload", true, "", { app.chooseArtwork(a, type: .front) })
			default: nil
			}
			noteBox(tone, i.level == .error ? "Problem" : i.level == .info ? "Note" : "Warning", action: act) { Text(i.text) }
		}
		if let c = app.mbCheck[a.id], !c.mismatches.isEmpty {
			noteBox(.error, "Mismatch", action: ("MusicBrainz", true, "", { app.sheet = .musicbrainz })) { ForEach(c.mismatches, id: \.self) { Text($0) } }
		}
		let req = a.missing.filter { !$0.step.optional }, opt = a.missing.filter(\.step.optional)
		ForEach([(false, req), (true, opt)], id: \.0) { optional, items in
			if !items.isEmpty {
				let holdsRun = optional ? req.isEmpty : true   // Run fixes sits on the first of the two boxes
				noteBox(optional ? .info : .error, optional ? "Optional" : "Missing", action: holdsRun ? ("Run fixes", canRun, "Run the pipeline for the missing data", { app.run(a) }) : nil) {
					ForEach(items) { m in
						Button { stepSel = m.step; tracksOpen = true } label: {
							(Text(m.label).fontWeight(.medium) + Text(" on \(m.count == m.of ? "all \(m.of) tracks" : "\(m.count) of \(m.of) tracks")")).frame(maxWidth: .infinity, alignment: .leading)
						}.buttonStyle(UnderlineOnHover()).help("Mark these tracks in the track list")
					}
				}
			}
		}
		if let c = app.mbCheck[a.id], !c.notes.isEmpty {
			noteBox(.info, "Note", action: ("MusicBrainz", true, "", { app.sheet = .musicbrainz })) { ForEach(c.notes, id: \.self) { Text($0) } }
		}
	}

	// MARK: folders

	func folderBox(_ a: Album) -> some View {
		let current = app.root.map { a.url.path.replacingOccurrences(of: $0.path + "/", with: "") } ?? a.name
		let newDir = a.tracks.first.flatMap { Naming.blissAlbum($0.tags) }
		let versions = app.library.versions(master: a.masterID, excluding: a.url.path)
		func vline(_ album: String, _ version: String) -> String { album + (!version.isEmpty && !album.contains(version) ? " " + version : "") }
		return VStack(alignment: .leading, spacing: 4) {
			folderRow("Current folder") { Text(current).font(.system(size: 12, design: .monospaced)) }
			folderRow("New folder") {
				if let n = newDir {
					Text(n).font(.system(size: 12, design: .monospaced))
					Text(vline(a.tracks.first?.tags.first("ALBUM") ?? a.name, a.version)).font(.system(size: 12))
				} else { Text("Not ready: artist or album is empty").font(.system(size: 12)).foregroundStyle(Color.slate(400)) }
			}
			if !versions.isEmpty {
				folderRow("In your library") { ForEach(versions) { v in Text(vline(v.album, v.version)).font(.system(size: 12)).help(v.path) } }
			}
		}
		.foregroundStyle(Color.slate(800)).textSelection(.enabled)
		.padding(.horizontal, 12).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
		.background(Color.slate(50), in: RoundedRectangle(cornerRadius: 12))
		.overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.slate(200)))
	}

	func folderRow<V: View>(_ label: String, @ViewBuilder _ v: () -> V) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Text(label.uppercased()).font(.system(size: 12, weight: .medium)).tracking(0.6).foregroundStyle(Color.slate(500)).frame(width: 128, alignment: .leading)
			VStack(alignment: .leading, spacing: 2) { v() }.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	// MARK: pipeline

	func pipeline(_ a: Album) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("PIPELINE").font(.system(size: 12, weight: .medium)).tracking(0.6).foregroundStyle(Color.slate(500))
			HStack(alignment: .top, spacing: 4) {
				ForEach(StepID.allCases) { s in StepCircle(album: a, step: s, selected: stepSel == s) {
					stepSel = stepSel == s ? nil : s; tracksOpen = true
				} run: {
					if (a.status != .needs || [.dr, .replaygain, .fingerprints].contains(s)) && app.job == nil { app.run(a, steps: [s]) }
				} }
			}
		}
	}

	// MARK: tracks

	func tracks(_ a: Album) -> some View {
		Collapsible(open: $tracksOpen) {
			HStack(spacing: 8) {
				Text("Tracks")
				Pill(text: "\(a.tracks.count)", bg: .white)
				if let s = stepSel { Text(s.label).font(.system(size: 12)).foregroundStyle(Color.sky(700)) }
			}
		} content: {
			let fails = stepSel.map { Set(a.missingTracks($0).map(\.id)) }
			ScrollView {
				VStack(spacing: 0) {
					ForEach(Array(a.tracks.enumerated()), id: \.element.id) { i, t in
						trackRow(t, fails: fails, last: i == a.tracks.count - 1)
					}
				}
			}.frame(maxHeight: 320).fixedSize(horizontal: false, vertical: a.tracks.count < 9)
		}
	}

	func trackRow(_ t: Track, fails: Set<String>?, last: Bool) -> some View {
		let playing = app.playing == t.id
		return HStack(spacing: 8) {
			Button { app.play(t) } label: { LucideIcon(icon: playing ? .pause : .play, size: 12) }.buttonStyle(IconButton()).help("Play")
			Text(t.number.isEmpty ? "" : String(format: "%02d", Int(t.number) ?? 0)).monospacedDigit().foregroundStyle(Color.slate(400)).frame(width: 24, alignment: .leading)
			Text(t.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(t.url.lastPathComponent)
			Text(Self.mmss(t.info.duration)).monospacedDigit().foregroundStyle(Color.slate(500)).frame(width: 40, alignment: .trailing)
			ChannelBadge(n: t.info.channels)
			if let f = fails, let s = stepSel {
				if f.contains(t.id) { Text("✗").fontWeight(.semibold).foregroundStyle(Color.rose(600)) }
				else { Text("✓").fontWeight(.semibold).foregroundStyle(t.lyricsKind == .txt && s == .lyrics ? Color.amber(500) : .emerald(600)) }
			}
			Pill(text: t.formatLabel, fg: .slate(700), bg: .white, border: true, width: 72).monospacedDigit().help(t.formatHelp)
			Pill(text: t.dr.isEmpty ? "DR —" : "DR\(t.dr)", fg: t.dr.isEmpty ? .slate(500) : .emerald(800), bg: t.dr.isEmpty ? .slate(200) : .emerald(100), width: 48)
			LyricsBadge(kind: t.lyricsKind)
			Button { app.lyricsTrack = t.id; app.sheet = .lyrics } label: { LucideIcon(icon: .pencil, size: 12) }.buttonStyle(IconButton()).help("Edit lyrics")
		}
		.font(.system(size: 13)).padding(.vertical, 6).padding(.leading, 4)
		.background(playing ? Color.yellow(50) : .clear)
		.overlay(alignment: .leading) { Rectangle().fill(playing ? Color.yellow(400) : .clear).frame(width: 4) }
		.overlay(alignment: .bottom) { if !last { Rectangle().fill(Color.slate(200)).frame(height: 1) } }
	}

	static func mmss(_ s: Double) -> String { s > 0 ? String(format: "%d:%02d", Int(s.rounded()) / 60, Int(s.rounded()) % 60) : "" }

	// MARK: log

	var logBox: some View {
		Collapsible(open: $logOpen) { Text("Log") } content: {
			ScrollViewReader { r in
				ScrollView {
					VStack(alignment: .leading, spacing: 0) {
						if app.logLines.isEmpty { (Text("—").foregroundStyle(Color.slate(500)) + Text("   No runs yet")) }
						ForEach(Array(app.logLines.suffix(300).enumerated()), id: \.offset) { i, l in
							(Text(l.t).foregroundStyle(Color.slate(500)) + Text("   " + l.m))
								.foregroundStyle(l.k == "ok" ? Color.emerald(400) : Color.slate(200)).opacity(l.k == "file" ? 0.6 : 1).id(i)
						}
					}.font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.slate(200)).textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading).padding(12)
				}
				.frame(maxHeight: 288).fixedSize(horizontal: false, vertical: app.logLines.count < 20)
				.background(Color.slate(900), in: RoundedRectangle(cornerRadius: 8))
				.onChange(of: app.logLines.count) { r.scrollTo(min(app.logLines.count, 300) - 1) }
			}
		}
	}
}

/// `hover:underline` for the lines of the Missing box.
struct UnderlineOnHover: ButtonStyle {
	func makeBody(configuration c: Configuration) -> some View { B(c: c) }
	struct B: View {
		let c: Configuration
		@State private var over = false
		var body: some View { c.label.underline(over).contentShape(Rectangle()).onHover { over = $0 } }
	}
}

/// shadcn Collapsible as the inspector uses it: rounded-xl slate-100 box, 13 pt trigger with a chevron.
struct Collapsible<Label: View, Content: View>: View {
	@Binding var open: Bool
	@ViewBuilder var label: Label
	@ViewBuilder var content: Content
	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
				HStack(spacing: 8) { label; Spacer(); LucideIcon(icon: .chevronDown, size: 16).rotationEffect(.degrees(open ? 180 : 0)) }
					.font(.system(size: 13, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
			}.buttonStyle(.plain)
			if open { content.padding(.horizontal, 16).padding(.bottom, 12) }
		}
		.background(Color.slate(100), in: RoundedRectangle(cornerRadius: 12))
	}
}

/// One step of the pipeline row (inspector.tsx): icon circle, state badge, label; click marks the tracks,
/// double-click runs only this step.
struct StepCircle: View {
	@EnvironmentObject var app: AppState
	var album: Album
	var step: StepID
	var selected: Bool
	var select: () -> Void
	var run: () -> Void
	var body: some View {
		let st = album.state(step)
		let busy = (app.runningStep == step && app.job == "Fixing \(album.title)") || (app.working[album.id]?.contains(step) ?? false)
		let note = step == .tags && album.coverTooSmall ? (album.issues.first { $0.action == "cover" }?.text ?? "") + " " : ""
		VStack(spacing: 4) {
			ZStack(alignment: .bottomTrailing) {
				ZStack {
					Circle().fill(busy ? Color.sky(500) : st == .done ? .emerald(500) : st == .partial ? .amber(400) : .white)
					if st == .open && !busy { Circle().stroke(Color.slate(200), style: StrokeStyle(lineWidth: 1, dash: step.optional ? [3, 2] : [])) }
					if busy { Circle().stroke(Color.sky(300), lineWidth: 2).padding(-2) }
					Group {
						if busy { Spinner(icon: .refreshCw, size: 18) } else { LucideIcon(icon: step.lucide, size: 18) }
					}.foregroundStyle(busy || st == .done ? .white : st == .partial ? Color.amber(950) : Color.slate(400))
				}.frame(width: 36, height: 36)
				if !busy && st != .open {
					LucideIcon(icon: st == .partial ? .triangleAlert : .check, size: 10).foregroundStyle(.white)
						.frame(width: 15, height: 15).background(st == .partial ? Color.amber(700) : .emerald(700), in: Circle())
						.overlay(Circle().stroke(.white, lineWidth: 1.5)).offset(x: 2, y: 2)
				}
			}
			Text(step.label).font(.system(size: 11, weight: selected ? .medium : .regular)).lineLimit(1).minimumScaleFactor(0.8)
				.padding(.horizontal, 4).background(selected ? Color.slate(800).opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
		}
		.frame(maxWidth: .infinity)
		.background(alignment: .top) {
			if step != .dr { Rectangle().fill(Color.slate(200)).frame(height: 2).offset(x: -40, y: 17).frame(maxWidth: .infinity).zIndex(-1) }
		}
		.contentShape(Rectangle())
		.onTapGesture(count: 2) { run() }
		.onTapGesture { select() }
		.pointer()
		.help(note + "Double-click to run only this step.")
	}
}

extension StepID {
	var lucide: Lucide { [.chartColumn, .volume2, .fingerprint, .tags, .mic, .fileText][rawValue] }
}

/// One of the four artwork fields (inspector.tsx CoverField, ADR 0090). Front is single; the others are small
/// carousels. Drop replaces the shown image; double-click shows it full size.
struct ArtworkField: View {
	@EnvironmentObject var app: AppState
	var album: Album
	var type: ArtType
	var disc: Int? = nil   // ADR 0098: only this disc's files
	var box = false   // ADR 0099: the box-set cover
	@State private var at = 0
	@State private var targeted = false
	@FocusState private var focused: Bool   // a click focuses the field; ⌘V then pastes into it (ADR 0096)

	var body: some View {
		let items = box ? album.artwork[Artwork.box] ?? [] : disc.map { album.discArtwork[$0]?[type.rawValue] ?? [] } ?? album.artwork[type.rawValue] ?? []
		let multiple = type != .front
		let i = items.isEmpty ? 0 : min(at, items.count - 1)
		let current = items.isEmpty ? nil : items[i]
		let fallback = type == .front && !box && disc == nil && items.isEmpty && album.cover?.embedded == false ? album.cover : nil
		let warn = type == .front && !box ? album.issues.first { $0.action == "cover" }?.text : nil
		let busy = app.coverBusy == album.id
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 4) {
				Text(box ? "Box Cover" : type.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.slate(700)).lineLimit(1)
				if warn != nil { LucideIcon(icon: .triangleAlert, size: 12).foregroundStyle(Color.amber(700)) }
				Spacer(minLength: 2)
				if let c = current ?? fallback {
					Text(verbatim: "\(c.width)×\(c.height)").font(.system(size: 10)).monospacedDigit().foregroundStyle(Color.slate(500)).lineLimit(1)
						.help(current.map { "\($0.width)×\($0.height), \(Self.bytes($0.data.count))" } ?? "")
				}
				if multiple && !items.isEmpty { Text("\(i + 1)/\(items.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.slate(500)) }
			}
			ZStack {
				Color.white.opacity(0.7)
				if let c = current ?? fallback, let img = app.thumbnail(c, size: 400) {
					Color.clear.overlay { Image(nsImage: img).resizable().scaledToFill() }.clipped().opacity(current == nil ? 0.7 : 1)
						.onTapGesture(count: 2) { app.fullCover = c }
						.help(current.map { "\($0.width)×\($0.height), \(Self.bytes($0.data.count)) — double-click to view full size" } ?? "Double-click to view full size")
				} else {
					Text("Drop image or click Upload").font(.system(size: 11)).multilineTextAlignment(.center).foregroundStyle(Color.slate(400)).padding(4)
				}
				if busy { Color.white.opacity(0.7); Spinner(icon: .loader2, size: 20).foregroundStyle(Color.slate(700)) }
			}
			.aspectRatio(1, contentMode: .fit)
			.clipShape(RoundedRectangle(cornerRadius: 8))
			HStack(spacing: 2) {
				if multiple {
					small("‹", .slate(600), disabled: items.count < 2, help: "Previous image") { at = (i - 1 + items.count) % items.count }
					small("›", .slate(600), disabled: items.count < 2, help: "Next image") { at = (i + 1) % items.count }
				}
				if current == nil && fallback == nil { small("Upload", .slate(700)) { app.chooseArtwork(album, type: type, disc: disc, box: box) } }
				if current != nil || fallback != nil {
					small("Delete", .rose(600), hover: .rose(50)) { remove(current) }
				}
				if multiple { small("+", .slate(700), help: "Add an image") { app.chooseArtwork(album, type: type, disc: disc, box: box) } }
				if type == .front {
					Spacer(minLength: 0)
					Menu {
						Button { app.chooseArtwork(album, type: .front, disc: disc, box: box) } label: { Label { Text("Upload image") } icon: { Image(nsImage: Lucide.upload.image.sized(16)) } }
						Button { app.pasteCover(album, disc: disc, box: box) } label: { Label { Text("Paste image") } icon: { Image(nsImage: Lucide.clipboardPaste.image.sized(16)) } }
						Button { open("https://covers.musichoarders.xyz/?" + Self.query(["artist": album.artist, "album": album.title])) } label: { Label { Text("Search musichoarders") } icon: { Image(nsImage: Asset.musichoarders.image.onTile(16)) } }
						Button { open("https://albumartexchange.com/covers?" + Self.query(["q": [album.artist, album.title].filter { !$0.isEmpty }.joined(separator: " "), "fltr": "ALL", "sort": "SCORE", "status": "", "size": "any"])) } label: { Label { Text("Search albumartexchange") } icon: { Image(nsImage: Asset.albumartexchange.image.sized(16)) } }
						Divider()
						Button(role: .destructive) { remove(current) } label: { Label { Text("Remove cover") } icon: { Image(nsImage: Lucide.trash2.image.sized(16)) } }
					} label: { LucideIcon(icon: .ellipsis, size: 14).foregroundStyle(Color.slate(500)) }
						.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Cover options")
				}
			}
		}
		.padding(8)
		.frame(minHeight: 144, alignment: .top)
		.background(warn != nil ? Color.amber(50) : Color.slate(50), in: RoundedRectangle(cornerRadius: 12))
		.overlay(RoundedRectangle(cornerRadius: 12).stroke(targeted ? Color.slate(800) : focused ? Color.slate(400) : warn != nil ? Color.amber(400) : Color.slate(200), lineWidth: targeted ? 4 : focused ? 2 : 1))
		.help(warn ?? "")
		.onDrop(of: ["public.file-url", "public.image"], isTargeted: $targeted) { app.dropCover(album, providers: $0, type: type, replacing: current?.data, disc: disc, box: box) }
		.focusable().focused($focused).focusEffectDisabled()
		.simultaneousGesture(TapGesture().onEnded { focused = true })
		.onPasteCommand(of: [.fileURL, .png, .jpeg, .tiff, .image]) { _ in app.pasteCover(album, type: type, disc: disc, box: box) }   // front replaced, others appended (ADR 0096)
	}

	/// Delete: one back/leaflet/media image, the box cover at once, the front cover after the Remove cover dialog.
	func remove(_ c: Cover?) {
		if box { app.removeArtwork(album, type: .front, data: c?.data, box: true) }
		else if type == .front { app.sheet = .coverDelete }
		else if let c { app.removeArtwork(album, type: type, data: c.data, disc: disc) }
	}

	func small(_ t: String, _ c: Color, hover: Color = .white, disabled: Bool = false, help: String = "", _ action: @escaping () -> Void) -> some View {
		Button(t, action: action).buttonStyle(TinyButton(color: c, hover: hover)).disabled(disabled).help(help)
	}
	func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
	static func query(_ q: [String: String]) -> String {
		var c = URLComponents(); c.queryItems = q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }; return c.percentEncodedQuery ?? ""
	}
	static func bytes(_ n: Int) -> String { n >= 1_048_576 ? String(format: "%.1f MB", Double(n) / 1_048_576) : n >= 1024 ? "\(Int((Double(n) / 1024).rounded())) KB" : "\(n) B" }
}

/// The artwork fields' footer buttons: `rounded px-1.5 text-[11px] hover:bg-white`.
struct TinyButton: ButtonStyle {
	var color: Color
	var hover: Color = .white
	func makeBody(configuration c: Configuration) -> some View { B(c: c, s: self) }
	struct B: View {
		let c: Configuration, s: TinyButton
		@State private var over = false
		@Environment(\.isEnabled) private var enabled
		var body: some View {
			c.label.font(.system(size: 11)).foregroundStyle(s.color).padding(.horizontal, 6).padding(.vertical, 1)
				.background(over && enabled ? s.hover : .clear, in: RoundedRectangle(cornerRadius: 4))
				.opacity(enabled ? 1 : 0.3).onHover { over = $0 }.contentShape(Rectangle())
		}
	}
}

/// "Artwork for" (inspector.tsx DiscSwitch, ADR 0098): All discs, Disc 1, Disc 2, … in a pill across the width of
/// the cover fields; when the discs do not fit it scrolls sideways with ‹ › at its ends, keeping the chosen disc in view.
struct DiscSwitch: View {
	var discs: [Int]
	var disc: Int?
	var choose: (Int?) -> Void
	@State private var pos = ScrollPosition(idType: Int.self)
	@State private var geo = (x: 0.0, width: 0.0, content: 0.0)

	var body: some View {
		let left = geo.x > 1, right = geo.x + geo.width < geo.content - 1
		HStack(spacing: 8) {
			Text("Artwork for").font(.system(size: 12)).foregroundStyle(Color.slate(500)).fixedSize()
			HStack(spacing: 0) {
				if left || right { arrow("‹", "Earlier discs", enabled: left) { pos.scrollTo(x: max(0, geo.x - geo.width * 0.6)) } }
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 0) {
						ForEach([-1] + discs, id: \.self) { d in
							let on = (d == -1 ? nil : d) == disc
							Button { choose(d == -1 ? nil : d) } label: {
								Text(d == -1 ? "All discs" : "Disc \(d)").font(.system(size: 12)).lineLimit(1).fixedSize()
									.foregroundStyle(on ? Color.slate(900) : Color.slate(500)).padding(.horizontal, 10).frame(maxHeight: .infinity)
									.background(on ? Color.slate(200) : .clear, in: Capsule()).contentShape(Capsule())
							}.buttonStyle(.plain).pointer().id(d)
						}
					}.scrollTargetLayout()
				}
				.scrollPosition($pos)
				.onScrollGeometryChange(for: [Double].self) { [$0.contentOffset.x, $0.containerSize.width, $0.contentSize.width] } action: { _, v in geo = (v[0], v[1], v[2]) }
				if left || right { arrow("›", "Later discs", enabled: right) { pos.scrollTo(x: geo.x + geo.width * 0.6) } }
			}
			.padding(2).frame(height: 28).frame(maxWidth: .infinity)
			.background(.white, in: Capsule()).overlay(Capsule().stroke(Color.slate(300)))
		}
		.onChange(of: disc) { withAnimation { pos.scrollTo(id: disc ?? -1) } }
	}

	func arrow(_ t: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
		Button { withAnimation { action() } } label: { Text(t).font(.system(size: 14)).foregroundStyle(Color.slate(500)).frame(width: 24).frame(maxHeight: .infinity).contentShape(Rectangle()) }
			.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.3).help(help)
	}
}
