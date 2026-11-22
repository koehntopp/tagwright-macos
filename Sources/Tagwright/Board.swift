import SwiftUI

/// One album card (page.tsx): cover with the status pill and the playing badge, title and artist with copy
/// buttons, the edition line, ID badges, DR and lyrics badges, missing pills and the progress bar.
struct CardView: View {
	@EnvironmentObject var app: AppState
	var album: Album
	var selected: Bool
	@State private var over = false

	var body: some View {
		let s = album.status
		VStack(alignment: .leading, spacing: 0) {
			Color.clear.aspectRatio(1, contentMode: .fit)
				.overlay { CoverFill(album: album) }
				.clipped()
				.overlay(alignment: .topLeading) { Pill(text: album.pillText, fg: .white, bg: s.strong).shadow(color: .black.opacity(0.15), radius: 2, y: 1).padding(12) }
				.overlay(alignment: .topTrailing) {
					if let p = app.playing, album.tracks.contains(where: { $0.id == p }) {
						EqBars().padding(.horizontal, 10).frame(height: 20).background(Color.yellow(400), in: Capsule()).shadow(color: .black.opacity(0.15), radius: 2, y: 1).padding(12).help("Playing")
					}
				}
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 4) { Text(album.title).font(.system(size: 14, weight: .semibold)).lineLimit(1); CopyButton(text: album.title) }
				HStack(spacing: 4) {
					Text((album.artist.isEmpty ? "No artist" : album.artist) + (album.dateYear.isEmpty ? "" : " · " + album.dateYear)).font(.system(size: 13)).foregroundStyle(Color.slate(600)).lineLimit(1)
					if !album.artist.isEmpty { CopyButton(text: album.artist) }
				}
				Text(album.editionLine.isEmpty ? " " : album.editionLine).font(.system(size: 12)).foregroundStyle(Color.slate(500)).lineLimit(1)
				HStack(spacing: 6) {
					if !album.discogsID.isEmpty { IdBadge(service: .discogs, id: album.discogsID) }
					if !album.mbid.isEmpty { IdBadge(service: .musicbrainz, id: album.mbid) }
				}.frame(minHeight: 20).padding(.top, 4)
				HStack(spacing: 6) {
					if !album.albumDR.isEmpty { Pill(text: "DR\(album.albumDR)", fg: .emerald(800), bg: Color.white.opacity(0.7)) }
					if album.lrc > 0 { Pill(text: "LRC \(album.lrc)", fg: .white, bg: .emerald(500)) }
					if album.txt > 0 { Pill(text: "TXT \(album.txt)", fg: .amber(950), bg: .amber(400)) }
				}.frame(minHeight: 20)
				if !album.missing.isEmpty {
					FlowRow {
						ForEach(album.missing) { m in
							let opt = m.step.optional
							Pill(text: "\(m.label) \(m.count)", fg: opt ? .sky(700) : .rose(700), bg: opt ? .sky(100) : .rose(100))
								.overlay(Capsule().stroke(opt ? Color.sky(200) : .rose(200)))
								.help("\(m.count) of \(m.of) tracks: \(m.tracks.prefix(5).joined(separator: ", "))\(m.tracks.count > 5 ? ", …" : "")")
						}
					}
				}
				HStack(spacing: 8) {
					GeometryReader { g in
						ZStack(alignment: .leading) {
							Capsule().fill(Color.white.opacity(0.7))
							Capsule().fill(Color.slate(900)).frame(width: g.size.width * CGFloat(album.doneCount) / 6)
						}
					}.frame(height: 6)
					Text("\(album.doneCount)/6").font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.slate(500))
				}.padding(.top, 8)
			}
			.padding(16)
		}
		.frame(maxWidth: .infinity, alignment: .topLeading)
		.background(s.tint)
		.clipShape(RoundedRectangle(cornerRadius: 16))
		.overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.slate(800) : s.border, lineWidth: selected ? 2 : 1))
		.shadow(color: .black.opacity(over ? 0.1 : 0), radius: 6, y: 4)
		.offset(y: over ? -2 : 0)
		.animation(.easeOut(duration: 0.15), value: over)
		.contentShape(RoundedRectangle(cornerRadius: 16))
		.onHover { over = $0 }
		.onTapGesture { app.selection = album.id }
		.onDrop(of: ["public.file-url", "public.image"], isTargeted: nil) { app.dropCover(album, providers: $0) }
	}
}

/// Wrapping row of small items.
struct FlowRow<Content: View>: View {
	@ViewBuilder var content: Content
	var body: some View { WrapLayout(spacing: 6) { content } }
}

struct WrapLayout: Layout {
	var spacing: CGFloat = 5
	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let w = proposal.width ?? 300
		var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
		for v in subviews {
			let s = v.sizeThatFits(.unspecified)
			if x + s.width > w, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
			x += s.width + spacing; rowH = max(rowH, s.height)
		}
		return CGSize(width: w, height: y + rowH)
	}
	func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		var x = b.minX, y = b.minY, rowH: CGFloat = 0
		for v in subviews {
			let s = v.sizeThatFits(.unspecified)
			if x + s.width > b.maxX, x > b.minX { x = b.minX; y += rowH + spacing; rowH = 0 }
			v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
			x += s.width + spacing; rowH = max(rowH, s.height)
		}
	}
}

