import SwiftUI
import XCTest
@testable import Tagwright

/// TW_RENDER=<png path>: renders the icon button states (rest, playing, paused row, pen) for a visual check.
final class RenderIconsTests: XCTestCase {
	@MainActor func testRender() throws {
		guard let out = ProcessInfo.processInfo.environment["TW_RENDER"] else { throw XCTSkip("set TW_RENDER") }
		func row(_ label: String, playing: Bool, paused: Bool) -> some View {
			HStack(spacing: 8) {
				Button {} label: { LucideIcon(icon: playing && !paused ? .pause : .play, size: 14) }.buttonStyle(IconButton())
				Text(label).font(.system(size: 13)); Spacer()
				Button {} label: { LucideIcon(icon: .pencil, size: 14) }.buttonStyle(IconButton())
			}
			.padding(.vertical, 4).padding(.leading, 8)
			.background(playing ? Color(hex: 0xfef9c3) : .clear)
			.overlay(alignment: .leading) { if playing { Rectangle().fill(Color.warn).frame(width: 3) } }
		}
		let v = VStack(spacing: 4) { row("rest", playing: false, paused: false); row("playing", playing: true, paused: false); row("paused", playing: true, paused: true) }
			.frame(width: 320).padding(12).background(Color.board)
		let r = ImageRenderer(content: v); r.scale = 2
		let img = try XCTUnwrap(r.nsImage)
		let rep = NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation))!
		try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
	}
}
