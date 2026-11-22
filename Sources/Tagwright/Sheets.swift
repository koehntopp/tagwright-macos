import SwiftUI

/// A sheet that can be enlarged: `width` is its minimum and default width, `height` the default (down to 60 %), no upper limit.
struct SheetFrame<Content: View>: View {
	var title: String
	var width: CGFloat
	var height: CGFloat? = nil
	@Environment(\.dismiss) var dismiss
	@ViewBuilder var content: Content
	var body: some View {
		VStack(spacing: 0) {
			HStack { Text(title).font(.system(size: 16, weight: .semibold)); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.muted.opacity(0.6)) }.buttonStyle(.plain).keyboardShortcut(.cancelAction) }
				.padding(.horizontal, 20).padding(.vertical, 14)
			Divider()
			content.frame(maxWidth: .infinity, maxHeight: height == nil ? nil : .infinity)
		}
		.frame(minWidth: width, idealWidth: width, maxWidth: .infinity, minHeight: height.map { $0 * 0.6 }, idealHeight: height, maxHeight: height == nil ? nil : .infinity)
		.background(.white)
	}
}

// MARK: settings (ADR 0009, 0045)

struct SettingsSheet: View {
	@EnvironmentObject var app: AppState
	@Environment(\.dismiss) var dismiss
	@State private var token = Keychain.get("discogs") ?? ""
	@State private var tab = Int(ProcessInfo.processInfo.environment["TW_TAB"] ?? "") ?? 0
	@State private var draft = LibrarySettings.load()
	var body: some View {
		SheetFrame(title: "Settings", width: 640, height: 640) { VStack(spacing: 0) {
			Picker("", selection: $tab) { Text("General").tag(0); Text("Library").tag(1) }.pickerStyle(.segmented).labelsHidden().frame(width: 220).padding(.top, 10)
			if tab == 1 { LibraryTab(lib: app.library, draft: $draft) }
			else { Form {
				Section("Folders") {
					folder("Staging folder", app.stagingPath, true)
					folder("Library folder", app.libraryPath, false)
				}
				Section("Discogs") {
					SecureField("API token", text: $token).onChange(of: token) { _, v in Keychain.set("discogs", v) }
					Text(token.isEmpty ? "No token set. Create one at discogs.com/settings/developers." : "Token saved in the macOS Keychain.").font(.caption).foregroundStyle(Color.muted)
				}
				Section("Covers") {
					Stepper(value: $app.minCover, in: 100...20000, step: 100) { Text(verbatim: "Minimum cover size: \(app.minCover) px") }
					Stepper(value: $app.maxCover, in: max(100, app.minCover)...20000, step: 100) { Text(verbatim: "Maximum cover size: \(app.maxCover) px") }
				}
				Section("Move") { Toggle("Delete the staging folder after a move", isOn: $app.deleteAfterMove) }
			}
			.formStyle(.grouped).scrollContentBackground(.hidden).frame(maxHeight: .infinity) }
			if tab == 1, !LibTemplate.validate(draft.template).errors.isEmpty { Text(LibTemplate.validate(draft.template).errors.joined(separator: "; ")).font(.caption).foregroundStyle(Color.bad).padding(.horizontal, 20) }
			HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(Color.ink).keyboardShortcut(.defaultAction).disabled(!LibTemplate.validate(draft.template).errors.isEmpty) }.padding(14)
		} }
		.onDisappear { if LibTemplate.validate(draft.template).errors.isEmpty { app.library.settings = draft }; app.rescan() }
	}
	func folder(_ label: String, _ path: String, _ staging: Bool) -> some View {
		HStack {
			VStack(alignment: .leading) { Text(label); Text(path.isEmpty ? "Not set" : path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.muted).lineLimit(1).truncationMode(.middle) }
			Spacer()
			Button("Choose…") { app.chooseFolder(staging) }
		}
	}
}

// MARK: move (ADR 0037)

