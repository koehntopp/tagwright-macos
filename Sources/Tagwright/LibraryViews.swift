import SwiftUI
import UniformTypeIdentifiers

// MARK: top bar indicator (ADR 0037)

func n(_ x: Int, _ one: String) -> String { "\(x.formatted()) \(x == 1 ? one : one + "s")" }

struct LibraryIndicator: View {
	@ObservedObject var lib: LibraryWatcher
	var open: () -> Void
	var d: (color: Color, text: String) {
		let s = lib.status
		if s.phase == "error" { return (.bad, s.error.isEmpty ? "Error" : s.error) }
		if s.phase == "scanning" || s.phase == "planning" { return (.info, s.message.isEmpty ? "Scanning…" : s.message) }
		if s.phase == "moving" { return (.info, s.message.isEmpty ? "Moving files…" : s.message) }
		if !lib.settings.apply, !s.planned.isEmpty { return (.warn, "Report only: \(s.planned.count) move\(s.planned.count > 1 ? "s" : "") planned") }
		if s.phase == "waiting" { return (.warn, s.message.isEmpty ? "Waiting for files to settle" : s.message) }
		if !s.unplaced.isEmpty { return (.warn, "\(s.unplaced.count) file\(s.unplaced.count > 1 ? "s" : "") cannot be placed") }
		return (.ok, s.phase == "starting" ? "Starting…" : "Up to date")
	}
	var body: some View {
		let s = lib.status
		Button(action: open) {
			HStack(spacing: 8) {
				Circle().fill(d.color).frame(width: 8, height: 8)
				VStack(alignment: .leading, spacing: 1) {
					Text("\(n(s.artists, "artist")) · \(n(s.albums, "album")) · \(n(s.tracks, "track"))").font(.system(size: 14, weight: .semibold)).lineLimit(1)
					Text(d.text).font(.system(size: 13)).foregroundStyle(Color.muted).lineLimit(1)
				}
			}.padding(.horizontal, 20).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
		}.buttonStyle(.plain).help("Library status")
	}
}

// MARK: status dialog

struct LibrarySheet: View {
	@ObservedObject var lib: LibraryWatcher
	@EnvironmentObject var app: AppState
	@Environment(\.dismiss) var dismiss
	func ago(_ d: Date?) -> String {
		guard let d else { return "never" }
		let s = Int(max(0, -d.timeIntervalSinceNow))
		return s < 90 ? "\(s) s ago" : s < 5400 ? "\(Int((Double(s) / 60).rounded())) min ago" : "\(Int((Double(s) / 3600).rounded())) h ago"
	}
	var body: some View {
		let s = lib.status
		SheetFrame(title: "Library", width: 720, height: 620) {
			VStack(alignment: .leading, spacing: 14) {
				HStack {
					VStack(alignment: .leading, spacing: 2) {
						Text("\(n(s.artists, "artist")) · \(n(s.albums, "album")) · \(n(s.tracks, "track"))").font(.system(size: 15, weight: .semibold))
						Text(s.phase == "error" ? s.error : (s.message.isEmpty ? "Last pass \(ago(s.lastScan)), last full pass \(ago(s.lastFull))" : s.message)).font(.system(size: 12)).foregroundStyle(s.phase == "error" ? Color.bad : Color.muted)
					}
					Spacer()
					Button { lib.rescan() } label: { Label("Re-analyze", systemImage: "arrow.clockwise") }.help("A full pass now: lists and stats every file")
					Button { exportCSV() } label: { Label("Export CSV", systemImage: "tablecells") }
				}
				Text(lib.settings.apply ? "Files are moved to the layout after \(Int(lib.settings.cooldown)) s without changes." : "Report only: nothing is moved (turn Apply on in Settings > Library).").font(.system(size: 12)).foregroundStyle(Color.muted)
				ScrollView {
					VStack(alignment: .leading, spacing: 16) {
						section("Planned moves", s.planned.map { ($0.from, "→ " + $0.to) })
						section("Cannot be placed", s.unplaced.map { ($0.path, $0.reason) })
						section("Skipped: fix the tags", s.skipped.map { ($0.path, $0.reason) })
						section("Recent activity", s.recent.map { ($0.text, $0.t.formatted(date: .omitted, time: .standard)) })
						if s.planned.isEmpty && s.unplaced.isEmpty && s.skipped.isEmpty && s.recent.isEmpty { Text("Nothing to do: the library is in order.").font(.system(size: 13)).foregroundStyle(Color.muted) }
					}.frame(maxWidth: .infinity, alignment: .leading)
				}
				HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(Color.ink).keyboardShortcut(.defaultAction) }
			}.padding(20)
		}
	}
	@ViewBuilder func section(_ title: String, _ rows: [(String, String)]) -> some View {
		if !rows.isEmpty {
			VStack(alignment: .leading, spacing: 4) {
				Text(title.uppercased()).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.muted)
				ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
					VStack(alignment: .leading, spacing: 0) {
						Text(r.0).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
						Text(r.1).font(.system(size: 12)).foregroundStyle(Color.muted).lineLimit(2)
					}.padding(.vertical, 3)
					Divider()
				}
			}
		}
	}
	func exportCSV() {
		let p = NSSavePanel(); p.nameFieldStringValue = "albums.csv"; p.allowedContentTypes = [.commaSeparatedText]
		if p.runModal() == .OK, let u = p.url { try? lib.csv().write(to: u, atomically: true, encoding: .utf8) }
	}
}

