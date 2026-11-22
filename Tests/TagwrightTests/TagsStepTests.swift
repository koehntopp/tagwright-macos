import AppKit
import XCTest
@testable import Tagwright

/// ADR 0028 ReplayGain skip, ADR 0074 cover resize, languages.py track matching.
final class TagsStepTests: XCTestCase {
	func flac(_ comments: [(String, String)], pictures: [Tagwright.Picture] = []) throws -> URL {
		let u = FileManager.default.temporaryDirectory.appendingPathComponent("tw-tags-\(UUID().uuidString).flac")
		var d = Data("fLaC".utf8); d.append(contentsOf: [0x80, 0, 0, 34]); d.append(Data(count: 34)); d.append(Data(count: 100))
		try d.write(to: u)
		var f = try FlacFile(url: u); f.comments = comments.map { (key: $0.0, value: $0.1) }; f.pictures = pictures; try f.save()
		addTeardownBlock { try? FileManager.default.removeItem(at: u) }
		return u
	}

	func jpeg(_ w: Int, _ h: Int) -> Data {
		let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
		return rep.representation(using: .jpeg, properties: [:])!
	}

	func testReplayGainSkipNeedsAlbumGainOnEveryFile() throws {
		let a = try flac([("REPLAYGAIN_ALBUM_GAIN", "-3.00 dB")]), b = try flac([("REPLAYGAIN_TRACK_GAIN", "-3.00 dB")])
		XCTAssertTrue(Pipeline.hasAlbumGain([a]))
		XCTAssertFalse(Pipeline.hasAlbumGain([a, b]), "track gain alone is not enough")
		XCTAssertFalse(Pipeline.hasAlbumGain([]))
		var logged: [String] = []
		try Pipeline.replayGain(files: [a], log: { logged.append($0) })
		XCTAssertEqual(logged, ["Album gain already on every file: skipped"])
	}

	func testResizeCoversOnlyWhenLarger() throws {
		let big = try flac([], pictures: [Tagwright.Picture(type: 3, mime: "image/jpeg", data: jpeg(2000, 1000)), Tagwright.Picture(type: 4, mime: "image/jpeg", data: jpeg(800, 800))])
		let small = try flac([], pictures: [Tagwright.Picture(type: 3, mime: "image/jpeg", data: jpeg(1200, 1200))])
		let before = try FlacFile(url: small).pictures
		XCTAssertEqual(try Pipeline.resizeCovers(files: [big, small], max: 1500), 1)
		let p = try FlacFile(url: big).pictures
		XCTAssertEqual(p.map(\.type), [3, 4])
		XCTAssertEqual(ImageSize.of(p[0].data).map { [$0.0, $0.1] }, [1500, 750])
		XCTAssertEqual(ImageSize.of(p[1].data).map { [$0.0, $0.1] }, [800, 800], "back cover below the maximum stays")
		XCTAssertEqual(try FlacFile(url: small).pictures, before)
		XCTAssertEqual(try Pipeline.resizeCovers(files: [big], max: 1500), 0, "idempotent")
	}

	func testFindTrack() {
		let rel = [MusicBrainz.LangTrack(id: "a", disc: 1, position: 1, title: "Money for Nothing", languages: ["eng"]),
				   MusicBrainz.LangTrack(id: "b", disc: 2, position: 1, title: "Intro", languages: [])]
		XCTAssertEqual(MusicBrainz.findTrack(rel, tags: ["MUSICBRAINZ_RELEASETRACKID": ["b"]])?.id, "b")
		XCTAssertEqual(MusicBrainz.findTrack(rel, tags: ["DISCNUMBER": ["1/2"], "TRACKNUMBER": ["1"], "TITLE": ["Money For Nothing (Remastered)"]])?.id, "a")
		XCTAssertNil(MusicBrainz.findTrack(rel, tags: ["DISCNUMBER": ["1"], "TRACKNUMBER": ["1"], "TITLE": ["Walk of Life"]]), "same position, other song")
		XCTAssertNil(MusicBrainz.findTrack(rel, tags: ["TRACKNUMBER": ["7"], "TITLE": ["Intro"]]))
	}
}