struct MoveSheet: View {
	@EnvironmentObject var app: AppState
	@Environment(\.dismiss) var dismiss
	var album: Album
	var body: some View {
		let plan = Pipeline.movePlan(album: album, library: URL(fileURLWithPath: app.libraryPath.isEmpty ? "/missing" : app.libraryPath), extra: app.mbCheck[album.id]?.mismatches ?? [])
		SheetFrame(title: "Move to library", width: 640) {
			VStack(alignment: .leading, spacing: 12) {
				if app.libraryPath.isEmpty { Text("Choose a library folder in Settings first.").foregroundStyle(Color.bad) }
				Text("Library folder").font(.caption).foregroundStyle(Color.muted)
				Text(plan.folder.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
				Text(app.deleteAfterMove ? "Only the FLAC files move. Afterwards you are asked whether to delete what is left of the album folder." : "Only the FLAC files move; images, logs and other files stay in the staging folder.").font(.system(size: 12)).foregroundStyle(Color.muted)
				ScrollView {
					VStack(alignment: .leading, spacing: 3) {
						ForEach(Array(plan.moves.enumerated()), id: \.offset) { _, m in Text(m.to.path.replacingOccurrences(of: plan.folder.path + "/", with: "")).font(.system(size: 11, design: .monospaced)) }
					}.frame(maxWidth: .infinity, alignment: .leading)
				}.frame(height: 160).padding(8).background(Color.board, in: RoundedRectangle(cornerRadius: 8))
				ForEach(plan.problems, id: \.self) { p in Label(p, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(Color(hex: 0x92400e)) }
				HStack {
					Spacer()
					Button("Cancel") { dismiss() }
					Button("Move") { dismiss(); app.move(album) }.buttonStyle(.borderedProminent).tint(Color.ink).disabled(!plan.problems.isEmpty || app.libraryPath.isEmpty)
				}
			}.padding(20)
		}
	}
}

struct CoverSheet: View {
	var cover: Cover
	var body: some View {
		SheetFrame(title: "Artwork", width: 720) {
			if let i = NSImage(data: cover.data) {
				Image(nsImage: i).resizable().scaledToFit().frame(maxHeight: 640).padding(20)
				Text(verbatim: "\(cover.width)×\(cover.height) · \(ByteCountFormatter.string(fromByteCount: Int64(cover.data.count), countStyle: .file))").font(.caption).foregroundStyle(Color.muted).padding(.bottom, 14)
			}
		}
	}
}

// MARK: shared assignment (ADR 0053, 0078, 0081, 0089: one component for the Discogs and the MusicBrainz dialog)

struct AssignState {
	var tracks: [DTrack] = []
	var mapping: [Int?] = []
	var disc: [Int] = []
	var number: [Int] = []
	var title: [String] = []
	var releaseSub: [String] = []   // the release's disc subtitle of the assigned track
	var mineSub: [String] = []      // what the file has now
	var keepMine: [Bool] = []
	var subText: [String] = []      // editable release subtitle

	/// Proposal, then numbers 1..n per disc in release order over the selected files, discs renumbered from 1 (ADR 0053).
	mutating func propose(album: Album) {
		mapping = Assign.propose(files: album.tracks, release: tracks)
		mineSub = album.tracks.map { $0.tags.first("SET SUBTITLE", "DISCSUBTITLE") }
		keepMine = Array(repeating: false, count: mapping.count)
		renumber()
	}

	mutating func renumber() {
		disc = Array(repeating: 1, count: mapping.count); number = disc
		title = mapping.map { $0.map { tracks[$0].title } ?? "" }
		releaseSub = mapping.map { $0.map { tracks[$0].subtitle } ?? "" }
		subText = releaseSub
		let sel = mapping.enumerated().compactMap { i, m in m.map { (i, $0) } }.sorted { tracks[$0.1].id < tracks[$1.1].id }
		var discs: [Int: Int] = [:], counts: [Int: Int] = [:]
		for (i, m) in sel {
			let d = tracks[m].disc
			if discs[d] == nil { discs[d] = discs.count + 1 }
			counts[discs[d]!, default: 0] += 1
			disc[i] = discs[d]!; number[i] = counts[discs[d]!]!
		}
	}

	func subtitle(_ i: Int) -> String { keepMine[i] ? mineSub[i] : subText[i] }
	var duplicates: Bool { let m = mapping.compactMap { $0 }; return Set(m).count != m.count }
	var assigned: Int { mapping.compactMap { $0 }.count }

	/// Rows in release order (ADR 0089), skipped files last.
	var order: [Int] {
		let a = mapping.indices.filter { mapping[$0] != nil }.sorted { mapping[$0]! < mapping[$1]! }
		return a + mapping.indices.filter { mapping[$0] == nil }
	}
}

struct ReleaseInfo {
	var title: String
	var meta: [String]
	var url: URL?
	var thumb: URL?
	var tracks: Int
}

/// The assignment step: back link, the release, the file -> release track table, the titles checkbox and Cancel/Apply.
struct AssignPane: View {
	var album: Album
	var info: ReleaseInfo
	@Binding var st: AssignState
	@Binding var importTitles: Bool
	var skipNote: String?
	var applying: Bool
	var onBack: () -> Void
	var onApply: () -> Void
	var onCancel: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Button { onBack() } label: { Label("Back to search results", systemImage: "chevron.left") }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.info)
			releaseCard
			table
			if let n = skipNote { Text(n).font(.system(size: 12)).foregroundStyle(Color(hex: 0x92400e)) }
			let unused = st.tracks.filter { t in !st.mapping.contains(t.id) }
			if !unused.isEmpty {
				Text("Not in this album: " + unused.map { "\($0.disc)-\($0.number) \($0.title)" }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Color.muted).lineLimit(3)
			}
			Divider()
			HStack(spacing: 14) {
				Toggle("Import song titles", isOn: $importTitles).toggleStyle(.checkbox)
				legend
				Spacer()
			}
			if st.duplicates { Text("One release track is given to two files.").font(.system(size: 12)).foregroundStyle(Color.bad) }
			HStack {
				Text("\(st.assigned) of \(album.tracks.count) files assigned").font(.system(size: 12)).foregroundStyle(Color.muted)
				Spacer()
				Button("Cancel") { onCancel() }
				Button(applying ? "Applying…" : "Apply") { onApply() }.buttonStyle(.borderedProminent).tint(applying ? Color.bad : Color.ink).disabled(st.assigned == 0 || st.duplicates || applying)
			}
		}.padding(20)
	}

	var releaseCard: some View {
		HStack(spacing: 12) {
			AsyncImage(url: info.thumb) { $0.resizable().scaledToFill() } placeholder: { Color.board }.frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
			VStack(alignment: .leading, spacing: 3) {
				Text(info.title).font(.system(size: 14, weight: .semibold))
				Text(info.meta.filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Color.muted).lineLimit(2)
			}
			Spacer()
			Pill(text: "\(info.tracks) tracks", fg: info.tracks == album.tracks.count ? Color(hex: 0x1d4ed8) : Color.muted, bg: info.tracks == album.tracks.count ? Color(hex: 0xdbeafe) : Color(hex: 0xe5e7eb))
			if let u = info.url { Button("Open") { NSWorkspace.shared.open(u) }.buttonStyle(.bordered).controlSize(.small) }
		}.padding(10).background(Color.board.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
	}

	var legend: some View {
		HStack(spacing: 10) {
			HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0xdbeafe)).frame(width: 12, height: 12); Text("from the release, will be written") }
			HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0xe5e7eb)).frame(width: 12, height: 12); Text("what the file has, stays") }
		}.font(.system(size: 11)).foregroundStyle(Color.muted)
	}

	var table: some View {
		List {
			let order = st.order
			ForEach(Array(order.enumerated()), id: \.element) { pos, i in
				if i < album.tracks.count {
					if st.mapping[i] != nil, importTitles, groupStarts(order, pos) { divider(order, pos) }
					row(i, album.tracks[i])
				}
			}
		}.listStyle(.plain).frame(minHeight: 200, maxHeight: .infinity)
	}

	func groupStarts(_ order: [Int], _ pos: Int) -> Bool {
		let i = order[pos]
		let cur = st.releaseSub[i] + "|" + st.mineSub[i]
		if cur == "|" { return false }
		guard pos > 0, st.mapping[order[pos - 1]] != nil else { return true }
		return st.releaseSub[order[pos - 1]] + "|" + st.mineSub[order[pos - 1]] != cur
	}

	/// ADR 0081: a band where the subtitle changes, with the release's text, the file's old one and the choice between them.
	func divider(_ order: [Int], _ pos: Int) -> some View {
		let i = order[pos]
		let members = order[pos...].prefix { st.mapping[$0] != nil && st.releaseSub[$0] == st.releaseSub[i] && st.mineSub[$0] == st.mineSub[i] }
		return HStack(spacing: 8) {
			Image(systemName: "text.line.first.and.arrowtriangle.forward").foregroundStyle(Color.info)
			TextField("Disc subtitle", text: Binding(get: { st.subText[i] }, set: { v in for m in members { st.subText[m] = v } })).textFieldStyle(.roundedBorder)
				.background(Color(hex: 0xdbeafe).opacity(0.6)).disabled(st.keepMine[i])
			Picker("", selection: Binding(get: { st.keepMine[i] }, set: { v in for m in members { st.keepMine[m] = v } })) { Text("Release").tag(false); Text("Keep mine").tag(true) }.pickerStyle(.segmented).frame(width: 190).labelsHidden()
			if !st.mineSub[i].isEmpty { Text("Was: \(st.mineSub[i])").font(.system(size: 11)).foregroundStyle(Color.muted) }
			Spacer()
		}.padding(.vertical, 4).listRowSeparator(.hidden)
	}

	func row(_ i: Int, _ t: Track) -> some View {
		let m = st.mapping[i]
		let on = importTitles && m != nil
		return HStack(alignment: .top, spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				if on {
					TextField("", text: Binding(get: { st.title[i] }, set: { st.title[i] = $0 })).textFieldStyle(.plain).font(.system(size: 12)).padding(.horizontal, 6).padding(.vertical, 4).background(Color(hex: 0xdbeafe), in: RoundedRectangle(cornerRadius: 5))
					HStack(spacing: 4) { Text("Was: \(t.title)").font(.system(size: 11)).foregroundStyle(Color.muted).lineLimit(1)
						Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t.title, forType: .string) } label: { LucideIcon(icon: .copy, size: 11) }.buttonStyle(IconButton(color: Color.muted)) }
				} else { Text(t.title).font(.system(size: 12)).foregroundStyle(Color.muted).lineLimit(1) }
				Text("\(t.url.lastPathComponent) · \(Inspector.mmss(t.info.duration))").font(.system(size: 10)).foregroundStyle(Color.muted.opacity(0.8)).lineLimit(1)
			}.frame(maxWidth: .infinity, alignment: .leading)
			Pill(text: t.channelsLabel, fg: Color.ink.opacity(0.7), bg: Color(hex: 0xe5e7eb))
			numField(i, \.disc, 36, on)
			numField(i, \.number, 40, on)
			Picker("", selection: Binding(get: { m ?? -1 }, set: { st.mapping[i] = $0 < 0 ? nil : $0; st.renumber() })) {
				Text("Skip").tag(-1)
				ForEach(st.tracks) { r in Text("\(r.disc)-\(r.number)  \(r.title)").tag(r.id) }
			}.labelsHidden().frame(width: 250)
			badge(i, t)
		}.padding(.vertical, 5)
	}

	func numField(_ i: Int, _ kp: WritableKeyPath<AssignState, [Int]>, _ w: CGFloat, _ on: Bool) -> some View {
		TextField("", value: Binding(get: { st[keyPath: kp][i] }, set: { st[keyPath: kp][i] = $0 }), format: .number.grouping(.never)).textFieldStyle(.plain).multilineTextAlignment(.center)
			.frame(width: w).padding(.vertical, 4).background(on ? Color(hex: 0xdbeafe) : Color(hex: 0xe5e7eb), in: RoundedRectangle(cornerRadius: 5)).disabled(!on)
	}

	@ViewBuilder func badge(_ i: Int, _ t: Track) -> some View {
		if let m = st.mapping[i] {
			let r = st.tracks[m]
			let ok = r.seconds == 0 || abs(Int(t.info.duration.rounded()) - r.seconds) <= 8
			Pill(text: ok ? "match" : "check", fg: ok ? Color(hex: 0x047857) : Color(hex: 0x92400e), bg: ok ? Color(hex: 0xd1fae5) : Color(hex: 0xfef3c7))
		} else { Pill(text: "skip", fg: Color.muted, bg: Color(hex: 0xe5e7eb)) }
	}
}

