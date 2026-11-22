import AppKit
import SwiftUI

// The web app's look (Tailwind + shadcn/ui), rebuilt for SwiftUI. Sizes are the web's CSS pixels as points.

extension Color {
	init(hex: UInt32) { self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255) }
	static let topBar = Color(hex: 0xe9edf3)
	static let board = Color(hex: 0xf1f4f9)
	static let ink = Color(hex: 0x0f172a)
	static let muted = Color(hex: 0x64748b)
	static let brand = Color(hex: 0xf4511e)
	static let ok = Color(hex: 0x10b981)
	static let warn = Color(hex: 0xfbbf24)
	static let bad = Color(hex: 0xef4444)
	static let info = Color(hex: 0x3b82f6)

	/// Tailwind colours by name and shade, as the web app uses them.
	static func slate(_ n: Int) -> Color { tw(["50": 0xf8fafc, "100": 0xf1f5f9, "200": 0xe2e8f0, "300": 0xcbd5e1, "400": 0x94a3b8, "500": 0x64748b, "600": 0x475569, "700": 0x334155, "800": 0x1e293b, "900": 0x0f172a], n) }
	static func rose(_ n: Int) -> Color { tw(["50": 0xfff1f2, "100": 0xffe4e6, "200": 0xfecdd3, "300": 0xfda4af, "500": 0xf43f5e, "600": 0xe11d48, "700": 0xbe123c, "800": 0x9f1239, "900": 0x881337], n) }
	static func emerald(_ n: Int) -> Color { tw(["50": 0xecfdf5, "100": 0xd1fae5, "200": 0xa7f3d0, "400": 0x34d399, "500": 0x10b981, "600": 0x059669, "700": 0x047857, "800": 0x065f46], n) }
	static func amber(_ n: Int) -> Color { tw(["50": 0xfffbeb, "100": 0xfef3c7, "200": 0xfde68a, "400": 0xfbbf24, "500": 0xf59e0b, "600": 0xd97706, "700": 0xb45309, "800": 0x92400e, "900": 0x78350f, "950": 0x451a03], n) }
	static func sky(_ n: Int) -> Color { tw(["50": 0xf0f9ff, "100": 0xe0f2fe, "200": 0xbae6fd, "300": 0x7dd3fc, "400": 0x38bdf8, "500": 0x0ea5e9, "600": 0x0284c7, "700": 0x0369a1, "800": 0x075985, "900": 0x0c4a6e, "950": 0x082f49], n) }
	static func yellow(_ n: Int) -> Color { tw(["50": 0xfefce8, "100": 0xfef9c3, "200": 0xfef08a, "400": 0xfacc15, "800": 0x854d0e], n) }
	static func violet(_ n: Int) -> Color { tw(["100": 0xede9fe, "800": 0x5b21b6], n) }
	private static func tw(_ m: [String: UInt32], _ n: Int) -> Color { Color(hex: m["\(n)"] ?? 0xff00ff) }
}

extension Status {
	/// Card background and border (page.tsx TONE), the status pill (BADGE) and the list dot (album-list.tsx DOT).
	var tint: Color { switch self { case .needs: .rose(100); case .ready: .sky(100); case .fixed: .emerald(100) } }
	var border: Color { switch self { case .needs: Color.rose(200).opacity(0.7); case .ready: Color.sky(200).opacity(0.7); case .fixed: Color.emerald(200).opacity(0.7) } }
	var strong: Color { switch self { case .needs: .rose(600); case .ready: .sky(600); case .fixed: .emerald(600) } }
}

/// `inline-flex h-5 rounded-full px-2 text-[11px] font-medium` (page.tsx / inspector.tsx Pill).
struct Pill: View {
	var text: String
	var fg: Color = .ink
	var bg: Color = .white
	var mono = false
	var border = false
	var width: CGFloat? = nil
	var body: some View {
		Text(text).font(.system(size: 11, weight: .medium, design: mono ? .monospaced : .default)).lineLimit(1)
			.foregroundStyle(fg).padding(.horizontal, 8).frame(minWidth: width, maxWidth: width).frame(height: 20)
			.background(bg, in: Capsule())
			.overlay { if border { Capsule().stroke(Color.slate(200)) } }
	}
}

struct DRBadge: View {
	var value: String
	var body: some View { Pill(text: "DR\(value)", fg: .emerald(800), bg: .emerald(100)).help("Album dynamic range") }
}

