import XCTest
@testable import Tagwright

/// Runs the native steps on a copy of a fixture staging folder given by TW_FIXTURE (skipped otherwise).
final class PipelineTests: XCTestCase {
	func testSteps() async throws {
		guard let src = ProcessInfo.processInfo.environment["TW_FIXTURE"] else { throw XCTSkip("TW_FIXTURE not set") }
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tw-\(UUID().uuidString)")
		try FileManager.default.copyItem(atPath: src, toPath: tmp.path)
		let (dir, files) = Scanner.albumFolders(root: tmp, staging: true)[0]
		var album = Scanner.loadAlbum(folder: dir, files: files, minCover: 1000)!
		let urls = album.tracks.map(\.url)
		try Pipeline.dynamicRange(files: urls, log: { print($0) })
		try Pipeline.replayGain(files: urls, log: { print($0) })
		try Pipeline.fingerprints(files: urls, log: { print($0) })
		album = Scanner.loadAlbum(folder: dir, files: files, minCover: 1000)!
		XCTAssertEqual(album.missingTracks(.dr).count, 0)
		XCTAssertEqual(album.missingTracks(.replaygain).count, 0)
		XCTAssertEqual(album.missingTracks(.fingerprints).count, 0)
		try Pipeline.rename(album: album, log: { print($0) })
		album = Scanner.loadAlbum(folder: dir, files: Scanner.flacs(in: dir, recursive: true), minCover: 1000)!
		XCTAssertEqual(album.missingTracks(.filenames).count, 0)
		XCTAssertEqual(album.tracks[0].url.lastPathComponent, "01_01_Frost.flac")
		print("status", album.status, album.states)
		print("TMP", tmp.path)
	}
}

final class ID3v1Tests: XCTestCase {
	/// A minimal FLAC (STREAMINFO only, fake audio bytes) with a 128-byte ID3v1 tag appended.
	func make(trailer: Bool) throws -> (URL, Data) {
		let u = FileManager.default.temporaryDirectory.appendingPathComponent("tw-id3-\(UUID().uuidString).flac")
		var d = Data("fLaC".utf8)
		d.append(contentsOf: [0x80, 0, 0, 34]); d.append(Data(count: 34))
		let audio = Data((0..<500).map { UInt8($0 % 251) })
		d.append(audio)
		if trailer { d.append(Data("TAG".utf8)); d.append(Data(count: 125)) }
		try d.write(to: u)
		return (u, audio)
	}

	func testStripsTrailerAndKeepsAudio() throws {
		let (u, audio) = try make(trailer: true); defer { try? FileManager.default.removeItem(at: u) }
		XCTAssertEqual(FlacFile.id3v1Trailer(u), 128)
		XCTAssertEqual(try Pipeline.stripID3v1([u], log: { _ in }), 1)
		XCTAssertEqual(FlacFile.id3v1Trailer(u), 0)
		let out = try Data(contentsOf: u)
		XCTAssertTrue(out.suffix(500) == audio, "audio frames are copied unchanged")
		XCTAssertEqual(try Pipeline.stripID3v1([u], log: { _ in }), 0, "idempotent")
		XCTAssertNoThrow(try FlacFile(url: u))
	}

	func testLeavesCleanFilesAlone() throws {
		let (u, _) = try make(trailer: false); defer { try? FileManager.default.removeItem(at: u) }
		let before = try Data(contentsOf: u)
		XCTAssertEqual(try Pipeline.stripID3v1([u], log: { _ in }), 0)
		XCTAssertEqual(try Data(contentsOf: u), before)
	}
}

extension ID3v1Tests {
	/// TW_ID3FILE=<flac with a trailing ID3v1 tag>: works on a copy; `flac -t` must pass afterwards.
	func testRealFileCopy() throws {
		guard let src = ProcessInfo.processInfo.environment["TW_ID3FILE"] else { throw XCTSkip("set TW_ID3FILE") }
		let u = URL(fileURLWithPath: "/tmp/tw-id3-copy.flac"); try? FileManager.default.removeItem(at: u)
		try FileManager.default.copyItem(at: URL(fileURLWithPath: src), to: u)
		XCTAssertEqual(try Pipeline.stripID3v1([u], log: { print($0) }), 1)
	}
}