/// Default dialog height from the number of files: room for the release card, the rows and the footer.
func dialogHeight(_ tracks: Int) -> CGFloat { min(max(580, 330 + CGFloat(tracks) * 58), 1000) }

// MARK: Discogs (ADR 0053)

struct DiscogsSheet: View {
	@EnvironmentObject var app: AppState
	@Environment(\.dismiss) var dismiss
	var album: Album
	@AppStorage("importTitles") private var importTitles = true
	@State private var assigning = false
	@State private var query = ""
	@State private var hits: [DiscogsHit] = []
	@State private var picked: Int?
	@State private var raw: [String: Any]?
	@State private var st = AssignState()
	@State private var busy = false
	@State private var searchTask: Task<Void, Never>?   // a new search replaces the running one
	@State private var loadingRelease = false
	@State private var message: String?
	@State private var sortKey = ""
	@State private var asc = true
	@State private var mb: MBRelease?

	var sorted: [DiscogsHit] {
		if sortKey.isEmpty { return hits }
		return hits.sorted { a, b in
			let (x, y): (Int?, Int?) = sortKey == "year" ? (Int(a.year), Int(b.year)) : (a.tracks, b.tracks)
			guard let x else { return false }; guard let y else { return true }
			return asc ? x < y : x > y
		}
	}