struct Board: View {
	@EnvironmentObject var app: AppState
	var body: some View {
		Group {
			if app.root == nil {
				VStack(spacing: 12) {
					Text("No \(app.source == .staging ? "staging" : "library") folder chosen.").foregroundStyle(Color.slate(500))
					Button("Open Settings") { app.sheet = .settings }.buttonStyle(WebButton(kind: .primary))
				}.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if !app.shown.isEmpty {
				if app.listView { AlbumTable() } else {
					ScrollView {
						LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 20, alignment: .top)], alignment: .leading, spacing: 20) {
							ForEach(app.shown) { a in CardView(album: a, selected: a.id == app.selection) }
						}
						.padding(32)
					}
				}
			} else if app.scanning {
				Skeleton()
			} else {
				let q = app.search.trimmingCharacters(in: .whitespaces)
				Text(q.isEmpty ? "No albums match." : "No albums match “\(q)”.").foregroundStyle(Color.slate(500)).padding(.vertical, 64).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color.board)
	}
}

/// "Scanning albums…" with six placeholder cards (page.tsx).
struct Skeleton: View {
	@State private var dim = false
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				HStack(spacing: 8) { Spinner(size: 16); Text("Scanning albums…") }.foregroundStyle(Color.slate(500))
				LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 20, alignment: .top)], spacing: 20) {
					ForEach(0..<6, id: \.self) { _ in
						VStack(alignment: .leading, spacing: 8) {
							Rectangle().fill(Color.slate(200).opacity(0.8)).aspectRatio(1, contentMode: .fit)
							VStack(alignment: .leading, spacing: 8) {
								RoundedRectangle(cornerRadius: 4).fill(Color.slate(200).opacity(0.8)).frame(height: 16).frame(maxWidth: .infinity).padding(.trailing, 60)
								RoundedRectangle(cornerRadius: 4).fill(Color.slate(200).opacity(0.8)).frame(width: 120, height: 12)
								RoundedRectangle(cornerRadius: 4).fill(Color.slate(200).opacity(0.8)).frame(width: 160, height: 12)
							}.padding(12)
						}
						.background(Color.white.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 16))
						.overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.slate(200)))
					}
				}.opacity(dim ? 0.5 : 1).animation(.easeInOut(duration: 1).repeatForever(), value: dim).onAppear { dim = true }
			}.padding(32)
		}
	}
}

/// List view columns (album-list.tsx): empty values sort last both ways; DR and years numerically.
enum AlbumColumn: String, CaseIterable {
	case artist, name, media, edition, catalog, dr, release, master
	var label: String { ["Album artist", "Release name", "Media", "Edition", "Catalog #", "DR", "Release", "Master"][Self.allCases.firstIndex(of: self)!] }
	var hint: String { ["Album artist", "Release name", "Media", "Edition", "Catalog number", "Dynamic range", "Release year", "Master year"][Self.allCases.firstIndex(of: self)!] }
	var width: CGFloat { [220, 280, 80, 160, 120, 70, 90, 90][Self.allCases.firstIndex(of: self)!] }
	var numeric: Bool { [.dr, .release, .master].contains(self) }
	func value(_ a: Album) -> String {
		switch self {
		case .artist: a.artist
		case .name: a.title
		case .media: a.format
		case .edition: a.edition
		case .catalog: a.catalog
		case .dr: a.albumDR
		case .release: a.year
		case .master: a.masterYear
		}
	}
	static func less(_ key: String, _ asc: Bool, _ a: Album, _ b: Album) -> Bool {
		guard let c = AlbumColumn(rawValue: key) else { return false }
		let x = c.value(a), y = c.value(b)
		if x.isEmpty != y.isEmpty { return !x.isEmpty }   // empty last, either direction
		if x.isEmpty { return false }
		let r: ComparisonResult = c.numeric ? ((Double(x) ?? 0) < (Double(y) ?? 0) ? .orderedAscending : (Double(x) ?? 0) > (Double(y) ?? 0) ? .orderedDescending : .orderedSame) : x.localizedCompare(y)
		return asc ? r == .orderedAscending : r == .orderedDescending
	}
}

/// ADR 0085-0087: full-bleed table, sticky header, alternating rows, sortable and resizable columns (widths kept).
struct AlbumTable: View {
	@EnvironmentObject var app: AppState
	@AppStorage("tableWidths") private var stored = ""
	@State private var widths: [AlbumColumn: CGFloat] = [:]
	@State private var dragStart: CGFloat?
	@State private var hover: String?

	func w(_ c: AlbumColumn) -> CGFloat { widths[c] ?? c.width }

	var total: CGFloat { AlbumColumn.allCases.reduce(0) { $0 + w($1) } }

