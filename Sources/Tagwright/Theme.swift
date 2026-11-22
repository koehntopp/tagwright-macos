import AppKit
import SwiftUI

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
}

extension Status {
	var tint: Color { switch self { case .needs: Color(hex: 0xfee2e2); case .ready: Color(hex: 0xdbeafe); case .fixed: Color(hex: 0xd1fae5) } }
	var strong: Color { switch self { case .needs: Color(hex: 0xe11d48); case .ready: Color(hex: 0x0284c7); case .fixed: Color(hex: 0x059669) } }
}

struct Pill: View {
	var text: String
	var fg: Color = .ink
	var bg: Color = .white
	var mono = false
	var body: some View {
		Text(text).font(.system(size: 11, weight: .medium, design: mono ? .monospaced : .default))
			.foregroundStyle(fg).padding(.horizontal, 8).padding(.vertical, 2)
			.background(bg, in: Capsule())
	}
}

struct DRBadge: View {
	var value: String
	var body: some View { Pill(text: "DR\(value)", fg: Color(hex: 0x065f46), bg: Color(hex: 0xd1fae5)) }
}

struct CoverView: View {
	@EnvironmentObject var app: AppState
	var album: Album
	var size: CGFloat
	var body: some View {
		Group {
			if let img = app.thumbnail(album, size: Int(size * 2)) {
				Image(nsImage: img).resizable().scaledToFill()
			} else {
				ZStack { Color(hex: 0xcbd5e1); Image(systemName: "opticaldisc").font(.system(size: size * 0.3)).foregroundStyle(.white.opacity(0.8)) }
			}
		}
		.frame(width: size, height: size).clipped()
	}
}

struct SoftButton: ButtonStyle {
	var dark = false
	var danger = false
	@Environment(\.isEnabled) var enabled
	func makeBody(configuration c: Configuration) -> some View {
		c.label.font(.system(size: 13, weight: .medium))
			.foregroundStyle(dark || danger ? .white : (enabled ? Color.ink : Color.muted.opacity(0.6)))
			.padding(.horizontal, 14).frame(height: 32).frame(maxWidth: .infinity)
			.background(danger ? Color.bad : dark ? Color.ink : .white, in: RoundedRectangle(cornerRadius: 8))
			.overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.1)))
			.opacity(enabled ? (c.isPressed ? 0.8 : 1) : 0.5)
	}
}

/// The web app's lucide icons (lucide-react 1.71, ISC licence): outline glyphs with a 2 px stroke on a 24 px
/// grid. NSImage draws SVG natively; the images are templates, so `foregroundStyle` colours them.
enum Lucide: String {
	case pencil, play, pause, copy
	private var body: String {
		switch self {
		case .pencil: #"<path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/>"#
		case .play: #"<path d="M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z"/>"#
		case .pause: #"<rect x="14" y="3" width="5" height="18" rx="1"/><rect x="5" y="3" width="5" height="18" rx="1"/>"#
		case .copy: #"<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>"#
		}
	}
	@MainActor private static var cache: [Lucide: NSImage] = [:]
	@MainActor var image: NSImage {
		if let i = Self.cache[self] { return i }
		let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">"# + body + "</svg>"
		let i = NSImage(data: Data(svg.utf8)) ?? NSImage()
		i.isTemplate = true
		Self.cache[self] = i
		return i
	}
}

struct LucideIcon: View {
	var icon: Lucide
	var size: CGFloat = 14
	var body: some View { Image(nsImage: icon.image).resizable().renderingMode(.template).frame(width: size, height: size) }
}

/// Icon button like the web app's (`rounded-full p-1 hover:bg-white`, pointer cursor): a bare outline icon at
/// rest, a round fill under it on hover.
struct IconButton: ButtonStyle {
	var color = Color.ink
	var hover = Color.white
	func makeBody(configuration c: Configuration) -> some View { IconBody(c: c, style: self) }
	struct IconBody: View {
		let c: Configuration, style: IconButton
		@State private var over = false
		@Environment(\.isEnabled) private var enabled
		var body: some View {
			c.label
				.foregroundStyle(enabled ? (over ? Color.ink : style.color) : Color.muted.opacity(0.5))
				.padding(5)
				.background(Circle().fill(c.isPressed ? Color.black.opacity(0.1) : over && enabled ? style.hover : .clear))
				.contentShape(Circle())
				.onHover { h in
					over = h
					if h && enabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
				}
		}
	}
}