	var info: ReleaseInfo {
		let r = raw ?? [:]
		let labels = r["labels"] as? [[String: Any]] ?? []
		let fmt = (r["formats"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
		return ReleaseInfo(title: "\(Discogs.artistNames(r["artists"] as? [[String: Any]] ?? [])) - \(r["title"] as? String ?? "")",
			meta: [(r["year"] as? Int).map(String.init) ?? "", r["country"] as? String ?? "", fmt, labels.first?["name"] as? String ?? "", labels.first?["catno"] as? String ?? ""],
			url: URL(string: "https://www.discogs.com/release/\(picked ?? 0)"), thumb: URL(string: ((r["images"] as? [[String: Any]])?.first?["uri150"] as? String) ?? ""), tracks: st.tracks.count)
	}

	var skipNote: String? {
		guard let id = picked else { return nil }
		let n = zip(album.tracks, st.mapping).filter { t, m in m == nil && !t.tags.first("DISCOGS_RELEASE_ID").isEmpty && t.tags.first("DISCOGS_RELEASE_ID") != "\(id)" }.count
		return n == 0 ? nil : "\(n) skipped file\(n == 1 ? "" : "s") keep their Discogs release, not \(id)."
	}

	var body: some View {
		SheetFrame(title: "Assign tracks to a release", width: 1000, height: dialogHeight(album.tracks.count)) {
			if assigning, raw != nil {
				AssignPane(album: album, info: info, st: $st, importTitles: $importTitles, skipNote: skipNote, applying: app.job != nil, onBack: { assigning = false }, onApply: apply, onCancel: { dismiss() })
			} else if loadingRelease {
				ProgressView("Loading the release…").frame(maxWidth: .infinity, maxHeight: .infinity)
			} else { searchPane }
		}
		.onAppear {
			guard query.isEmpty else { return }
			query = [album.artist, album.title].filter { !$0.isEmpty }.joined(separator: " ")
			if !album.discogsID.isEmpty, let id = Int(album.discogsID) { picked = id; load(id) }
			Task { if !album.mbid.isEmpty { mb = await MusicBrainz.release(album.mbid) }; search() }
		}
	}

	var searchPane: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				TextField("Search Discogs (a release number loads it)", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
				Button { search() } label: { HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text(busy ? "Search again" : "Search Discogs") }.padding(.horizontal, 6) }.buttonStyle(.borderedProminent).tint(Color.ink).help(busy ? "Stops the running search and starts a new one" : "")
			}
			HStack(spacing: 18) { chip("Artist", album.artist); chip("Album", album.title); chip("Year", album.year); if !album.catalog.isEmpty { chip("Catalog #", album.catalog) } }
				.font(.system(size: 12)).foregroundStyle(Color.muted)
			if let m = message { Text(m).font(.system(size: 12)).foregroundStyle(Color.bad) }
			HStack {
				Text("Release").frame(maxWidth: .infinity, alignment: .leading)
				Button("Year \(arrow("year"))") { sort("year") }.frame(width: 60)
				Text("Cat. no.").frame(width: 120, alignment: .leading)
				Button("Tracks \(arrow("tracks"))") { sort("tracks") }.frame(width: 70)
				Spacer().frame(width: 80)
			}.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).padding(.leading, 62).padding(.trailing, 12)
			List(sorted, selection: $picked) { h in
				HStack(spacing: 10) {
					AsyncImage(url: URL(string: h.thumb)) { $0.resizable().scaledToFill() } placeholder: { Color.board }.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 4))
					VStack(alignment: .leading, spacing: 2) {
						HStack(spacing: 6) { Text(h.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
							if !h.match.isEmpty { Pill(text: "\(h.match) match", fg: Color(hex: 0x047857), bg: Color(hex: 0xd1fae5)) } }
						Text([h.country, h.format, h.label].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Color.muted).lineLimit(1)
					}
					Spacer()
					Text(h.year).frame(width: 60)
					Text(h.catno).font(.system(size: 12, design: .monospaced)).frame(width: 120, alignment: .leading).lineLimit(1)
					Text(h.tracks.map { "\($0) tracks" } ?? "…").foregroundStyle(h.tracks == album.tracks.count ? Color.info : Color.muted).frame(width: 70)
					Button("Select") { picked = h.id; load(h.id) }.buttonStyle(.bordered).controlSize(.small).frame(width: 80)
				}.tag(h.id)
			}.frame(minHeight: 200, maxHeight: .infinity)
			.overlay { if hits.isEmpty && !busy { Text("Search to list releases.").foregroundStyle(Color.muted) } }
			HStack {
				if raw != nil { Button("Back to the assignment") { assigning = true }.buttonStyle(.plain).foregroundStyle(Color.info) }
				Spacer(); Button("Cancel") { dismiss() }
			}
		}.padding(20)
	}

	func arrow(_ k: String) -> String { sortKey == k ? (asc ? "↑" : "↓") : "" }
	func sort(_ k: String) { if sortKey == k { asc.toggle() } else { sortKey = k; asc = true } }

	func chip(_ k: String, _ v: String) -> some View {
		HStack(spacing: 4) { Text("\(k): \(v)")
			Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(v, forType: .string) } label: { LucideIcon(icon: .copy, size: 12) }.buttonStyle(IconButton(color: Color.muted)) }
	}

	func search() {
		searchTask?.cancel()
		busy = true; message = nil
		searchTask = Task {
			defer { if !Task.isCancelled { busy = false } }
			do {
				var found = try await Discogs.search(query: query)
				if Task.isCancelled { return }
				if let mb { for i in found.indices where mb.discogsIDs.contains(found[i].id) { found[i].match = "MusicBrainz" }; found.sort { $0.match > $1.match } }
				hits = found
				if hits.isEmpty { message = "No releases found" }
			} catch { if !Task.isCancelled { message = error.localizedDescription }; return }
			for h in hits where h.tracks == nil {
				if Task.isCancelled { return }
				let n = await Discogs.trackCount(h.id)
				if let i = hits.firstIndex(where: { $0.id == h.id }) { hits[i].tracks = n ?? 0 }
			}
		}
	}

	func load(_ id: Int) {
		loadingRelease = true; message = nil
		Task {
			defer { loadingRelease = false }
			do {
				let r = try await Discogs.release(id)
				var s = AssignState(); s.tracks = Discogs.tracklist(r); s.propose(album: album)
				raw = r; st = s; assigning = true
			} catch { message = error.localizedDescription; raw = nil; assigning = false }
		}
	}

	func apply() {
		guard let r = raw, let id = picked else { return }
		let items = album.tracks.enumerated().compactMap { i, t -> Assign.Item? in
			guard let m = st.mapping[i] else { return nil }
			return Assign.Item(url: t.url, track: st.tracks[m], disc: st.disc[i], number: st.number[i], title: st.title[i].isEmpty ? st.tracks[m].title : st.title[i], subtitle: st.subtitle(i))
		}
		app.assign(album, release: r, id: id, items: items, importTitles: importTitles)
		dismiss()
	}
}

// MARK: MusicBrainz release (ADR 0023, 0078)

struct MusicBrainzSheet: View {
	@EnvironmentObject var app: AppState
	@Environment(\.dismiss) var dismiss
	var album: Album
	@AppStorage("importTitles") private var importTitles = true
	@State private var assigning = false
	@State private var query = ""
	@State private var hits: [MBHit] = []
	@State private var picked: String?
	@State private var detail: MusicBrainz.Detail?
	@State private var st = AssignState()
	@State private var busy = false
	@State private var searchTask: Task<Void, Never>?   // a new search replaces the running one
	@State private var loading = false
	@State private var message: String?
	@State private var sortKey = ""
	@State private var asc = true

	var sorted: [MBHit] {
		if sortKey.isEmpty { return hits }
		return hits.sorted { a, b in
			let (x, y) = sortKey == "year" ? (Int(a.date) ?? 0, Int(b.date) ?? 0) : (a.tracks, b.tracks)
			return asc ? x < y : x > y
		}
	}

	var info: ReleaseInfo {
		let h = hits.first { $0.id == picked }
		return ReleaseInfo(title: h.map { "\($0.artist) - \($0.title)" } ?? detail.map { "\($0.artist) - \($0.title)" } ?? (picked ?? ""),
			meta: [h?.date ?? "", h?.country ?? "", h?.format ?? "", h?.label ?? "", h?.catno ?? "", h?.barcode ?? ""],
			url: URL(string: "https://musicbrainz.org/release/\(picked ?? "")"), thumb: URL(string: "https://coverartarchive.org/release/\(picked ?? "")/front-250"), tracks: st.tracks.count)
	}

