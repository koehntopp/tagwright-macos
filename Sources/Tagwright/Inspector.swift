import SwiftUI
import UniformTypeIdentifiers

struct Inspector: View {
	@EnvironmentObject var app: AppState
	@State private var focusStep: Int?
	@State private var logOpen = false

	var body: some View {
		Group {
			if let a = app.selected {
				ScrollView {
					VStack(alignment: .leading, spacing: 16) {
						header(a)
						actions(a)
						alerts(a)
						folderBox(a)
						pipeline(a)
						tracks(a)
						logBox
					}
					.padding(24)
				}
				.task(id: a.id + a.mbid + a.discogsID) { await app.checkMusicBrainz(a) }
			} else {
				VStack(spacing: 8) {
					Image(systemName: "square.stack").font(.system(size: 36)).foregroundStyle(Color.muted.opacity(0.5))
					Text("Select an album").foregroundStyle(Color.muted)
				}.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.background(.white)
	}

	// MARK: header

	func header(_ a: Album) -> some View {
		VStack(alignment: .leading, spacing: 14) {
			VStack(alignment: .leading, spacing: 6) {
				editable(a.artist, size: 14, weight: .regular, color: Color.muted)
				editable(a.title, size: 24, weight: .semibold, color: .ink)
				Text([a.year, a.format].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 14)).foregroundStyle(Color.muted)
				HStack(spacing: 8) {
					idBadge(a.discogsID, icon: AnyView(Image(systemName: "opticaldisc.fill").foregroundStyle(Color.ink)), url: "https://www.discogs.com/release/\(a.discogsID)") { app.sheet = .discogs }
					idBadge(a.mbid, icon: AnyView(Image(systemName: "hexagon.fill").foregroundStyle(LinearGradient(colors: [Color(hex: 0xba478f), Color(hex: 0xeb743b)], startPoint: .leading, endPoint: .trailing))), url: "https://musicbrainz.org/release/\(a.mbid)") { app.sheet = .musicbrainz }
					if !a.albumDR.isEmpty { DRBadge(value: a.albumDR) }
				}.padding(.top, 2)
			}
			artworkRow(a)
		}
	}

	func editable(_ s: String, size: CGFloat, weight: Font.Weight, color: Color) -> some View {
		HStack(spacing: 6) {
			Text(s).font(.system(size: size, weight: weight)).foregroundStyle(color).textSelection(.enabled)
			Button { app.sheet = .tagEditor } label: { LucideIcon(icon: .pencil, size: max(13, size * 0.6)) }.buttonStyle(IconButton(hover: Color.board)).help("Edit in the Tag Editor")
			Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string); app.notify("Copied") } label: { LucideIcon(icon: .copy, size: max(12, size * 0.55)) }
				.buttonStyle(IconButton(color: Color.muted, hover: Color.board)).help("Copy")
		}
	}

	/// Service icon plus the ID (opens the release page) or a red "missing"; the pencil opens the search.
	func idBadge(_ id: String, icon: AnyView, url: String, search: @escaping () -> Void) -> some View {
		HStack(spacing: 6) {
			Button { if !id.isEmpty { NSWorkspace.shared.open(URL(string: url)!) } } label: {
				HStack(spacing: 6) {
					icon.font(.system(size: 14))
					Text(id.isEmpty ? "missing" : (id.count > 12 ? String(id.prefix(8)) : id)).font(.system(size: 12, weight: .medium, design: id.isEmpty ? .default : .monospaced))
				}
				.foregroundStyle(id.isEmpty ? Color(hex: 0xbe123c) : Color.ink)
				.padding(.horizontal, 10).padding(.vertical, 4)
				.background(id.isEmpty ? Color(hex: 0xffe4e6) : Color.board, in: Capsule())
			}.buttonStyle(.plain)
			Button(action: search) { LucideIcon(icon: .pencil, size: 14) }.buttonStyle(IconButton(hover: Color.board)).help("Search")
		}
	}

	func copyable(_ s: String, size: CGFloat, weight: Font.Weight, color: Color) -> some View {
		HStack(spacing: 5) {
			Text(s).font(.system(size: size, weight: weight)).foregroundStyle(color).textSelection(.enabled)
			Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string); app.notify("Copied") } label: { LucideIcon(icon: .copy, size: 12) }
				.buttonStyle(IconButton(color: Color.muted, hover: Color.board)).help("Copy")
		}
	}

	// MARK: actions

	func actions(_ a: Album) -> some View {
		let busy = app.job != nil
		return HStack(spacing: 8) {
			Button("Tag Editor") { app.sheet = .tagEditor }.buttonStyle(SoftButton(dark: true))
			Button { app.run(a) } label: { Text(app.job?.hasPrefix("Fixing") == true ? "Running…" : "Run fixes") }
				.buttonStyle(SoftButton(danger: app.job?.hasPrefix("Fixing") == true)).disabled(busy || a.status == .needs)
				.help(a.status == .needs ? "Resolve the issues first" : "Run every open step")
			Button(app.job?.hasPrefix("Moving") == true ? "Moving…" : "Move to library") { app.sheet = .move }.buttonStyle(SoftButton(danger: app.job?.hasPrefix("Moving") == true)).disabled(busy || app.source == .library || !a.canMove || !(app.mbCheck[a.id]?.mismatches.isEmpty ?? true))
				.help((app.mbCheck[a.id]?.mismatches.first).map { $0 + " Fix the release before moving." } ?? "")
		}
	}

	// MARK: artwork (ADR 0090)

	func artworkRow(_ a: Album) -> some View {
		HStack(alignment: .top, spacing: 10) {
			ForEach(ArtType.allCases) { t in ArtworkField(album: a, type: t) }
		}
	}

	// MARK: notes (ADR 0083: one shell, type at the left, button at the right)

	enum NoteType { case problem, mismatch, missing, warning, note, optional
		var label: String { ["PROBLEM", "MISMATCH", "MISSING", "WARNING", "NOTE", "OPTIONAL"][[NoteType.problem, .mismatch, .missing, .warning, .note, .optional].firstIndex(of: self)!] }
		var tone: (fg: Color, bg: Color) {
			switch self {
			case .problem, .mismatch, .missing: (Color(hex: 0xbe123c), Color(hex: 0xffe4e6))
			case .warning: (Color(hex: 0x92400e), Color(hex: 0xfef3c7))
			case .note, .optional: (Color(hex: 0x1d4ed8), Color(hex: 0xdbeafe))
			}
		}
		var icon: String { switch self { case .problem, .mismatch, .missing: "xmark.octagon"; default: "exclamationmark.triangle" } }
	}

	func noteBox(_ type: NoteType, _ lines: [(String, (() -> Void)?)], button: (String, Bool, () -> Void)? = nil) -> some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: type.icon).font(.system(size: 13)).padding(.top, 2)
			Text(type.label).font(.system(size: 11, weight: .semibold)).frame(width: 74, alignment: .leading).padding(.top, 3)
			VStack(alignment: .leading, spacing: 4) {
				ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
					if let tap = l.1 { Button(action: tap) { Text(l.0).font(.system(size: 13)).multilineTextAlignment(.leading) }.buttonStyle(.plain) }
					else { Text(l.0).font(.system(size: 13)) }
				}
			}
			Spacer(minLength: 6)
			if let b = button {
				Button(b.0, action: b.2).buttonStyle(.plain).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 3)
					.background(.white, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(b.1 ? Color.ink : Color.muted).disabled(!b.1)
			}
		}
		.foregroundStyle(type.tone.fg).padding(.horizontal, 14).padding(.vertical, 10)
		.background(type.tone.bg, in: RoundedRectangle(cornerRadius: 10))
		.overlay(RoundedRectangle(cornerRadius: 10).stroke(type.tone.fg.opacity(0.25)))
	}

	@ViewBuilder func alerts(_ a: Album) -> some View {
		// ADR 0054/0039: without a release ID the red Discogs line is the only line shown
		if a.discogsID.isEmpty {
			noteBox(.problem, [("No Discogs release ID: search for the release to assign it", nil)], button: ("Search", true, { app.sheet = .discogs }))
		} else {
			ForEach(a.issues.filter { $0.level != .error }) { i in
				switch i.level {
				case .warn: noteBox(.warning, [(i.text, nil)], button: ("Tag Editor", true, { app.sheet = .tagEditor }))
				case .ingest: noteBox(.warning, [(i.text, nil)], button: ("Upload", true, { app.chooseArtwork(a, type: .front) }))
				default: noteBox(.note, [(i.text, nil)])
				}
			}
			if let c = app.mbCheck[a.id] {
				if !c.mismatches.isEmpty { noteBox(.mismatch, c.mismatches.map { ($0, nil as (() -> Void)?) }, button: ("MusicBrainz", true, { app.sheet = .musicbrainz })) }
				if !c.notes.isEmpty { noteBox(.note, c.notes.map { ($0, nil as (() -> Void)?) }, button: ("MusicBrainz", true, { app.sheet = .musicbrainz })) }
			}
			missingBoxes(a)
		}
	}

	@ViewBuilder func missingBoxes(_ a: Album) -> some View {
		let req = a.missing.filter { !$0.step.optional }, opt = a.missing.filter(\.step.optional)
		let can = app.job == nil && a.status != .needs
		if !req.isEmpty { noteBox(.missing, req.map { m -> (String, (() -> Void)?) in ("\(m.label) on \(m.count == m.of ? "all \(m.of)" : "\(m.count) of \(m.of)") tracks", { focusStep = m.step.rawValue }) }, button: ("Run fixes", can, { app.run(a) })) }
		if !opt.isEmpty { noteBox(.optional, opt.map { m -> (String, (() -> Void)?) in ("\(m.label) on \(m.count == m.of ? "all \(m.of)" : "\(m.count) of \(m.of)") tracks", { focusStep = m.step.rawValue }) }, button: req.isEmpty ? ("Run fixes", can, { app.run(a) }) : nil) }
	}

	func folderBox(_ a: Album) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			row("CURRENT FOLDER", a.name)
			if app.source == .staging, let first = a.tracks.first, let t = try? LibTemplate.target(app.library.settings.template, first.tags.mapValues { $0.first ?? "" }) { row("NEW FOLDER", t.albumDir.joined(separator: "/")) }
			let versions = app.library.versions(master: a.masterID, excluding: a.url.path)
			ForEach(Array(versions.enumerated()), id: \.element.id) { n, v in row(n == 0 ? "IN YOUR LIBRARY" : "", v.album + (v.version.isEmpty ? "" : " " + v.version)) }
		}
		.padding(14).frame(maxWidth: .infinity, alignment: .leading)
		.background(Color.board.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
		.overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08)))
	}

	func row(_ k: String, _ v: String) -> some View {
		HStack(alignment: .top) {
			Text(k).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.muted).frame(width: 140, alignment: .leading)
			Text(v).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
			Spacer(minLength: 0)
		}
	}

	// MARK: pipeline

	func pipeline(_ a: Album) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("PIPELINE").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.muted)
			HStack(alignment: .top, spacing: 0) {
				ForEach(StepID.allCases) { s in
					let st = a.state(s)
					Button { } label: {
						VStack(spacing: 6) {
							ZStack(alignment: .bottomTrailing) {
								Circle().fill(app.runningStep == s ? Color.info.opacity(0.15) : st == .done ? Color.ok : st == .partial ? Color.warn : .white)
									.overlay(Circle().stroke(st == .open ? Color.muted.opacity(0.3) : .clear, style: StrokeStyle(lineWidth: 1, dash: s.optional ? [3] : [])))
									.frame(width: 36, height: 36)
								if app.runningStep == s { ProgressView().controlSize(.small).frame(width: 36, height: 36) }
								else { Image(systemName: s.icon).font(.system(size: 15)).foregroundStyle(st == .open ? Color.muted.opacity(0.6) : .white).frame(width: 36, height: 36) }
								if st != .open {
									Image(systemName: st == .done ? "checkmark" : "exclamationmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
										.frame(width: 13, height: 13).background(st == .done ? Color(hex: 0x047857) : Color(hex: 0xb45309), in: Circle())
								}
							}
							Text(s.label).font(.system(size: 11)).foregroundStyle(Color.ink.opacity(0.8)).lineLimit(1).minimumScaleFactor(0.8)
						}.frame(maxWidth: .infinity)
					}.buttonStyle(.plain)
					.simultaneousGesture(TapGesture(count: 2).onEnded { if app.job == nil { app.run(a, steps: [s]) } })
					.simultaneousGesture(TapGesture().onEnded { focusStep = focusStep == s.rawValue ? nil : s.rawValue })
					.help("\(s.label): double-click to run only this step.")
				}
			}
			.background(alignment: .top) { Rectangle().fill(Color.black.opacity(0.08)).frame(height: 2).padding(.horizontal, 40).padding(.top, 17) }
		}
	}

	// MARK: tracks

	func tracks(_ a: Album) -> some View {
		let missing = focusStep.flatMap { StepID(rawValue: $0) }.map { Set(a.missingTracks($0).map(\.id)) }
		return VStack(alignment: .leading, spacing: 4) {
			HStack { Text("Tracks").font(.system(size: 14, weight: .semibold)); Pill(text: "\(a.tracks.count)", bg: .white) }.padding(.bottom, 6)
			ForEach(a.tracks) { t in
				HStack(spacing: 8) {
					Button { app.play(t) } label: {
						LucideIcon(icon: app.playing == t.id && !app.paused ? .pause : .play, size: 14)
					}
						.buttonStyle(IconButton()).help(app.playing == t.id && !app.paused ? "Pause" : "Play")
					Text(t.number.isEmpty ? "" : String(format: "%02d", Int(t.number) ?? 0)).font(.system(size: 12)).foregroundStyle(Color.muted).frame(width: 22, alignment: .leading)
					Text(t.title).font(.system(size: 13)).lineLimit(1)
					Spacer(minLength: 4)
					if let m = missing { Image(systemName: m.contains(t.id) ? "xmark" : "checkmark").foregroundStyle(m.contains(t.id) ? Color.bad : Color.ok).font(.system(size: 12, weight: .bold)) }
					Text(Self.mmss(t.info.duration)).font(.system(size: 12)).foregroundStyle(Color.muted).monospacedDigit()
					Pill(text: t.channelsLabel, fg: Color.ink.opacity(0.7), bg: Color(hex: 0xe5e7eb))
					Pill(text: t.formatLabel, bg: .white)
					if !t.dr.isEmpty { DRBadge(value: t.dr) } else { Pill(text: "---", fg: Color.muted, bg: Color(hex: 0xe5e7eb)) }
					Button { app.lyricsTrack = t.id; app.sheet = .lyrics } label: { lyricBadge(t) }.buttonStyle(.plain)
					Button { app.lyricsTrack = t.id; app.sheet = .lyrics } label: { LucideIcon(icon: .pencil, size: 14) }.buttonStyle(IconButton()).help("Edit lyrics")
				}
				.padding(.vertical, 4).padding(.leading, 8)   // room for the playing marker left of the button
				.background(app.playing == t.id ? Color(hex: 0xfef9c3) : .clear)
				.overlay(alignment: .leading) { if app.playing == t.id { Rectangle().fill(Color.warn).frame(width: 3) } }
				Divider().opacity(0.5)
			}
		}
		.padding(16).background(Color.board.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
	}

	@ViewBuilder func lyricBadge(_ t: Track) -> some View {
		switch t.lyricsKind {
		case .lrc: Pill(text: "LRC", fg: .white, bg: .ok)
		case .txt: Pill(text: "TXT", fg: .black, bg: .warn)
		case .instr: Pill(text: "INS", fg: .white, bg: .info)
		case .none: Pill(text: "---", fg: .white, bg: .bad)
		}
	}

	static func mmss(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

	var logBox: some View {
		DisclosureGroup(isExpanded: $logOpen) {
			ScrollView {
				Text(app.logLines.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
			}.frame(height: 160)
		} label: { Text("Log").font(.system(size: 14, weight: .semibold)) }
		.padding(16).background(Color.board.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
		.onChange(of: app.job) { _, j in if j != nil { logOpen = true } }
	}
}

struct ArtworkField: View {
	@EnvironmentObject var app: AppState
	var album: Album
	var type: ArtType
	@State private var targeted = false

	var body: some View {
		let imgs = album.artwork[type.rawValue] ?? []
		let warn = type == .front && album.coverTooSmall
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 4) {
				Text(type.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
				if type == .front, let c = imgs.first { Text(verbatim: "\(c.width)×\(c.height)").font(.system(size: 9)).foregroundStyle(Color.muted).lineLimit(1) }
				Spacer(minLength: 0)
			}
			ZStack {
				RoundedRectangle(cornerRadius: 8).fill(targeted ? Color.info.opacity(0.12) : Color.board.opacity(0.6))
				if imgs.isEmpty {
					Text("Drop image or click Upload").font(.system(size: 10)).multilineTextAlignment(.center).foregroundStyle(Color.muted.opacity(0.7)).padding(8)
				} else {
					ScrollView(.vertical, showsIndicators: false) {
						VStack(spacing: 4) {
							ForEach(imgs) { c in
								ZStack(alignment: .topTrailing) {
									if let img = app.thumbnail(c, size: 400) { Image(nsImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 4)) }
									Button { app.removeArtwork(album, type: type, data: c.data) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, Color.bad) }.buttonStyle(.plain).padding(3).help("Delete")
								}
								.onTapGesture { app.fullCover = c; app.sheet = .cover }
							}
						}.padding(4)
					}
				}
			}
			.frame(height: 124)
			.overlay(RoundedRectangle(cornerRadius: 8).stroke(warn ? Color.warn : (targeted ? Color.info : Color.black.opacity(0.08)), lineWidth: warn ? 2 : 1))
			.onDrop(of: ["public.file-url", "public.image"], isTargeted: $targeted) { app.dropCover(album, providers: $0, type: type) }
			HStack(spacing: 8) {
				Button("Upload") { app.chooseArtwork(album, type: type) }
				Button { app.pasteCover(album, type: type) } label: { Image(systemName: "doc.on.clipboard") }.help("Paste image from the clipboard")
			}.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Color.muted)
		}
		.frame(maxWidth: .infinity)
		.padding(8).background(.white, in: RoundedRectangle(cornerRadius: 10))
		.overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08)))
	}
}
