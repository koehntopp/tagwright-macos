import SwiftUI

struct CardView: View {
	@EnvironmentObject var app: AppState
	var album: Album
	var selected: Bool

	var body: some View {
		let s = album.status
		VStack(alignment: .leading, spacing: 0) {
			ZStack(alignment: .topLeading) {
				Color.clear.aspectRatio(1, contentMode: .fill)
					.overlay { CoverFill(album: album) }
					.clipped()
				Text(album.pillText).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
					.padding(.horizontal, 9).padding(.vertical, 3).background(s.strong, in: Capsule()).padding(12)
				if app.playing != nil, album.tracks.contains(where: { $0.id == app.playing }) {
					Image(systemName: "waveform").symbolEffect(.variableColor.iterative).foregroundStyle(Color.warn).padding(6)
						.background(.black.opacity(0.5), in: Circle()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(10)
				}
			}
			VStack(alignment: .leading, spacing: 4) {
				Text(album.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
				Text([album.artist, album.year].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(Color.ink.opacity(0.7)).lineLimit(1)
				if !album.versionLine.isEmpty { Text(album.versionLine).font(.system(size: 12)).foregroundStyle(Color.muted).lineLimit(1) }
				FlowRow {
					if !album.discogsID.isEmpty { Pill(text: "● " + album.discogsID, mono: true) }
					if !album.mbid.isEmpty { Pill(text: "MB", fg: Color(hex: 0x7c3aed)) }
					if !album.albumDR.isEmpty { DRBadge(value: album.albumDR) }
					if album.lrc > 0 { Pill(text: "LRC \(album.lrc)", fg: .white, bg: .ok) }
					if album.txt > 0 { Pill(text: "TXT \(album.txt)", fg: .black, bg: .warn) }
					if album.instr > 0 { Pill(text: "INS \(album.instr)", fg: .white, bg: .info) }
					ForEach(album.missing) { m in
						Pill(text: "\(m.label) \(m.count)", fg: m.step.optional ? Color(hex: 0x1d4ed8) : Color(hex: 0xbe123c), bg: m.step.optional ? Color(hex: 0xdbeafe) : Color(hex: 0xffe4e6))
					}
				}
				Spacer(minLength: 0)
				HStack(spacing: 8) {
					ProgressView(value: Double(album.doneCount), total: 6).tint(Color.ink).progressViewStyle(.linear)
					Text("\(album.doneCount)/6").font(.system(size: 12)).foregroundStyle(Color.muted)
				}
			}
			.padding(16)
		}
		.frame(maxWidth: .infinity, alignment: .topLeading)
		.background(s.tint, in: RoundedRectangle(cornerRadius: 18))
		.clipShape(RoundedRectangle(cornerRadius: 18))
		.overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.ink, lineWidth: selected ? 2 : 0))
		.contentShape(RoundedRectangle(cornerRadius: 18))
		.onTapGesture { app.selection = album.id }
		.onDrop(of: ["public.file-url", "public.image"], isTargeted: nil) { app.dropCover(album, providers: $0) }
	}
}

/// Wrapping row of small items.
struct FlowRow<Content: View>: View {
	@ViewBuilder var content: Content
	var body: some View { WrapLayout(spacing: 5) { content } }
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
				EmptyState(title: "No folder chosen", text: "Choose the \(app.source == .staging ? "staging" : "library") folder in Settings.", action: "Open Settings") { app.sheet = .settings }
			} else if app.shown.isEmpty && !app.scanning {
				EmptyState(title: "No albums", text: app.albums.isEmpty ? "No FLAC albums found in this folder." : "Nothing matches this filter.", action: "Rescan") { app.rescan() }
			} else if app.listView {
				AlbumTable()
			} else {
				ScrollView {
					LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 20, alignment: .top)], alignment: .leading, spacing: 20) {
						ForEach(app.shown) { a in CardView(album: a, selected: a.id == app.selection) }
					}
					.padding(32)
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color.board)
		.overlay(alignment: .center) { if app.scanning && app.albums.isEmpty { ProgressView("Scanning…") } }
	}
}

struct EmptyState: View {
	var title: String, text: String, action: String, run: () -> Void
	var body: some View {
		VStack(spacing: 10) {
			Text(title).font(.title3.weight(.semibold))
			Text(text).foregroundStyle(Color.muted)
			Button(action, action: run).buttonStyle(SoftButton(dark: true)).frame(width: 160)
		}.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

/// ADR 0085/0086: sortable table with the same selection and status model as the cards.
struct AlbumTable: View {
	@EnvironmentObject var app: AppState
	@State private var order = [KeyPathComparator(\Album.artist)]
	var body: some View {
		Table(app.shown.sorted(using: order), selection: $app.selection, sortOrder: $order) {
			TableColumn("Status") { a in Pill(text: a.status.label, fg: .white, bg: a.status.strong) }.width(min: 90, ideal: 100)
			TableColumn("Album artist", value: \.artist).width(min: 100, ideal: 180)
			TableColumn("Release name", value: \.title).width(min: 120, ideal: 230)
			TableColumn("Media", value: \.format).width(min: 50, ideal: 70)
			TableColumn("Edition", value: \.edition).width(min: 70, ideal: 120)
			TableColumn("Catalog #", value: \.catalog).width(min: 80, ideal: 120)
			TableColumn("DR", value: \.albumDR) { a in
				if let n = Int(a.albumDR) { Pill(text: "DR\(n)", fg: n >= 12 ? Color(hex: 0x065f46) : Color(hex: 0x92400e), bg: n >= 12 ? Color(hex: 0xd1fae5) : Color(hex: 0xfef3c7)) }
			}.width(56)
			TableColumn("Release", value: \.year).width(60)
			TableColumn("Master", value: \.masterYear).width(60)
		}
		.scrollContentBackground(.hidden)
	}
}

struct CoverFill: View {
	@EnvironmentObject var app: AppState
	var album: Album
	var body: some View {
		if let img = app.thumbnail(album, size: 640) {
			Image(nsImage: img).resizable().scaledToFill()
		} else {
			ZStack { Color(hex: 0xcbd5e1); Image(systemName: "opticaldisc").font(.system(size: 60)).foregroundStyle(.white.opacity(0.8)) }
		}
	}
}