	var body: some View {
		SheetFrame(title: "Choose a MusicBrainz release", width: 1000, height: dialogHeight(album.tracks.count)) {
			if assigning, detail != nil {
				AssignPane(album: album, info: info, st: $st, importTitles: $importTitles, skipNote: nil, applying: app.job != nil, onBack: { assigning = false }, onApply: apply, onCancel: { dismiss() })
			} else if loading {
				ProgressView("Loading the release…").frame(maxWidth: .infinity, maxHeight: .infinity)
			} else { searchPane }
		}
		.onAppear {
			guard query.isEmpty else { return }
			query = [album.artist, album.title].filter { !$0.isEmpty }.joined(separator: " ")
			if !album.mbid.isEmpty { picked = album.mbid; load(album.mbid) }
			search()
		}
	}

	var searchPane: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				TextField("Search MusicBrainz (a release ID loads it)", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
				Button { search() } label: { HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text(busy ? "Search again" : "Search MusicBrainz") }.padding(.horizontal, 6) }.buttonStyle(.borderedProminent).tint(Color.ink).help(busy ? "Stops the running search and starts a new one" : "")
			}
			HStack(spacing: 18) { chip("Artist", album.artist); chip("Album", album.title); chip("Year", album.year); if !album.catalog.isEmpty { chip("Catalog #", album.catalog) } }
				.font(.system(size: 12)).foregroundStyle(Color.muted)
			if let m = message { Text(m).font(.system(size: 12)).foregroundStyle(Color.bad) }
			HStack {
				Text("Release").frame(maxWidth: .infinity, alignment: .leading)
				Button("Year \(arrow("year"))") { sort("year") }.frame(width: 60)
				Text("Cat. no.").frame(width: 130, alignment: .leading)
				Button("Tracks \(arrow("tracks"))") { sort("tracks") }.frame(width: 70)
				Spacer().frame(width: 80)
			}.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).padding(.leading, 62).padding(.trailing, 12)
			List(sorted, selection: $picked) { h in
				HStack(spacing: 10) {
					AsyncImage(url: URL(string: "https://coverartarchive.org/release/\(h.id)/front-250")) { $0.resizable().scaledToFill() } placeholder: { Color.board }.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 4))
					VStack(alignment: .leading, spacing: 2) {
						HStack(spacing: 6) { Text("\(h.artist) - \(h.title)").font(.system(size: 13, weight: .medium)).lineLimit(1)
							if !h.match.isEmpty { Pill(text: h.match, fg: Color(hex: 0x047857), bg: Color(hex: 0xd1fae5)) } }
						Text([h.country, h.format, h.label, h.barcode].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Color.muted).lineLimit(1)
					}
					Spacer()
					Text(h.date).frame(width: 60)
					Text(h.catno).font(.system(size: 12, design: .monospaced)).frame(width: 130, alignment: .leading).lineLimit(2)
					Text("\(h.tracks) tracks").foregroundStyle(h.tracks == album.tracks.count ? Color.info : Color.muted).frame(width: 70)
					Button("Select") { picked = h.id; load(h.id) }.buttonStyle(.bordered).controlSize(.small).frame(width: 80)
				}.tag(h.id)
			}.frame(minHeight: 200, maxHeight: .infinity).overlay { if hits.isEmpty && !busy { Text("Search to list releases.").foregroundStyle(Color.muted) } }
			HStack {
				if detail != nil { Button("Back to the assignment") { assigning = true }.buttonStyle(.plain).foregroundStyle(Color.info) }
				Spacer(); Button("Cancel") { dismiss() }
			}
		}.padding(20)
	}

	func arrow(_ k: String) -> String { sortKey == k ? (asc ? "↑" : "↓") : "" }
	func sort(_ k: String) { if sortKey == k { asc.toggle() } else { sortKey = k; asc = true } }
	func chip(_ k: String, _ v: String) -> some View {
		HStack(spacing: 4) { Text("\(k): \(v)")
			Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(v, forType: .string) } label: { LucideIcon(icon: .copy, size: 12) }.buttonStyle(IconButton(color: Color.muted)) }
	}

	func search() {
		busy = true; message = nil
		let barcode = album.tracks.first?.tags.first("BARCODE", "UPC") ?? ""
		searchTask?.cancel()
		searchTask = Task {
			defer { if !Task.isCancelled { busy = false } }
			do {
				let found = try await MusicBrainz.search(query: query, discogsID: album.discogsID, barcode: barcode, catno: album.catalog)
				if Task.isCancelled { return }
				hits = found
				if hits.isEmpty { message = "No releases found" }
			} catch { if !Task.isCancelled { message = error.localizedDescription } }
		}
	}

	func load(_ id: String) {
		loading = true; message = nil
		Task {
			defer { loading = false }
			do {
				let d = try await MusicBrainz.detail(id)
				var s = AssignState(); s.tracks = d.tracks; s.propose(album: album)
				detail = d; st = s; assigning = true
			} catch { message = error.localizedDescription; detail = nil; assigning = false }
		}
	}

	func apply() {
		guard let d = detail else { return }
		let items = album.tracks.enumerated().compactMap { i, t -> (Assign.Item, [String])? in
			guard let m = st.mapping[i] else { return nil }
			return (Assign.Item(url: t.url, track: st.tracks[m], disc: st.disc[i], number: st.number[i], title: st.title[i].isEmpty ? st.tracks[m].title : st.title[i], subtitle: st.subtitle(i)), d.trackArtistIDs[m])
		}
		app.assignMusicBrainz(album, detail: d, items: items, importTitles: importTitles)
		dismiss()
	}
}

// MARK: lyrics editor (ADR 0021)

struct LyricsSheet: View {
	@EnvironmentObject var app: AppState
	@Environment(\.dismiss) var dismiss
	var album: Album
	var track: Track
	@State private var title = ""
	@State private var artist = ""
	@State private var text = ""
	@State private var message: String?
	@State private var busy = false
	@State private var searchTask: Task<Void, Never>?   // a new search replaces the running one
	@State private var loaded = false

