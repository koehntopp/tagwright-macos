import AppKit
import XCTest
@testable import Tagwright

/// ADR 0091, 0098, 0099: folder.jpg and the numbered Artwork/ files per folder; identical pictures once; a move never
/// overwrites, a library rebuild does; per-disc writes; the box-set cover.
final class ArtworkTests: XCTestCase {
	func jpeg(_ w: Int, _ h: Int) -> Data {
		NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .jpeg, properties: [:])!
	}
	func png(_ w: Int) -> Data {
		NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: w, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
	}
	func dir() throws -> URL {
		let d = FileManager.default.temporaryDirectory.appendingPathComponent("tw-art-\(UUID().uuidString)")
		addTeardownBlock { try? FileManager.default.removeItem(at: d) }
		try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
		return d
	}
	@discardableResult func flac(_ at: URL, disc: Int, pictures: [Tagwright.Picture]) throws -> URL {
		try FileManager.default.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
		var d = Data("fLaC".utf8); d.append(contentsOf: [0x80, 0, 0, 34]); d.append(Data(count: 34)); d.append(Data(count: 100))
		try d.write(to: at)
		var f = try FlacFile(url: at); f.comments = [(key: "DISCNUMBER", value: "\(disc)")]; f.pictures = pictures; try f.save()
		return at
	}

	func testNames() {
		let front = jpeg(10, 10), back1 = jpeg(11, 11), back2 = jpeg(12, 12), leaf = png(13), disc = jpeg(14, 14)
		let g: [UInt32: [Tagwright.Picture]] = [0: [], 3: [.init(type: 3, data: front)], 4: [.init(type: 4, data: back1), .init(type: 4, data: back2)], 5: [.init(type: 5, mime: "image/png", data: leaf)], 6: [.init(type: 6, data: disc)]]
		XCTAssertEqual(Artwork.names(g).map(\.0), ["folder.jpg", "Artwork/01 back.jpg", "Artwork/02 back-02.jpg", "Artwork/03 booklet-01.jpg", "Artwork/04 disc.jpg"])
	}

	func testExportNeverOverwritesAndConvertsToJpeg() throws {
		let album = try dir()
		try flac(album.appendingPathComponent("01.flac"), disc: 1, pictures: [.init(type: 3, data: jpeg(10, 10)), .init(type: 5, mime: "image/png", data: png(13))])
		try Data("mine".utf8).write(to: album.appendingPathComponent("folder.jpg"))
		XCTAssertEqual(Artwork.export(album), ["Artwork/01 booklet-01.jpg"])
		XCTAssertEqual(try Data(contentsOf: album.appendingPathComponent("folder.jpg")), Data("mine".utf8), "never overwritten on a move")
		XCTAssertTrue(try Data(contentsOf: album.appendingPathComponent("Artwork/01 booklet-01.jpg")).starts(with: [0xff, 0xd8]), "PNG written as JPEG")
		XCTAssertEqual(Artwork.export(album), [], "a second pass writes nothing")
	}

	func testDiscFoldersBoxCoverAndRebuild() throws {
		let album = try dir(), d1 = jpeg(21, 21), d2back = jpeg(22, 22), box = jpeg(23, 23)
		let boxPic = Tagwright.Picture(type: 3, desc: Artwork.boxDesc, data: box)
		let a = try flac(album.appendingPathComponent("Disc 1/01.flac"), disc: 1, pictures: [.init(type: 3, data: d1), boxPic])
		let b = try flac(album.appendingPathComponent("Disc 2/01.flac"), disc: 2, pictures: [boxPic, .init(type: 4, data: d2back)])
		XCTAssertEqual(Artwork.export(album).sorted(), ["Disc 1/folder.jpg", "Disc 2/Artwork/01 back.jpg", "Disc 2/folder.jpg", "folder.jpg"])
		XCTAssertEqual(try Data(contentsOf: album.appendingPathComponent("folder.jpg")), box, "the box folder shows the box cover")
		XCTAssertEqual(try Data(contentsOf: album.appendingPathComponent("Disc 1/folder.jpg")), d1, "a disc folder its own front")
		XCTAssertEqual(try Data(contentsOf: album.appendingPathComponent("Disc 2/folder.jpg")), box, "else the box cover")

		// a new front for disc 2 only goes first in disc 2's files; disc 1 and the box cover stay
		let d2 = jpeg(24, 24)
		try Artwork.write([a, b], type: 3, pictures: [.init(type: 3, data: d2)], disc: 2)
		XCTAssertEqual(try FlacFile(url: a).pictures.map(\.data), [d1, box])
		XCTAssertEqual(try FlacFile(url: b).pictures.map(\.data), [d2, box, d2back])
		// deleting disc 2's back cover and rebuilding removes its file and the emptied Artwork/ folder
		try Artwork.write([a, b], type: 4, pictures: [], disc: 2)
		Artwork.rebuild(album)
		XCTAssertEqual(try Data(contentsOf: album.appendingPathComponent("Disc 2/folder.jpg")), d2, "rebuild overwrites")
		XCTAssertFalse(FileManager.default.fileExists(atPath: album.appendingPathComponent("Disc 2/Artwork").path))
		XCTAssertEqual(Artwork.read([a, b], disc: 1)[3]?.map(\.data), [d1])
		XCTAssertEqual(Artwork.read([a, b])[Artwork.box]?.map(\.data), [box])
	}

	func testMovePlanListsCoverFilesPerFolder() throws {
		let src = try dir(), lib = try dir().appendingPathComponent("A/Album")
		let one = try flac(src.appendingPathComponent("1.flac"), disc: 1, pictures: [.init(type: 3, data: jpeg(10, 10))])
		let two = try flac(src.appendingPathComponent("2.flac"), disc: 2, pictures: [.init(type: 3, data: jpeg(11, 11))])
		XCTAssertEqual(Artwork.plan(lib, moves: [(one, lib.appendingPathComponent("Disc 1/01.flac")), (two, lib.appendingPathComponent("Disc 2/01.flac"))]),
			["folder.jpg", "Disc 1/folder.jpg", "Disc 2/folder.jpg"])
	}
}