// MARK: settings, Library tab (ADR 0037): behaviour and the path template with a live preview

struct LibraryTab: View {
	@ObservedObject var lib: LibraryWatcher
	@Binding var draft: LibrarySettings
	@State private var preview: (errors: [String], warnings: [String], album: String, albumDir: String, files: [(from: String, name: String, problem: String)])?

	var body: some View {
		Form {
			Section("Watcher") {
				Toggle("Apply: move files into the layout", isOn: $draft.apply)
				Text(draft.apply ? "New and changed files are moved and renamed after the cooldown." : "Report only: the status lists what would move, nothing changes.").font(.caption).foregroundStyle(Color.muted)
				Stepper(value: $draft.cooldown, in: 0...3600, step: 10) { Text(verbatim: "Cooldown: \(Int(draft.cooldown)) s") }
				Stepper(value: $draft.interval, in: 10...3600, step: 10) { Text(verbatim: "Check every \(Int(draft.interval)) s") }
				Stepper(value: $draft.sweepHours, in: 1...168, step: 1) { Text(verbatim: "Full pass at least every \(Int(draft.sweepHours)) h") }
			}
			Section("Layout") {
				ForEach(draft.template.folders.indices, id: \.self) { i in
					levelRow("Folder \(i + 1)", $draft.template.folders[i]) { if draft.template.folders.count > 1 { draft.template.folders.remove(at: i) } }
				}
				if draft.template.folders.count < LibTemplate.maxLevels {
					Button("Add folder level") { draft.template.folders.append([LibTemplate.Chip(tag: "ALBUM")]) }
				}
				Toggle("Disc folder for multi-disc albums", isOn: Binding(get: { draft.template.discFolder != nil }, set: { draft.template.discFolder = $0 ? LibTemplate.default.discFolder : nil }))
				if draft.template.discFolder != nil { levelRow("Disc folder", Binding($draft.template.discFolder)!, remove: nil) }
				levelRow("File name", $draft.template.filename, remove: nil)
				Button("Reset to the bliss layout") { draft.template = LibTemplate.default }
			}
			Section("Preview") {
				if let p = preview {
					ForEach(p.errors + [], id: \.self) { Text($0).font(.caption).foregroundStyle(Color.bad) }
					ForEach(p.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(Color.warn) }
					if p.errors.isEmpty {
						Text(p.album.isEmpty ? "The library has no files yet." : "Album \(p.album)").font(.caption).foregroundStyle(Color.muted)
						if !p.albumDir.isEmpty { Text(p.albumDir + "/").font(.system(size: 12, weight: .semibold, design: .monospaced)) }
						ForEach(Array(p.files.prefix(12).enumerated()), id: \.offset) { _, f in
							Text(f.problem.isEmpty ? f.name : "\(URL(fileURLWithPath: f.from).lastPathComponent): \(f.problem)").font(.system(size: 12, design: .monospaced)).foregroundStyle(f.problem.isEmpty ? Color.ink : Color.warn)
						}
					}
				}
			}
		}
		.formStyle(.grouped).scrollContentBackground(.hidden).frame(maxWidth: .infinity, maxHeight: .infinity)
		.task(id: draft.template) { try? await Task.sleep(nanoseconds: 400_000_000); if !Task.isCancelled { preview = lib.preview(draft.template) } }
	}