/// Lyrics kind badge (inspector.tsx LY): LRC green, TXT amber, INS sky, --- rose, with the web tooltips.
struct LyricsBadge: View {
	var kind: LyricsKind
	var width: CGFloat? = 40
	var body: some View {
		let (t, fg, bg, h): (String, Color, Color, String) = switch kind {
		case .lrc: ("LRC", .white, .emerald(500), "Synced lyrics (LRC)")
		case .txt: ("TXT", .amber(950), .amber(400), "Plain text lyrics, not synced")
		case .instr: ("INS", .sky(800), .sky(100), "Instrumental")
		case .none: ("---", .rose(700), .rose(100), "No lyrics")
		}
		Pill(text: t, fg: fg, bg: bg, width: width).help(h)
	}
}

/// Channel layout (ADR 0040): Mono and Stereo neutral, multichannel violet; 52 pt wide.
struct ChannelBadge: View {
	var n: Int
	static func label(_ n: Int) -> String { [1: "Mono", 2: "Stereo", 3: "3.0", 4: "4.0", 5: "5.0", 6: "5.1", 7: "6.1", 8: "7.1"][n] ?? "\(n) ch" }
	var body: some View {
		if n > 0 {
			Pill(text: Self.label(n), fg: n > 2 ? .violet(800) : .slate(700), bg: n > 2 ? .violet(100) : .slate(200), width: 52).help("\(n) channel\(n > 1 ? "s" : "")")
		}
	}
}

extension NSImage {
	/// A copy drawn at `pt` points (menu items show an NSImage at its own size).
	func sized(_ pt: CGFloat) -> NSImage {
		let i = NSImage(size: NSSize(width: pt, height: pt), flipped: false) { r in self.draw(in: r); return true }
		i.isTemplate = isTemplate
		return i
	}
	/// The same on a dark rounded tile (`bg-slate-800 p-px`), for the white musichoarders logo.
	func onTile(_ pt: CGFloat) -> NSImage {
		NSImage(size: NSSize(width: pt, height: pt), flipped: false) { r in
			NSColor(red: 0x1e / 255.0, green: 0x29 / 255.0, blue: 0x3b / 255.0, alpha: 1).setFill()
			NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
			self.draw(in: r.insetBy(dx: 1, dy: 1)); return true
		}
	}
}

struct LucideIcon: View {
	var icon: Lucide
	var size: CGFloat = 14
	var body: some View { Image(nsImage: icon.image).resizable().renderingMode(.template).frame(width: size, height: size) }
}

/// One of the web app's static images (logo, service icons).
struct AssetIcon: View {
	var asset: Asset
	var size: CGFloat = 14
	var body: some View { Image(nsImage: asset.image).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 2)) }
}

/// Spinning lucide RefreshCw / Loader2 (`animate-spin`).
struct Spinner: View {
	var icon: Lucide = .refreshCw
	var size: CGFloat = 14
	@State private var on = false
	var body: some View {
		LucideIcon(icon: icon, size: size).rotationEffect(.degrees(on ? 360 : 0))
			.animation(.linear(duration: 1).repeatForever(autoreverses: false), value: on).onAppear { on = true }
	}
}

/// The playing indicator: four bars bouncing (`eq-bar`).
struct EqBars: View {
	var color: Color = .slate(900)
	var body: some View {
		TimelineView(.animation) { ctx in
			let t = ctx.date.timeIntervalSinceReferenceDate
			HStack(alignment: .center, spacing: 2) {
				ForEach([0, 0.25, 0.5, 0.15], id: \.self) { d in
					RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2, height: 4 + 10 * abs(sin((t + d) * 4)))
				}
			}.frame(height: 16)
		}
	}
}

// MARK: buttons and fields (shadcn/ui)