	var body: some View {
		SheetFrame(title: "Edit lyrics  \(track.url.lastPathComponent)  \(Inspector.mmss(track.info.duration))", width: 820, height: 760) {
			VStack(alignment: .leading, spacing: 10) {
				HStack {
					TextField("Title", text: $title).textFieldStyle(.roundedBorder)
					TextField("Artist", text: $artist).textFieldStyle(.roundedBorder)
					Button { search() } label: { HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text(busy ? "Search again" : "Search lrclib.net") } }.buttonStyle(.borderedProminent).tint(Color.ink)
				}
				HStack {
					Text("Lyrics").font(.system(size: 13, weight: .medium))
					Pill(text: kind, fg: .white, bg: kindColor)
					Text("\(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines").font(.system(size: 12)).foregroundStyle(Color.muted)
					Spacer()
					Button("Normalise") { tidy() }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
					Button("Instrumental") { text = Lrc.instrumental(artist: track.tags.first("ALBUMARTIST", "ARTIST"), title: track.title, album: album.title, length: track.info.duration) }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
				}
				TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).frame(minHeight: 200, maxHeight: .infinity)
					.overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12)))
				Text("Title and artist are only used for the search and are not saved (change them in the Tag Editor).").font(.system(size: 11)).foregroundStyle(Color.muted)
				if !suspect.isEmpty { Text("Suspect timestamps: \(suspect)").font(.system(size: 12)).foregroundStyle(Color.warn) }
				if let m = message { Text(m).font(.system(size: 12)).foregroundStyle(Color.bad) }
				HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent).tint(Color.ink).keyboardShortcut(.defaultAction) }
			}.padding(20)
		}
		.onAppear {
			guard !loaded else { return }
			loaded = true
			title = track.title; artist = track.tags.first("ARTIST", "ALBUMARTIST"); text = track.tags.first("LYRICS", "UNSYNCEDLYRICS")
		}
	}

	var probe: Track { var t = track; t.tags["LYRICS"] = text.isEmpty ? nil : [text]; return t }
	var kind: String { switch probe.lyricsKind { case .lrc: "LRC"; case .txt: "TXT"; case .instr: "INS"; case .none: "---" } }
	var kindColor: Color { switch probe.lyricsKind { case .lrc: .ok; case .txt: .warn; case .instr: .info; case .none: .bad } }

	func search() {
		searchTask?.cancel()
		busy = true; message = nil
		searchTask = Task {
			defer { if !Task.isCancelled { busy = false } }
			var tags = track.tags
			tags["TITLE"] = [title]; tags["ARTIST"] = [artist]; tags["ALBUMARTIST"] = [track.tags.first("ALBUMARTIST", "ARTIST")]
			tags["LYRICS"] = nil
			let r = await Lrc.decide(tags: tags, length: track.info.duration, log: { _ in }, lookup: Lrc.lrclib)
			if Task.isCancelled { return }
			switch r.action {
			case "failed": message = "lrclib.net did not answer; try again"
			case "new", "fix": text = r.lyrics
			default: message = "Not found on lrclib.net"
			}
		}
	}

	var suspect: String {
		let r = Lrc.suspectReasons(text, length: track.info.duration), n = Lrc.problemLineCount(text)
		return (r.map { ["one_timestamp": "every line has the same timestamp", "shared_timestamps": "many lines share one timestamp", "ends_early": "ends long before the track does", "junk_hearts": "hearts in lyric lines"][$0] ?? $0 } + (n > 0 ? ["\(n) problem lines"] : [])).joined(separator: "; ")
	}

	func tidy() {
		let a = track.tags.first("ALBUMARTIST", "ARTIST")
		text = Lrc.isLrc(text)
			? Lrc.capitalizeLrc(Lrc.normalizeLrc(Lrc.applyHeaders(text, artist: a, title: track.title, album: album.title, length: track.info.duration)))
			: Lrc.capitalizeTxt(Lrc.normalizeText(text))
	}

	func save() {
		let t = text
		app.writeTags(album, files: [track.url]) { _, tags in
			tags["UNSYNCEDLYRICS"] = nil
			tags["LYRICS"] = t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : [t]
		}
		dismiss()
	}
}

// MARK: tag editor (ADR 0014, 0057, 0080)

struct TagEditorSheet: View {
	@EnvironmentObject var app: AppState
	@Environment(\.dismiss) var dismiss
	var album: Album
	var startTab = 0

	init(album: Album, startTab: Int = 0) { self.album = album; self.startTab = startTab; _tab = State(initialValue: startTab) }

	static let overrides: [(key: String, label: String, target: String, hint: String)] = [
		("ALBUM_ARTIST_OVERRIDE", "Album Artist Override", "ALBUMARTIST", ""),
		("ALBUM_TITLE_OVERRIDE", "Album Title Override", "ALBUM", ""),
		("ALBUM_FORMAT_OVERRIDE", "Album Format Override", "ALBUM_FORMAT", "For example CD, SACD, Vinyl. Saved as ALBUM_FORMAT_OVERRIDE and kept when a Discogs release is assigned. Empty restores the Discogs format."),
		("ALBUM_EDITION", "Album Edition", "ALBUM_EDITION", "For example Remastered or Gold Disc. Part of the version string."),
		("CATALOGNUMBER_OVERRIDE", "Catalog # Override", "CATALOGNUMBER", "Part of the version string. Saved as CATALOGNUMBER_OVERRIDE and kept when a Discogs release is assigned. Empty restores the Discogs number."),
	]

	@State private var tab: Int
	@State private var fields: [String: String] = [:]
	@State private var order: [String] = []
	@State private var rows: [String: [String: String]] = [:]
	@State private var message: String?
	@State private var loaded = false
	@State private var lyricsFor: Track?

	var body: some View {
		SheetFrame(title: "Tag editor", width: 980, height: dialogHeight(album.tracks.count) + 40) {
			VStack(spacing: 0) {
				Picker("", selection: $tab) { Text("Album").tag(0); Text("Tracks").tag(1); Text("Discogs").tag(2); Text("MusicBrainz").tag(3); Text("Other").tag(4) }
					.pickerStyle(.segmented).labelsHidden().padding(14)
				Group {
					switch tab {
					case 0: albumTab
					case 1: tracksTab
					case 2: readOnly(keys: { Self.isDiscogs($0) }, empty: "No Discogs tags yet.")
					case 3: readOnly(keys: { $0.hasPrefix("MUSICBRAINZ") || ["BARCODE", "ASIN"].contains($0) }, empty: "No MusicBrainz tags yet.")
					default: readOnly(keys: { Self.isOther($0) }, empty: "Nothing else.")
					}
				}.frame(minHeight: 300, maxHeight: .infinity)
				Divider()
				HStack {
					if let m = message { Text(m).font(.system(size: 12)).foregroundStyle(Color.bad) }
					Spacer()
					Button("Cancel") { dismiss() }
					Button("Save") { save() }.buttonStyle(.borderedProminent).tint(Color.ink).keyboardShortcut(.defaultAction)
				}.padding(14)
			}
		}
		.onAppear { if !loaded { load(); loaded = true } }
		.sheet(item: $lyricsFor) { t in LyricsSheet(album: album, track: t) }
	}