	var body: some View {
		GeometryReader { g in
			let width = max(total, g.size.width)   // full-bleed: the last column takes the rest (table w-full)
			ScrollView([.vertical, .horizontal]) {
				LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
					Section {
						ForEach(Array(app.shown.enumerated()), id: \.element.id) { i, a in row(a, i, extra: width - total) }
					} header: {
						VStack(spacing: 0) { Color.board.frame(height: 24); header(extra: width - total) }
					}
				}
				.frame(minWidth: g.size.width, minHeight: g.size.height, alignment: .topLeading)
			}
		}
		.onAppear { load() }
	}

	func header(extra: CGFloat) -> some View {
		HStack(spacing: 0) {
			ForEach(AlbumColumn.allCases, id: \.self) { c in
				let on = app.tableSort?.key == c.rawValue
				Button {
					app.tableSort = (c.rawValue, on ? !(app.tableSort!.asc) : true)
				} label: {
					HStack(spacing: 4) {
						Text(c.label).lineLimit(1)
						if on { Text(app.tableSort!.asc ? "▲" : "▼").foregroundStyle(Color.slate(600)) }
					}.font(.system(size: 12, weight: .medium)).foregroundStyle(Color.slate(900))
					.padding(.horizontal, 12).frame(width: w(c) + (c == .master ? extra : 0), height: 26, alignment: .leading).contentShape(Rectangle())
				}
				.buttonStyle(.plain).help("Sort by \(c.hint)")
				.overlay(alignment: .leading) { if c != .artist { Rectangle().fill(Color.slate(400)).frame(width: 1) } }
				.overlay(alignment: .trailing) {
					Color.clear.frame(width: 8).contentShape(Rectangle())
						.onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
						.gesture(DragGesture(minimumDistance: 1).onChanged { g in
							if dragStart == nil { dragStart = w(c) }
							widths[c] = max(64, dragStart! + g.translation.width)
						}.onEnded { _ in dragStart = nil; save() })
						.help("Drag to resize \(c.hint)").offset(x: 4)
				}
			}
		}
		.background(Color.slate(300)).overlay(alignment: .bottom) { Rectangle().fill(Color.slate(400)).frame(height: 1) }
	}

	func row(_ a: Album, _ i: Int, extra: CGFloat) -> some View {
		let sel = a.id == app.selection
		return HStack(spacing: 0) {
			ForEach(AlbumColumn.allCases, id: \.self) { c in
				Group {
					switch c {
					case .artist:
						HStack(spacing: 8) {
							Circle().fill(a.status.strong).frame(width: 8, height: 8).overlay(Circle().stroke(.white)).help(a.status.label)
							Text(a.artist.isEmpty ? "No artist" : a.artist).lineLimit(1)
						}
					case .name: Text(a.title).fontWeight(.medium).lineLimit(1)
					case .dr:
						let n = Int(a.albumDR)
						Text(n.map { String(format: "%02d", $0) } ?? "").fontWeight(.semibold).monospacedDigit().foregroundStyle((n ?? 0) >= 12 ? Color.emerald(700) : .amber(700)).frame(maxWidth: .infinity, alignment: .trailing)
					case .release, .master: Text(c.value(a)).monospacedDigit()
					default: Text(c.value(a)).lineLimit(1)
					}
				}
				.font(.system(size: 13)).padding(.horizontal, 12).frame(width: w(c) + (c == .master ? extra : 0), height: 26, alignment: .leading)
				.help(c == .release ? "Release year" : c == .master ? "Master year" : c == .name ? a.title : c.value(a))
				.overlay(alignment: .leading) { if c != .artist { Rectangle().fill(Color.slate(300)).frame(width: 1) } }
			}
		}
		.background(sel ? Color.slate(300) : hover == a.id ? Color.slate(300).opacity(0.7) : i % 2 == 1 ? Color.slate(50) : Color.slate(200))
		.onHover { h in hover = h ? a.id : (hover == a.id ? nil : hover) }
		.overlay(alignment: .bottom) { Rectangle().fill(Color.slate(300)).frame(height: 1) }
		.contentShape(Rectangle())
		.onTapGesture { app.selection = a.id }
	}

	func load() {
		guard let d = stored.data(using: .utf8), let m = try? JSONDecoder().decode([String: CGFloat].self, from: d) else { return }
		for (k, v) in m { if let c = AlbumColumn(rawValue: k), v >= 64 { widths[c] = v } }
	}
	func save() {
		let m = Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue, $0.value) })
		if let d = try? JSONEncoder().encode(m) { stored = String(decoding: d, as: UTF8.self) }
	}
}

struct CoverFill: View {
	@EnvironmentObject var app: AppState
	var album: Album
	var body: some View {
		if let img = app.thumbnail(album, size: 640) {
			Image(nsImage: img).resizable().scaledToFill()
		} else {
			CoverPlaceholder(name: album.artist.isEmpty ? album.name : album.artist)
		}
	}
}