/// shadcn Button: `default` dark, `outline`, `ghost`, `danger` (rose); sizes `xs` h-6, `sm` h-8, `md` h-9.
struct WebButton: ButtonStyle {
	enum Kind { case primary, outline, ghost, danger }
	enum Size { case xs, sm, md }
	var kind: Kind = .outline
	var size: Size = .sm
	var full = false
	func makeBody(configuration c: Configuration) -> some View { WBody(c: c, s: self) }
	struct WBody: View {
		let c: Configuration, s: WebButton
		@State private var over = false
		@Environment(\.isEnabled) private var enabled
		var body: some View {
			let h: CGFloat = s.size == .xs ? 24 : s.size == .sm ? 32 : 36
			let fg: Color = s.kind == .primary || s.kind == .danger ? .white : .slate(900)
			let bg: Color = switch s.kind {
			case .primary: over ? .slate(700) : .slate(800)
			case .danger: over ? .rose(700) : .rose(600)
			case .outline: over ? .slate(100) : .white
			case .ghost: over ? .slate(100) : .clear
			}
			c.label.font(.system(size: s.size == .xs ? 12 : 14, weight: .medium)).lineLimit(1)
				.foregroundStyle(fg).padding(.horizontal, s.size == .xs ? 8 : s.size == .sm ? 12 : 16)
				.frame(height: h).frame(maxWidth: s.full ? .infinity : nil)
				.background(bg, in: RoundedRectangle(cornerRadius: 6))
				.overlay { if s.kind == .outline { RoundedRectangle(cornerRadius: 6).stroke(Color.slate(200)) } }
				.shadow(color: .black.opacity(s.kind == .outline ? 0.05 : 0), radius: 1, y: 1)
				.opacity(enabled ? (c.isPressed ? 0.85 : 1) : 0.5)
				.contentShape(RoundedRectangle(cornerRadius: 6))
				.onHover { over = $0 && enabled }
		}
	}
}

/// shadcn Input: `h-9 rounded-md border px-3 text-sm shadow-xs`; `h` sets the height (h-7, h-8).
struct WebField: ViewModifier {
	var height: CGFloat = 36
	var tint: Color = .white
	var border: Color = .slate(200)
	func body(content: Content) -> some View {
		content.textFieldStyle(.plain).font(.system(size: height < 32 ? 12 : 14)).padding(.horizontal, height < 32 ? 8 : 12)
			.frame(height: height).background(tint, in: RoundedRectangle(cornerRadius: 6))
			.overlay(RoundedRectangle(cornerRadius: 6).stroke(border))
	}
}
extension View {
	func webField(height: CGFloat = 36, tint: Color = .white, border: Color = .slate(200)) -> some View { modifier(WebField(height: height, tint: tint, border: border)) }
	func pointer() -> some View { onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() } }
}

/// Icon button like the web app's (`rounded-full p-1 hover:bg-white`, pointer cursor): a bare outline icon at
/// rest, a round fill under it on hover.
struct IconButton: ButtonStyle {
	var color = Color.ink
	var hover = Color.white
	var hoverText: Color? = nil
	func makeBody(configuration c: Configuration) -> some View { IconBody(c: c, style: self) }
	struct IconBody: View {
		let c: Configuration, style: IconButton
		@State private var over = false
		@Environment(\.isEnabled) private var enabled
		var body: some View {
			c.label
				.foregroundStyle(enabled ? (over ? (style.hoverText ?? style.color) : style.color) : Color.muted.opacity(0.5))
				.padding(4)
				.background(Circle().fill(c.isPressed ? Color.black.opacity(0.1) : over && enabled ? style.hover : .clear))
				.contentShape(Circle())
				.onHover { h in
					over = h
					if h && enabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
				}
		}
	}
}

/// inspector.tsx CopyBtn: slate-400 copy icon, black/5 hover, toast "Copied".
struct CopyButton: View {
	@EnvironmentObject var app: AppState
	var text: String
	var title = "Copy"
	var size: CGFloat = 12
	var body: some View {
		Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); app.notify("Copied", kind: .success) } label: { LucideIcon(icon: .copy, size: size) }
			.buttonStyle(IconButton(color: .slate(400), hover: Color.black.opacity(0.05), hoverText: .slate(700))).help(title)
	}
}