	static func isDiscogs(_ k: String) -> Bool {
		["DISCOGS_", "ALBUM_RELEASE_", "ALBUM_COMPANY_", "ALBUM_CREDIT_", "ALBUM_IDENT_", "ALBUM_MASTER_", "ORIGINAL"].contains { k.hasPrefix($0) } || ["VERSION", "ALBUM_FORMAT", "ALBUM_MAX_RESOLUTION", "ALBUM_DR", "ALBUM_FORMAT", "COUNTRY", "MEDIA", "CATALOG", "COPYRIGHT", "PUBLISHER", "PERSONNEL", "RELEASEDATE", "DATE", "YEAR"].contains(k)
	}
	static let hidden: Set<String> = ["TITLE", "ARTIST", "TRACKNUMBER", "DISCNUMBER", "LYRICS", "UNSYNCEDLYRICS", "ALBUMARTIST_UNUSED", "ALBUM_EDITION", "ALBUM_ARTIST_OVERRIDE", "ALBUM_TITLE_OVERRIDE", "ALBUM_FORMAT_OVERRIDE", "CATALOGNUMBER_OVERRIDE", "CATALOGNUMBER", "ALBUM"]
	static func isOther(_ k: String) -> Bool { !isDiscogs(k) && !k.hasPrefix("MUSICBRAINZ") && !["BARCODE", "ASIN"].contains(k) && !hidden.contains(k) }

	func load() {
		for o in Self.overrides { fields[o.key] = album.tracks.first?.tags[o.key]?.first ?? "" }
		order = album.tracks.map(\.id)
		for t in album.tracks { rows[t.id] = ["DISCNUMBER": t.tags.first("DISCNUMBER"), "TRACKNUMBER": t.tags.first("TRACKNUMBER"), "TITLE": t.tags.first("TITLE"), "ARTIST": t.tags.first("ARTIST")] }
	}

	// MARK: Album tab

