import SwiftUI
import UniformTypeIdentifiers

// library.tsx: the top-bar indicator, the Library dialog and the Settings Library tab (ADR 0037).

func n(_ x: Int, _ one: String) -> String { "\(x.formatted()) \(x == 1 ? one : one + "s")" }

extension LibraryWatcher {
	/// library.tsx describe(): the dot colour, whether it pulses, and the status sentence.
	var described: (color: Color, pulse: Bool, text: String) {
		let s = status
		if s.phase == "error" { return (.rose(500), false, s.error.isEmpty ? "Error" : s.error) }
		if s.phase == "scanning" || s.phase == "planning" { return (.sky(500), true, s.message.isEmpty ? "Scanning…" : s.message) }
		if s.phase == "moving" { return (.sky(500), true, s.message.isEmpty ? "Moving files…" : s.message) }
		if !settings.apply, !s.planned.isEmpty { return (.amber(500), false, "Report only: \(s.planned.count) move\(s.planned.count > 1 ? "s" : "") planned") }
		if s.phase == "waiting" { return (.amber(500), false, s.message.isEmpty ? "Waiting for files to settle" : s.message) }
		if !s.unplaced.isEmpty { return (.amber(500), false, "\(s.unplaced.count) file\(s.unplaced.count > 1 ? "s" : "") cannot be placed") }
		return (.emerald(500), false, s.phase == "starting" ? "Starting…" : "Up to date")
	}
}

struct Dot: View {
	var color: Color
	var pulse = false
	@State private var dim = false
	var body: some View {
		Circle().fill(color).frame(width: 8, height: 8).opacity(pulse && dim ? 0.4 : 1)
			.animation(pulse ? .easeInOut(duration: 1).repeatForever() : .default, value: dim).onAppear { dim = true }
	}
}

