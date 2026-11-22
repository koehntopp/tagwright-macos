import XCTest
@testable import Tagwright

/// The Discogs player and DISCOGS_* tags of a release equal the web app's release_tags() (scripts/web-release-tags.py
/// runs that function, extracted from ../tagwright/app.py, on the same JSON).
final class ReleaseTagsTests: XCTestCase {
	let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

	func testMatchesWebReleaseTags() throws {
		let py = dir.appendingPathComponent("../../../tagwright/.venv/bin/python").standardized.path
		guard FileManager.default.isExecutableFile(atPath: py) else { throw XCTSkip("the web app's venv is not there") }
		for id in ["9886890", "1524544"] {
			let json = dir.appendingPathComponent("Fixtures/discogs/\(id).json")
			let r = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
			let p = Process(); p.executableURL = URL(fileURLWithPath: py)
			p.arguments = [dir.appendingPathComponent("../../scripts/web-release-tags.py").standardized.path, json.path]
			let pipe = Pipe(); p.standardOutput = pipe; try p.run(); p.waitUntilExit()
			let web = try XCTUnwrap(JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) as? [String: [String: [String]]])
			XCTAssertEqual(Discogs.discogsTags(r), web["discogs"], "DISCOGS_* of \(id)")
			var player = Discogs.playerTags(r); player["COMPOSER"] = nil   // the web app keeps the writers apart from the player tags
			XCTAssertEqual(player, web["player"], "player tags of \(id)")
		}
	}
}

/// ADR 0053/0080 re-assignment: nothing of the previous release stays behind.
final class ReassignTests: XCTestCase {
	func testReassignReplacesPreviousRelease() async throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-reassign-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
		var d = Data("fLaC".utf8); d.append(contentsOf: [0x80, 0, 0, 34]); d.append(Data(count: 34)); d.append(Data(count: 100))
		let f = dir.appendingPathComponent("01.flac"); try d.write(to: f)
		var flac = try FlacFile(url: f)
		flac.comments = [("TITLE", "Turn To Stone"), ("ARTIST", "Someone"), ("DISCOGS_RELEASE_ID", "9886890"), ("GENRE", "Old Genre"), ("LABEL", "Old Label"),
			("DISCOGS_MASTER_ID", "m25569"), ("DISCOGS_RECORDED_AT", "Old Studio"), ("DISCOGS_VIDEO_URL", "old: x")]
		flac.pictures = [Picture(type: 3, mime: "image/png", data: Data([0x89, 0x50]))]   // has a cover: no image download
		try flac.save()

		let json = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/discogs/1524544.json")
		let r = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
		let album = try XCTUnwrap(Scanner.loadAlbum(folder: dir, files: [f], minCover: 0))
		let track = Discogs.tracklist(r)[0]
		try await Assign.apply(album: album, release: r, id: 1524544, items: [Assign.Item(url: f, track: track, disc: 1, number: 1, title: track.title)], importTitles: false, total: ([1: 1], 1))

		let t = try FlacFile(url: f).tags
		XCTAssertEqual(t.first("DISCOGS_RELEASE_ID"), "1524544")
		XCTAssertEqual(t["GENRE"], Discogs.playerTags(r)["GENRE"], "player tags follow the new release")
		XCTAssertEqual(t["LABEL"], Discogs.playerTags(r)["LABEL"])
		XCTAssertEqual(t["DISCOGS_MASTER_ID"], Discogs.discogsTags(r)["DISCOGS_MASTER_ID"])
		XCTAssertNil(t["DISCOGS_RECORDED_AT"].flatMap { $0 == ["Old Studio"] ? $0 : nil }, "old DISCOGS_* removed")
		XCTAssertFalse(t["DISCOGS_VIDEO_URL"]?.contains("old: x") ?? false)
		XCTAssertEqual(t.first("DISCOGS_RELEASE_ORDINAL_POSITION"), "0")
		XCTAssertEqual(t.first("TRACK_NUMBER_TEXT"), track.position)
		XCTAssertEqual(t.first("ARTIST"), "Someone", "titles off: the artist is only filled when empty")
	}
}
