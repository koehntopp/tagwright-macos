import XCTest
@testable import Tagwright

final class SummariesTests: XCTestCase {
	/// A stored summary is returned while the files are unchanged, survives a reload, and is dropped after a tag write.
	func testHitReloadAndInvalidate() throws {
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tw-sum-\(UUID().uuidString)")
		let dir = tmp.appendingPathComponent("Album")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tmp) }
		var d = Data("fLaC".utf8); d.append(contentsOf: [0x80, 0, 0, 34]); d.append(Data(count: 34)); d.append(Data(count: 100))
		let f = dir.appendingPathComponent("01.flac"); try d.write(to: f)
		var flac = try FlacFile(url: f); flac.comments = [("TITLE", "One")]; try flac.save()

		let store = tmp.appendingPathComponent("summaries.plist")
		let s = Summaries(url: store)
		let a = try XCTUnwrap(Scanner.loadAlbum(folder: dir, files: [f], minCover: 1000))
		s.put(a, sig: Summaries.signature(folder: dir, files: [f])); s.save()

		let hit = try XCTUnwrap(Summaries(url: store).album(folder: dir, sig: Summaries.signature(folder: dir, files: [f]), minCover: 1000))
		XCTAssertFalse(hit.full)
		XCTAssertEqual(hit.tracks.map(\.title), ["One"])

		flac = try FlacFile(url: f); flac.comments = [("TITLE", "Two, a longer title")]; try flac.save()
		XCTAssertNil(s.album(folder: dir, sig: Summaries.signature(folder: dir, files: [f]), minCover: 1000))

		s.put(try XCTUnwrap(Scanner.loadAlbum(folder: dir, files: [f], minCover: 1000)), sig: Summaries.signature(folder: dir, files: [f]))
		XCTAssertNotNil(s.album(folder: dir, sig: Summaries.signature(folder: dir, files: [f]), minCover: 1000))
		s.prune(root: tmp, keep: []); s.save()
		XCTAssertNil(Summaries(url: store).album(folder: dir, sig: Summaries.signature(folder: dir, files: [f]), minCover: 1000))
	}
}