struct LibraryIndicator: View {
	@ObservedObject var lib: LibraryWatcher
	var open: () -> Void
	@State private var over = false
	var body: some View {
		let s = lib.status, d = lib.described
		Button(action: open) {
			HStack(spacing: 8) {
				Dot(color: d.color, pulse: d.pulse)
				VStack(alignment: .leading, spacing: 0) {
					Text("\(n(s.artists, "artist")) · \(n(s.albums, "album")) · \(n(s.tracks, "track"))").font(.system(size: 15, weight: .medium)).lineLimit(1)
					Text(d.text).font(.system(size: 15)).foregroundStyle(Color.slate(500)).lineLimit(1)
				}
				Spacer(minLength: 0)
			}
			.padding(4).background(over ? Color.white.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
		}.buttonStyle(.plain).onHover { over = $0 }.help("Library status")
	}
}

// MARK: Library dialog

struct LibrarySheet: View {
	@ObservedObject var lib: LibraryWatcher
	@EnvironmentObject var app: AppState
	@Environment(\.dialogMaxHeight) var maxH
	func ago(_ d: Date?) -> String {
		guard let d else { return "never" }
		let s = Int(max(0, -d.timeIntervalSinceNow))
		return s < 90 ? "\(s) s ago" : s < 5400 ? "\(Int((Double(s) / 60).rounded())) min ago" : "\(Int((Double(s) / 3600).rounded())) h ago"
	}
	var body: some View {
		let s = lib.status, d = lib.described
		Shell(title: "Library", width: 640, saveLabel: nil, cancelLabel: "Close", onClose: { app.sheet = nil }) {
			Dot(color: d.color, pulse: d.pulse)
		} content: {
			VStack(alignment: .leading, spacing: 0) {
				HStack(spacing: 8) {
					ForEach([("Album artists", s.artists), ("Albums", s.albums), ("Tracks", s.tracks)], id: \.0) { l, v in
						VStack(spacing: 0) { Text(v.formatted()).font(.system(size: 20, weight: .semibold)); Text(l).font(.system(size: 12)).foregroundStyle(Color.slate(500)) }
							.frame(maxWidth: .infinity).padding(.vertical, 8).background(Color.slate(100), in: RoundedRectangle(cornerRadius: 12))
					}
				}
				Text(d.text).font(.system(size: 14)).padding(.top, 12)
				Text(lib.rootPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.slate(500)).textSelection(.enabled).padding(.top, 4)
				Text("Last scan \(ago(s.lastScan)), last full pass \(ago(s.lastFull)). \(lib.settings.apply ? "Changes are applied after \(Int(lib.settings.cooldown)) s without any change." : "Report only: nothing is moved (turn on Apply in Settings, Library).")")
					.font(.system(size: 12)).foregroundStyle(Color.slate(500)).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
				ScrollView {
					VStack(alignment: .leading, spacing: 16) {
						section("Recent activity", s.recent.prefix(15).map { ($0.text, ago($0.t)) })
						section(lib.settings.apply ? "Waiting to move (\(s.waiting))" : "Planned moves (\(s.planned.count))", s.planned.prefix(20).map { ($0.from, "→ " + $0.to) })
						section("Cannot be placed (\(s.unplaced.count))", s.unplaced.prefix(30).map { ($0.path, $0.reason) })
						section("Skipped, conflicting names (\(s.skipped.count))", s.skipped.prefix(30).map { ($0.path, $0.reason) })
					}.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
				}.frame(maxHeight: maxH * 0.45).fixedSize(horizontal: false, vertical: s.recent.count + s.planned.count + s.unplaced.count + s.skipped.count < 10).padding(.top, 12)
				HStack(spacing: 8) {
					Button { lib.rescan(); app.notify("Re-analysis started", kind: .success) } label: { HStack(spacing: 6) { LucideIcon(icon: .rotateCw, size: 14); Text("Re-analyze") } }
						.buttonStyle(WebButton(kind: .outline)).help("Forget what is known about the folders and read everything again")
					Text("Lists every folder and file again; a large library takes a while.").font(.system(size: 12)).foregroundStyle(Color.slate(500))
					Spacer()
					Button("Export CSV") { exportCSV() }.buttonStyle(WebButton(kind: .ghost))
				}.padding(.top, 16)
			}
		}
	}
	@ViewBuilder func section(_ title: String, _ rows: [(String, String)]) -> some View {
		if !rows.isEmpty {
			VStack(alignment: .leading, spacing: 4) {
				Text(title.uppercased()).font(.system(size: 12, weight: .medium)).tracking(0.6).foregroundStyle(Color.slate(500))
				VStack(alignment: .leading, spacing: 0) {
					ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
						VStack(alignment: .leading, spacing: 0) {
							Text(r.0).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(r.0)
							Text(r.1).font(.system(size: 12)).foregroundStyle(Color.slate(500)).lineLimit(1).help(r.1)
						}.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
						.overlay(alignment: .bottom) { if i < rows.count - 1 { Rectangle().fill(Color.slate(100)).frame(height: 1) } }
					}
				}
			}
		}
	}
	func exportCSV() {
		let p = NSSavePanel(); p.nameFieldStringValue = "albums.csv"; p.allowedContentTypes = [.commaSeparatedText]
		if p.runModal() == .OK, let u = p.url { try? lib.csv().write(to: u, atomically: true, encoding: .utf8) }
	}
}

// MARK: Settings, Library tab: behaviour and the path template with a live preview

struct LibraryTab: View {
	@ObservedObject var lib: LibraryWatcher
	@Binding var draft: LibrarySettings
	@State private var preview: (errors: [String], warnings: [String], album: String, albumDir: String, files: [(from: String, name: String, problem: String)])?
	@State private var sel: (row: String, idx: Int)?
	@State private var drag: (src: String, idx: Int, chip: LibTemplate.Chip)?
	@State private var over = ""

