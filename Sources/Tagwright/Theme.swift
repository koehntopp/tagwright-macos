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