/// The ID of a release on Discogs or MusicBrainz (inspector.tsx IdBadge); without one a rose "missing" that
/// searches the site for `query` when there is one.
struct IdBadge: View {
	enum Service { case discogs, musicbrainz }
	var service: Service
	var id: String
	var full = false
	var query = ""
	@State private var over = false
	var body: some View {
		let icon: Asset = service == .discogs ? .discogs : .musicbrainz
		let url = id.isEmpty
			? (query.isEmpty ? nil : URL(string: (service == .discogs ? "https://www.discogs.com/search?type=all&q=" : "https://musicbrainz.org/search?type=release&method=indexed&query=") + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")))
			: URL(string: (service == .discogs ? "https://www.discogs.com/release/" : "https://musicbrainz.org/release/") + id)
		Button { if let url { NSWorkspace.shared.open(url) } } label: {
			HStack(spacing: 4) {
				AssetIcon(asset: icon, size: 14)
				Text(id.isEmpty ? "missing" : (!full && id.count > 13 ? String(id.prefix(8)) : id))
					.font(.system(size: 11, weight: id.isEmpty ? .medium : .regular, design: id.isEmpty ? .default : .monospaced))
			}
			.foregroundStyle(id.isEmpty ? Color.rose(700) : Color.ink)
			.padding(.horizontal, 8).padding(.vertical, 2)
			.background(id.isEmpty ? (over && url != nil ? Color.rose(200) : .rose(100)) : (over ? .slate(200) : .slate(100)), in: Capsule())
		}
		.buttonStyle(.plain).onHover { over = $0 }.disabled(url == nil)
		.help(id.isEmpty && !query.isEmpty ? "Search \(service == .discogs ? "Discogs" : "MusicBrainz") for \(query)" : "")
	}
}

/// Generated cover placeholder (inspector.tsx CoverImg): a gradient from the artist's name with its initials.
struct CoverPlaceholder: View {
	var name: String
	var body: some View {
		let hue = name.unicodeScalars.reduce(7) { ($0 * 31 + Int($1.value)) % 360 }
		let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
		ZStack {
			LinearGradient(colors: [Color(hue: Double(hue) / 360, saturation: 0.7, brightness: 0.85), Color(hue: Double((hue + 40) % 360) / 360, saturation: 0.75, brightness: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
			GeometryReader { g in Text(initials.isEmpty ? "?" : initials).font(.system(size: min(30, g.size.width * 0.15), weight: .bold)).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity, maxHeight: .infinity) }
		}
	}
}

// MARK: dialog shell (dialogs.tsx Shell)

/// Every dialog of the web app: title (18 pt) with optional header content beside it, the close cross, content,
/// a rose error line and the footer Cancel + primary button (rose while `danger`).
struct Shell<Content: View, Header: View>: View {
	var title: String
	var width: CGFloat = 640
	var err: String? = nil
	var saveLabel: String? = "Save"
	var saveDisabled = false
	var danger = false
	var cancelLabel = "Cancel"
	var save: (() -> Void)? = nil
	var onClose: () -> Void
	@ViewBuilder var header: Header
	@ViewBuilder var content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 12) {
				Text(title).font(.system(size: 18, weight: .semibold)).fixedSize()
				header
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.trailing, 20)
			content.padding(.top, 12)
			if let err, !err.isEmpty { Text(err).font(.system(size: 14)).foregroundStyle(Color.rose(600)).padding(.top, 8) }
			HStack(spacing: 8) {
				Spacer()
				Button(cancelLabel, action: onClose).buttonStyle(WebButton(kind: .outline)).keyboardShortcut(.cancelAction)
				if let save, let saveLabel { Button(saveLabel, action: save).buttonStyle(WebButton(kind: danger ? .danger : .primary)).disabled(saveDisabled) }
			}.padding(.top, 16)
		}
		.padding(24)
		.frame(width: width, alignment: .topLeading)
		.background(.white, in: RoundedRectangle(cornerRadius: 16))
		.overlay(alignment: .topTrailing) {
			Button(action: onClose) { LucideIcon(icon: .x, size: 16) }.buttonStyle(IconButton(color: Color.slate(900).opacity(0.7), hover: .slate(100))).padding(12).help("Close")
		}
		.shadow(color: .black.opacity(0.15), radius: 24, y: 8)
	}
}

extension Shell where Header == EmptyView {
	init(title: String, width: CGFloat = 640, err: String? = nil, saveLabel: String? = "Save", saveDisabled: Bool = false, danger: Bool = false, cancelLabel: String = "Cancel", save: (() -> Void)? = nil, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
		self.init(title: title, width: width, err: err, saveLabel: saveLabel, saveDisabled: saveDisabled, danger: danger, cancelLabel: cancelLabel, save: save, onClose: onClose, header: { EmptyView() }, content: content)
	}
}

/// Small grey help text (`text-xs text-slate-500`) and a labelled field (dialogs.tsx Field).
struct Field<Content: View>: View {
	var label: String
	var help: String? = nil
	@ViewBuilder var content: Content
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(label).font(.system(size: 14, weight: .medium))
			content
			if let help { Text(help).font(.system(size: 12)).foregroundStyle(Color.slate(500)).fixedSize(horizontal: false, vertical: true) }
		}
	}
}
