import XCTest
@testable import Tagwright

final class CoverTests: XCTestCase {
	func testEmbedCover() throws {
		guard let src = ProcessInfo.processInfo.environment["TW_FIXTURE"] else { throw XCTSkip("TW_FIXTURE not set") }
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tw-\(UUID().uuidString)")
		try FileManager.default.copyItem(atPath: src, toPath: tmp.path)
		defer { try? FileManager.default.removeItem(at: tmp) }
		let (dir, files) = Scanner.albumFolders(root: tmp, staging: true)[0]
		let data = try Data(contentsOf: dir.appendingPathComponent("cover.jpg"))
		let (d, mime, w, h) = try XCTUnwrap(ImageSize.embeddable(data, max: 1200))
		XCTAssertEqual(max(w, h), 1200)
		for u in files { var f = try FlacFile(url: u); f.pictures = [Picture(type: 3, mime: mime, desc: "", width: UInt32(w), height: UInt32(h), data: d)]; try f.save() }
		let a = try XCTUnwrap(Scanner.loadAlbum(folder: dir, files: files, minCover: 1000))
		XCTAssertEqual(a.cover?.width, 1200); XCTAssertTrue(a.cover?.embedded ?? false)
	}
}