	static let formats = ["text": "Text", "num": "Number, zero-padded", "int": "Number", "year": "Year (4 digits)"]
	func label(_ k: String) -> String { LibTemplate.palette.first { $0.key == k }?.label ?? k }

	var rowKeys: [(key: String, name: String)] {
		draft.template.folders.indices.map { ("f\($0)", "Folder level \($0 + 1)") } + (draft.template.discFolder != nil ? [("disc", "Disc folder (multi-disc albums only)")] : []) + [("file", "File name (the extension is added)")]
	}
	func chips(_ key: String) -> LibTemplate.Level {
		key == "file" ? draft.template.filename : key == "disc" ? (draft.template.discFolder ?? []) : draft.template.folders[Int(key.dropFirst())!]
	}
	func mutate(_ key: String, _ f: (inout LibTemplate.Level) -> Void) {
		if key == "file" { f(&draft.template.filename) }
		else if key == "disc" { var l = draft.template.discFolder ?? []; f(&l); draft.template.discFolder = l }
		else { f(&draft.template.folders[Int(key.dropFirst())!]) }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack(spacing: 12) {
				Toggle("Apply changes", isOn: $draft.apply).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
				HStack(spacing: 8) { Text("Cooldown (s)"); TextField("", value: $draft.cooldown, format: .number).webField(height: 32).frame(width: 80) }.frame(maxWidth: .infinity, alignment: .leading)
				HStack(spacing: 8) { Text("Check every (s)"); TextField("", value: $draft.interval, format: .number).webField(height: 32).frame(width: 80) }.frame(maxWidth: .infinity, alignment: .leading)
			}.font(.system(size: 14))
			Text("With Apply off the library only reports what it would move. A file is acted on only after nothing in its folder has changed for the cooldown.").font(.system(size: 12)).foregroundStyle(Color.slate(500)).padding(.top, -8)

			VStack(alignment: .leading, spacing: 4) {
				(Text("Tags ").fontWeight(.medium) + Text("(drag into a row below)").foregroundStyle(Color.slate(500))).font(.system(size: 14))
				FlowRow {
					ForEach(LibTemplate.palette, id: \.key) { p in
						paletteChip(p.label, dashed: false).onDrag {
							drag = ("palette", 0, LibTemplate.Chip(tag: p.key, fmt: ["DISCNUMBER", "TRACKNUMBER"].contains(p.key) ? "num" : ["DATE", "ORIGINALDATE"].contains(p.key) ? "year" : "text", pad: ["DISCNUMBER", "TRACKNUMBER"].contains(p.key) ? 2 : 0))
							return NSItemProvider(object: p.key as NSString)
						}
					}
					paletteChip("Text", dashed: true).onDrag { drag = ("palette", 0, LibTemplate.Chip(text: "_")); return NSItemProvider(object: "_" as NSString) }
				}
			}

			VStack(alignment: .leading, spacing: 8) {
				ForEach(rowKeys, id: \.key) { r in templateRow(r.key, r.name) }
				HStack(spacing: 8) {
					if draft.template.folders.count < LibTemplate.maxLevels { Button { draft.template.folders.append([]) } label: { HStack(spacing: 4) { LucideIcon(icon: .plus, size: 12); Text("Folder level") } }.buttonStyle(WebButton(kind: .outline, size: .xs)) }
					if draft.template.discFolder == nil { Button { draft.template.discFolder = [LibTemplate.Chip(text: "Disc "), LibTemplate.Chip(tag: "DISCNUMBER", fmt: "int")] } label: { HStack(spacing: 4) { LucideIcon(icon: .plus, size: 12); Text("Disc folder") } }.buttonStyle(WebButton(kind: .outline, size: .xs)) }
					Button("Reset to bliss default") { draft.template = LibTemplate.default; sel = nil }.buttonStyle(WebButton(kind: .ghost, size: .xs))
				}.padding(.leading, 184)
			}

			if let s = sel, s.idx < chips(s.row).count { chipEditor(s.row, s.idx) }

			if let p = preview { previewBox(p) }
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.task(id: draft.template) { try? await Task.sleep(nanoseconds: 400_000_000); if !Task.isCancelled { preview = lib.preview(draft.template) } }
	}

