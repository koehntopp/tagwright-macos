import AppKit
import XCTest
@testable import Tagwright

/// ADR 0091: folder.jpg and the numbered Artwork/ files; identical pictures once; never overwritten.
final class ArtworkTests: XCTestCase {
	func jpeg(_ w: Int, _ h: Int) -> Data {
		NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .jpeg, properties: [:])!
	}
	func png(_ w: Int) -> Data {
		NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: w, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
	}

	func testSidecars() throws {
		let front = jpeg(10, 10), back1 = jpeg(11, 11), back2 = jpeg(12, 12), leaf = png(13), disc = jpeg(14, 14)
		let g: [UInt32: [Tagwright.Picture]] = [0: [], 3: [.init(type: 3, data: front)], 4: [.init(type: 4, data: back1), .init(type: 4, data: back2)], 5: [.init(type: 5, mime: "image/png", data: leaf)], 6: [.init(type: 6, data: disc)]]
		XCTAssertEqual(Artwork.names(g).map(\.0), ["folder.jpg", "Artwork/01 back.jpg", "Artwork/02 back-02.jpg", "Artwork/03 booklet-01.jpg", "Artwork/04 disc.jpg"])
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-art-\(UUID().uuidString)")
		addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try Data("mine".utf8).write(to: dir.appendingPathComponent("folder.jpg"))
		XCTAssertEqual(Artwork.plan(g, target: dir).count, 4, "an existing folder.jpg is not planned")
		XCTAssertEqual(Artwork.export(g, target: dir).count, 4)
		XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("folder.jpg")), Data("mine".utf8), "never overwritten")
		XCTAssertTrue(try Data(contentsOf: dir.appendingPathComponent("Artwork/03 booklet-01.jpg")).starts(with: [0xff, 0xd8]), "PNG written as JPEG")
		XCTAssertEqual(Artwork.export(g, target: dir).count, 0, "a second pass writes nothing")
	}
}