	var albumTab: some View {
		let first = album.tracks.first?.tags ?? [:]
		return ScrollView {
			Grid(alignment: .topLeading, horizontalSpacing: 22, verticalSpacing: 14) {
				GridRow { field(0, small: !album.discogsID.isEmpty ? "ALBUM ARTIST: \(first.first("ALBUMARTIST"))" : nil); field(1, small: !album.discogsID.isEmpty ? "ALBUM TITLE: \(first.first("ALBUM_MASTER_TITLE", "ALBUM_RELEASE_TITLE"))" : nil) }
				GridRow { field(2); field(3) }
				GridRow { field(4); VStack(alignment: .leading, spacing: 4) { Text("Year Release").font(.system(size: 13, weight: .medium)); roText(first.first("ALBUM_RELEASE_YEAR")); Text("From Discogs, read-only.").font(.system(size: 11)).foregroundStyle(Color.muted) }
				}
				GridRow {
					VStack(alignment: .leading, spacing: 4) { Text("Year Master Release").font(.system(size: 13, weight: .medium)); roText(first.first("ALBUM_MASTER_YEAR")); Text("From Discogs, read-only.").font(.system(size: 11)).foregroundStyle(Color.muted) }
					Color.clear.frame(height: 1)
				}
				GridRow {
					idRow("Discogs Release ID", album.discogsID) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { app.sheet = .discogs } }
					idRow("Musicbrainz Release ID", album.mbid) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { app.sheet = .musicbrainz } }
				}
			}.padding(20)
		}
	}

	func roText(_ s: String) -> some View { Text(s).font(.system(size: 13)).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.board, in: RoundedRectangle(cornerRadius: 6)) }

	func field(_ i: Int, small: String? = nil) -> some View {
		let o = Self.overrides[i]
		return VStack(alignment: .leading, spacing: 4) {
			Text(o.label).font(.system(size: 13, weight: .medium))
			TextField("", text: Binding(get: { fields[o.key] ?? "" }, set: { fields[o.key] = $0 })).textFieldStyle(.roundedBorder)
			if let small, !small.hasSuffix(": ") { Text(small).font(.system(size: 11)).foregroundStyle(Color.muted) }
			else if !o.hint.isEmpty { Text(o.hint).font(.system(size: 11)).foregroundStyle(Color.muted) }
		}.frame(maxWidth: .infinity, alignment: .topLeading)
	}

	func idRow(_ label: String, _ id: String, pen: @escaping () -> Void) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(label).font(.system(size: 13, weight: .medium))
			HStack(spacing: 8) {
				Text(id.isEmpty ? "missing" : id).font(.system(size: 12, weight: .medium, design: id.isEmpty ? .default : .monospaced)).foregroundStyle(id.isEmpty ? Color(hex: 0xbe123c) : Color.ink)
					.padding(.horizontal, 10).padding(.vertical, 4).background(id.isEmpty ? Color(hex: 0xffe4e6) : Color.board, in: Capsule())
				Button(action: pen) { LucideIcon(icon: .pencil, size: 14) }.buttonStyle(IconButton(hover: Color.board)).help("Search")
			}
		}.frame(maxWidth: .infinity, alignment: .topLeading)
	}

	// MARK: Tracks tab

	var tracksTab: some View {
		List {
			HStack(spacing: 8) {
				Text("Disc").frame(width: 44, alignment: .leading); Text("Track").frame(width: 44, alignment: .leading); Text("Title").frame(maxWidth: .infinity, alignment: .leading); Text("Artist").frame(maxWidth: .infinity, alignment: .leading)
				Text("Time").frame(width: 42); Text("Rate/bits").frame(width: 70); Text("Channels").frame(width: 62); Text("Lyrics").frame(width: 44); Spacer().frame(width: 24)
			}.font(.system(size: 11)).foregroundStyle(Color.muted)
			ForEach(order, id: \.self) { id in
				if let t = album.tracks.first(where: { $0.id == id }) {
					HStack(spacing: 8) {
						cell(id, "DISCNUMBER").frame(width: 44); cell(id, "TRACKNUMBER").frame(width: 44)
						cell(id, "TITLE"); cell(id, "ARTIST")
						Text(Inspector.mmss(t.info.duration)).font(.system(size: 12)).foregroundStyle(Color.muted).frame(width: 42)
						Pill(text: t.formatLabel, bg: .white).frame(width: 70)
						Pill(text: t.channelsLabel, fg: Color.ink.opacity(0.7), bg: Color(hex: 0xe5e7eb)).frame(width: 62)
						Group { switch t.lyricsKind { case .lrc: Pill(text: "LRC", fg: .white, bg: .ok); case .txt: Pill(text: "TXT", fg: .black, bg: .warn); case .instr: Pill(text: "INS", fg: .white, bg: .info); case .none: Pill(text: "---", fg: .white, bg: .bad) } }.frame(width: 44)
						Button { lyricsFor = t } label: { LucideIcon(icon: .pencil, size: 14) }.buttonStyle(IconButton(hover: Color.board)).help("Edit lyrics")
					}
				}
			}.onMove { from, to in order.move(fromOffsets: from, toOffset: to); renumber() }
		}
	}

	/// A drag renumbers the tracks of each disc in the new order (ADR 0014).
	func renumber() {
		var n: [String: Int] = [:]
		for id in order { let d = rows[id]?["DISCNUMBER"] ?? "1"; n[d, default: 0] += 1; rows[id]?["TRACKNUMBER"] = "\(n[d]!)" }
	}

	func cell(_ id: String, _ key: String) -> some View {
		TextField("", text: Binding(get: { rows[id]?[key] ?? "" }, set: { rows[id, default: [:]][key] = $0 })).textFieldStyle(.roundedBorder)
	}

	// MARK: read-only tabs (ADR 0057)

	func readOnly(keys: (String) -> Bool, empty: String) -> some View {
		let all = album.tracks.map(\.tags)
		let ks = Set(all.flatMap(\.keys)).filter(keys).sorted()
		return Group {
			if ks.isEmpty { Text(empty).foregroundStyle(Color.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
			else {
				List(ks, id: \.self) { k in
					let vals = all.map { $0[k]?.joined(separator: "; ") ?? "" }
					let have = vals.filter { !$0.isEmpty }
					HStack(alignment: .top) {
						Text(k).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.muted).frame(width: 260, alignment: .leading)
						Text(String((have.first ?? "").prefix(300))).font(.system(size: 12)).lineLimit(2).help(have.first ?? "")
						Spacer()
						if have.count < all.count { Pill(text: "\(have.count) of \(all.count) files", fg: Color.muted, bg: Color(hex: 0xe5e7eb)) }
						if Set(have).count > 1 { Pill(text: "differs", fg: Color(hex: 0x92400e), bg: Color(hex: 0xfef3c7)) }
					}
				}
			}
		}
	}

	// MARK: save

	func save() {
		let f = fields
		for t in album.tracks.prefix(1) {
			for o in Self.overrides where (f[o.key] ?? "").isEmpty && ["ALBUM_FORMAT_OVERRIDE", "CATALOGNUMBER_OVERRIDE"].contains(o.key) == false && false { _ = t }
		}
		let had = Dictionary(uniqueKeysWithValues: Self.overrides.map { ($0.key, !(album.tracks.first?.tags[$0.key]?.first ?? "").isEmpty) })
		let cleared = Self.overrides.filter { had[$0.key] == true && (f[$0.key] ?? "").isEmpty && $0.key != "ALBUM_EDITION" }.map(\.key)
		let r = rows, dr = album.albumDR
		let versionInputs = [f["ALBUM_FORMAT_OVERRIDE"] ?? "", f["ALBUM_EDITION"] ?? "", f["CATALOGNUMBER_OVERRIDE"] ?? ""]
		let touchedVersion = versionInputs != [album.tracks.first?.tags["ALBUM_FORMAT_OVERRIDE"]?.first ?? "", album.edition, album.tracks.first?.tags["CATALOGNUMBER_OVERRIDE"]?.first ?? ""]
		for k in ["TITLE", "TRACKNUMBER", "DISCNUMBER"] where r.values.contains(where: { ($0[k] ?? "").isEmpty }) { message = "\(k) must not be empty"; return }
		app.writeTags(album) { url, t in
			for o in Self.overrides {
				let v = (f[o.key] ?? "").trimmingCharacters(in: .whitespaces)
				if o.key == "ALBUM_EDITION" { t[o.key] = v.isEmpty ? nil : [v]; continue }
				if v.isEmpty { t[o.key] = nil; continue }
				t[o.key] = [v]; t[o.target] = [v]
				if o.target == "CATALOGNUMBER" { for alt in ["CATALOG NUMBER", "CATALOG_NUMBER", "CATALOGNO"] { t[alt] = nil } }
			}
			if let row = r[url.path] { for (k, v) in row { t[k] = v.isEmpty ? nil : [v] } }
			if touchedVersion, !t.first("DISCOGS_RELEASE_ID").isEmpty {
				t["VERSION"] = [Naming.versionString(year: t.first("ALBUM_RELEASE_YEAR", "DATE"), dr: dr, format: t.first("ALBUM_FORMAT"), edition: t.first("ALBUM_EDITION"), catalog: t.first("CATALOGNUMBER", "CATALOG NUMBER"))]
			}
		}
		if !cleared.isEmpty { app.restoreFromDiscogs(album) }
		dismiss()
	}
}

// MARK: leftover staging folder (ADR 0072)

struct LeftoverSheet: View {
	@EnvironmentObject var app: AppState
	@Environment(\.dismiss) var dismiss
	var left: AppState.Leftover
	var body: some View {
		let subdirs = left.items.filter(\.dir).count
		SheetFrame(title: "Delete the folder?", width: 560) {
			VStack(alignment: .leading, spacing: 10) {
				Text(left.folder.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
				if left.items.isEmpty { Text("The folder holds nothing.").foregroundStyle(Color.muted) }
				else {
					Text("It still holds \(left.items.count) item\(left.items.count == 1 ? "" : "s")\(subdirs > 0 ? ", \(subdirs) of them folders that are deleted with their contents" : ""):").font(.system(size: 13))
					ScrollView { VStack(alignment: .leading, spacing: 3) {
						ForEach(Array(left.items.enumerated()), id: \.offset) { _, i in
							HStack { Image(systemName: i.dir ? "folder" : "doc"); Text(i.name); Spacer(); Text(ByteCountFormatter.string(fromByteCount: i.size, countStyle: .file)).foregroundStyle(Color.muted) }.font(.system(size: 12))
						}
					} }.frame(height: 160).padding(8).background(Color.board, in: RoundedRectangle(cornerRadius: 8))
				}
				HStack { Spacer(); Button("Keep") { dismiss() }
					Button("Delete") { try? FileManager.default.removeItem(at: left.folder); app.notify("Folder deleted"); dismiss() }.buttonStyle(.borderedProminent).tint(Color.bad) }
			}.padding(20)
		}
	}
}