	func paletteChip(_ t: String, dashed: Bool) -> some View {
		HStack(spacing: 4) { LucideIcon(icon: .gripVertical, size: 12).foregroundStyle(Color.slate(400)); Text(t) }
			.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 2)
			.background(.white, in: Capsule()).overlay(Capsule().stroke(dashed ? Color.slate(400) : .slate(300), style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : [])))
			.onHover { $0 ? NSCursor.openHand.push() : NSCursor.pop() }
	}

	func chipText(_ c: LibTemplate.Chip) -> String {
		c.tag.isEmpty ? "“\(c.text)”" : label(c.tag) + (c.fmt != "text" ? " · \(c.fmt == "num" ? "#\(c.pad > 0 ? "\(c.pad)" : "")" : c.fmt)" : "") + (c.fallback.isEmpty ? "" : " / \(label(c.fallback))")
	}

	func templateRow(_ key: String, _ name: String) -> some View {
		let cs = chips(key)
		return HStack(spacing: 8) {
			Text(name).font(.system(size: 12)).foregroundStyle(Color.slate(600)).frame(width: 176, alignment: .leading)
			FlowRow {
				if cs.isEmpty { Text("drop tags here").font(.system(size: 12)).foregroundStyle(Color.slate(400)).padding(.horizontal, 4).frame(height: 22) }
				ForEach(Array(cs.enumerated()), id: \.offset) { i, c in
					let on = sel?.row == key && sel?.idx == i
					HStack(spacing: 4) {
						Text(chipText(c))
						Button { mutate(key) { $0.remove(at: i) }; sel = nil } label: { LucideIcon(icon: .x, size: 12) }.buttonStyle(.plain).opacity(0.6).help("Remove")
					}
					.font(.system(size: 12)).foregroundStyle(c.tag.isEmpty ? Color.ink : .white).padding(.horizontal, 10).padding(.vertical, 2)
					.background(c.tag.isEmpty ? Color.white : .slate(800), in: Capsule())
					.overlay(Capsule().stroke(c.tag.isEmpty ? Color.slate(400) : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
					.overlay(Capsule().stroke(on ? Color.sky(400) : .clear, lineWidth: 2).padding(-2))
					.onTapGesture { sel = on ? nil : (key, i) }
					.onDrag { drag = (key, i, c); return NSItemProvider(object: "\(key):\(i)" as NSString) }
					.onDrop(of: [.text], isTargeted: nil) { _ in drop(key, i); return true }
				}
			}
			.padding(.horizontal, 6).padding(.vertical, 4).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
			.background(over == key ? Color.sky(50) : .slate(50), in: RoundedRectangle(cornerRadius: 8))
			.overlay(RoundedRectangle(cornerRadius: 8).stroke(over == key ? Color.sky(400) : .slate(300)))
			.onDrop(of: [.text], isTargeted: Binding(get: { over == key }, set: { over = $0 ? key : (over == key ? "" : over) })) { _ in drop(key, cs.count); return true }
			if key.hasPrefix("f"), draft.template.folders.count > 1 {
				Button { draft.template.folders.remove(at: Int(key.dropFirst())!); sel = nil } label: { LucideIcon(icon: .x, size: 16) }.buttonStyle(IconButton(color: .slate(400), hover: .clear, hoverText: .rose(600))).help("Remove this level")
			}
			if key == "disc" { Button { draft.template.discFolder = nil; sel = nil } label: { LucideIcon(icon: .x, size: 16) }.buttonStyle(IconButton(color: .slate(400), hover: .clear, hoverText: .rose(600))).help("No disc folder") }
		}
	}

	func drop(_ row: String, _ at: Int) {
		guard let d = drag else { return }
		drag = nil; over = ""
		var at = at
		if d.src != "palette" {
			mutate(d.src) { $0.remove(at: d.idx) }
			if d.src == row && d.idx < at { at -= 1 }
		}
		mutate(row) { $0.insert(d.chip, at: min(at, $0.count)) }
		sel = nil
	}

	func chipEditor(_ row: String, _ i: Int) -> some View {
		let c = chips(row)[i]
		let b: (WritableKeyPath<LibTemplate.Chip, String>) -> Binding<String> = { kp in Binding(get: { chips(row)[i][keyPath: kp] }, set: { v in mutate(row) { $0[i][keyPath: kp] = v } }) }
		return HStack(spacing: 12) {
			if !c.tag.isEmpty {
				Text(label(c.tag)).fontWeight(.medium)
				HStack(spacing: 4) { Text("Format"); Picker("", selection: b(\.fmt)) { ForEach(["text", "num", "int", "year"], id: \.self) { Text(Self.formats[$0]!).tag($0) } }.labelsHidden().fixedSize() }
				if c.fmt == "num" { HStack(spacing: 4) { Text("Digits"); TextField("", value: Binding(get: { chips(row)[i].pad }, set: { v in mutate(row) { $0[i].pad = max(0, min(6, v)) } }), format: .number).webField(height: 32).frame(width: 64) } }
				HStack(spacing: 4) {
					Text("If empty use")
					Picker("", selection: b(\.fallback)) { Text("nothing (file stays)").tag(""); ForEach(LibTemplate.palette.filter { $0.key != c.tag }, id: \.key) { Text($0.label).tag($0.key) } }.labelsHidden().fixedSize()
				}.help("Used when this tag is empty. Off by default: an empty tag keeps the file where it is.")
			} else {
				HStack(spacing: 8) { Text("Text"); TextField("", text: b(\.text)).font(.system(size: 14, design: .monospaced)).webField(height: 32).frame(width: 160) }
			}
			Spacer(minLength: 0)
		}.font(.system(size: 14)).padding(8).background(Color.slate(100), in: RoundedRectangle(cornerRadius: 8))
	}

	func previewBox(_ p: (errors: [String], warnings: [String], album: String, albumDir: String, files: [(from: String, name: String, problem: String)])) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			(Text("Preview").fontWeight(.medium) + Text(!p.album.isEmpty && p.album != "." ? " · from \(p.album)" : "").foregroundStyle(Color.slate(500)))
			ForEach(p.errors, id: \.self) { Text($0).foregroundStyle(Color.rose(600)) }
			ForEach(p.warnings, id: \.self) { Text($0).foregroundStyle(Color.amber(600)) }
			if !p.albumDir.isEmpty {
				Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 2) {
					GridRow { Text("Album folder").foregroundStyle(Color.slate(500)).frame(width: 88, alignment: .leading); Text(p.albumDir + "/").font(.system(size: 12, design: .monospaced)) }
					GridRow {
						Text("File names").foregroundStyle(Color.slate(500))
						VStack(alignment: .leading, spacing: 2) { ForEach(Array(p.files.filter { !$0.name.isEmpty }.prefix(12).enumerated()), id: \.offset) { _, f in Text(f.name).font(.system(size: 12, design: .monospaced)).lineLimit(1) } }
					}
				}.padding(.top, 4)
			}
			ForEach(Array(p.files.filter { !$0.problem.isEmpty }.prefix(4).enumerated()), id: \.offset) { _, f in
				Text("\(URL(fileURLWithPath: f.from).lastPathComponent): \(f.problem)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.amber(600)).lineLimit(1)
			}
			if p.files.isEmpty && p.errors.isEmpty { Text("No albums in the library yet.").foregroundStyle(Color.slate(400)) }
		}
		.font(.system(size: 12)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
		.overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.slate(200)))
	}
}