	func levelRow(_ title: String, _ level: Binding<LibTemplate.Level>, remove: (() -> Void)?) -> some View {
		HStack(alignment: .center, spacing: 6) {
			Text(title).frame(width: 80, alignment: .leading)
			ForEach(level.wrappedValue.indices, id: \.self) { j in
				ChipView(chip: level[j], left: j > 0 ? { level.wrappedValue.swapAt(j, j - 1) } : nil, right: j < level.wrappedValue.count - 1 ? { level.wrappedValue.swapAt(j, j + 1) } : nil, remove: { level.wrappedValue.remove(at: j) })
			}
			Menu {
				ForEach(LibTemplate.palette, id: \.key) { p in Button(p.label) { level.wrappedValue.append(LibTemplate.Chip(tag: p.key, fmt: p.key == "DATE" || p.key == "ORIGINALDATE" ? "year" : p.key == "TRACKNUMBER" || p.key == "DISCNUMBER" ? "num" : "text", pad: p.key == "TRACKNUMBER" || p.key == "DISCNUMBER" ? 2 : 0)) } }
				Divider()
				Button("Text…") { level.wrappedValue.append(LibTemplate.Chip(text: "_")) }
			} label: { Image(systemName: "plus.circle") }.menuStyle(.borderlessButton).fixedSize()
			Spacer(minLength: 0)
			if let remove { Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove this folder level") }
		}
	}
}

struct ChipView: View {
	@Binding var chip: LibTemplate.Chip
	var left: (() -> Void)?, right: (() -> Void)?, remove: () -> Void
	var label: String {
		let l = LibTemplate.palette.first { $0.key == chip.tag }?.label ?? chip.tag
		return chip.fmt == "text" ? l : "\(l) · \(chip.fmt)\(chip.fmt == "num" && chip.pad > 0 ? "\(chip.pad)" : "")"
	}
	var body: some View {
		if chip.tag.isEmpty {
			HStack(spacing: 2) {
				TextField("", text: $chip.text, prompt: Text("text")).labelsHidden().textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).frame(width: max(24, CGFloat(chip.text.count) * 8 + 12))
				menu
			}.padding(.horizontal, 6).padding(.vertical, 3).background(Color.black.opacity(0.06), in: Capsule())
		} else {
			HStack(spacing: 2) { Text(label).font(.system(size: 12, weight: .medium)); menu }
				.padding(.horizontal, 8).padding(.vertical, 3).background(Color.ink.opacity(0.1), in: Capsule())
		}
	}
	var menu: some View {
		Menu {
			if !chip.tag.isEmpty {
				Picker("Format", selection: $chip.fmt) { ForEach(LibTemplate.formats, id: \.self) { Text($0).tag($0) } }
				if chip.fmt == "num" { Picker("Padding", selection: $chip.pad) { ForEach(0...6, id: \.self) { Text("\($0)").tag($0) } } }
				Picker("If empty, use", selection: $chip.fallback) { Text("nothing (file waits)").tag(""); ForEach(LibTemplate.palette, id: \.key) { Text($0.label).tag($0.key) } }
				Divider()
			}
			if let left { Button("Move left", action: left) }
			if let right { Button("Move right", action: right) }
			Button("Remove", role: .destructive, action: remove)
		} label: { Image(systemName: "chevron.down").font(.system(size: 9)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
	}
}
