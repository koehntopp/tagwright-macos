import XCTest
@testable import Tagwright

/// ADR 0059: MP3 behind the FLAC surface. Fixtures: v23.mp3 (ffmpeg, ID3v2.3: TIT2, TPE1, TALB, TYER, TRCK 3/12,
/// TPOS 1/2, TXXX:DISCOGS_RELEASE_ID, TXXX:MusicBrainz Album Id, APIC 64x48), vbr.mp3 (LAME VBR, Xing, 5 s mono 48 kHz).
final class Mp3Tests: XCTestCase {
	let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

	func copy(_ name: String) throws -> URL {
		let u = FileManager.default.temporaryDirectory.appendingPathComponent("tw-mp3-\(UUID().uuidString).mp3")
		try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: u)
		addTeardownBlock { try? FileManager.default.removeItem(at: u) }
		return u
	}

	func testReadsID3v23() throws {
		let f = try AudioFile(url: copy("v23.mp3"))
		let t = f.tags
		XCTAssertEqual(t.first("TITLE"), "Stay The Night")
		XCTAssertEqual(t.first("ARTIST"), "Chicago")
		XCTAssertEqual(t.first("ALBUM"), "Chicago 17")
		XCTAssertEqual(t.first("TRACKNUMBER"), "3"); XCTAssertEqual(t.first("TRACKTOTAL"), "12"); XCTAssertEqual(t.first("TOTALTRACKS"), "12")
		XCTAssertEqual(t.first("DISCNUMBER"), "1"); XCTAssertEqual(t.first("DISCTOTAL"), "2")
		XCTAssertEqual(t.first("DATE"), "1984")
		XCTAssertEqual(t.first("DISCOGS_RELEASE_ID"), "9886890")
		XCTAssertEqual(t.first("MUSICBRAINZ ALBUM ID"), "abc-123", "a TXXX description in any case is a key")
		XCTAssertEqual(f.pictures.count, 1)
		XCTAssertEqual(f.pictures.first.map { [Int($0.width), Int($0.height)] }, [64, 48], "picture size is measured")
		XCTAssertEqual(f.info.sampleRate, 44100); XCTAssertEqual(f.info.channels, 2); XCTAssertEqual(f.info.bits, 0)
		XCTAssertEqual(f.info.duration, 3.03, accuracy: 0.1)
	}

	func testVBRLengthFromXing() throws {
		let f = try AudioFile(url: copy("vbr.mp3"))
		XCTAssertEqual(f.info.sampleRate, 48000); XCTAssertEqual(f.info.channels, 1)
		XCTAssertEqual(f.info.duration, 5.04, accuracy: 0.06)
	}

	/// Writes ID3v2.4 with several values per frame; the audio is copied byte for byte; mutagen reads it back.
	func testRoundTripV24() throws {
		let u = try copy("v23.mp3")
		let audioBefore = try audio(u)
		var f = try AudioFile(url: u)
		var t = f.tags
		t["GENRE"] = ["R&B/Soul", "Pop"]
		t["LABEL"] = ["Warner Bros."]
		t["TRACKNUMBER"] = ["4"]
		t["LYRICS"] = ["[00:01.00] Stay the night\n[00:05.00] There's room enough"]
		t["DYNAMIC_RANGE"] = ["11"]
		t["REPLAYGAIN_ALBUM_GAIN"] = ["-3.20 dB"]
		t["ALBUM_ARTIST_OVERRIDE"] = ["Chicago"]
		t["DISCOGS_RELEASE_ID"] = nil
		f.tags = t
		f.pictures.append(Picture(type: 4, mime: "image/jpeg", desc: "", width: 64, height: 48, data: f.pictures[0].data))
		try f.save()

		let g = try AudioFile(url: u)
		XCTAssertEqual(g.tags["GENRE"], ["R&B/Soul", "Pop"], "multi-valued, no separator splitting")
		XCTAssertEqual(g.tags.first("TRACKNUMBER"), "4"); XCTAssertEqual(g.tags.first("TRACKTOTAL"), "12", "the total half of TRCK is kept")
		XCTAssertEqual(g.tags.first("LYRICS"), t.first("LYRICS"))
		XCTAssertEqual(g.tags.first("DYNAMIC_RANGE"), "11")
		XCTAssertNil(g.tags["DISCOGS_RELEASE_ID"])
		XCTAssertEqual(g.tags.first("MUSICBRAINZ ALBUM ID"), "abc-123")
		XCTAssertEqual(g.pictures.map(\.type), [3, 4])
		XCTAssertEqual(try audio(u), audioBefore, "audio frames unchanged")

		guard let py = mutagenPython() else { throw XCTSkip("mutagen not available for the cross-check") }
		let out = try run(py, ["-c", """
		import sys, mutagen.mp3 as m
		a = m.MP3(sys.argv[1]); t = a.tags
		print(t.version)
		print(t['TCON'].text); print(t['TPUB'].text); print(t['TRCK'].text)
		print(t['TXXX:DYNAMIC_RANGE'].text, t['TXXX:REPLAYGAIN_ALBUM_GAIN'].text, t['TXXX:MusicBrainz Album Id'].text)
		print(t.getall('USLT')[0].text.splitlines()[0]); print(sorted(int(p.type) for p in t.getall('APIC'))); print(round(a.info.length, 1))
		""", u.path])
		XCTAssertEqual(out.split(separator: "\n").map(String.init), [
			"(2, 4, 0)", "['R&B/Soul', 'Pop']", "['Warner Bros.']", "['4/12']",
			"['11'] ['-3.20 dB'] ['abc-123']", "[00:01.00] Stay the night", "[3, 4]", "3.0",
		])
	}

	func testPipelineDecodesMP3() throws {
		let u = try copy("v23.mp3")
		try Pipeline.replayGain(files: [u], log: { _ in })   // decodes the whole stream (DR needs 12 s, the fixture has 3)
		XCTAssertFalse(try AudioFile(url: u).tags.first("REPLAYGAIN_ALBUM_GAIN").isEmpty)
		XCTAssertFalse(try Chromaprint.fingerprint(url: u).isEmpty)
		XCTAssertEqual(try Pipeline.stripID3v1([u], log: { _ in }), 0, "the FLAC ID3v1 fix leaves MP3 alone")
	}

	/// ADR 0076: as `rsgain easy`, every folder is one album, so each disc folder gets its own album gain.
	func testAlbumGainPerDiscFolder() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-discs-\(UUID().uuidString)")
		addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
		var files: [URL] = []
		for (disc, name) in [("Disc 1", "v23.mp3"), ("Disc 2", "vbr.mp3")] {
			let d = dir.appendingPathComponent(disc)
			try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
			try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: d.appendingPathComponent(name))
			files.append(d.appendingPathComponent(name))
		}
		try Pipeline.replayGain(files: files, log: { _ in })
		let tags = try files.map { try AudioFile(url: $0).tags }
		for t in tags { XCTAssertEqual(t.first("REPLAYGAIN_ALBUM_GAIN"), t.first("REPLAYGAIN_TRACK_GAIN"), "a one-track disc: album gain = track gain") }
		XCTAssertNotEqual(tags[0].first("REPLAYGAIN_ALBUM_GAIN"), tags[1].first("REPLAYGAIN_ALBUM_GAIN"))
	}

	func testNamesKeepTheExtension() throws {
		let u = try copy("v23.mp3")
		let dir = u.deletingLastPathComponent().appendingPathComponent("tw-album-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
		let f = dir.appendingPathComponent("x.MP3"); try FileManager.default.moveItem(at: u, to: f)
		XCTAssertEqual(Scanner.flacs(in: dir, recursive: false).map(\.lastPathComponent), ["x.MP3"])
		let a = try XCTUnwrap(Scanner.loadAlbum(folder: dir, files: [f], minCover: 0))
		XCTAssertEqual(a.tracks[0].formatLabel, "44.1", "no bit depth for MP3")
		try Pipeline.rename(album: a, log: { _ in })
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["01_03_Stay_The_Night.mp3"])
	}

	/// TW_MP3=<folder>: every MP3 below it, on a copy: our reading matches mutagen's; a rewrite keeps the audio and
	/// stays readable by mutagen.
	func testRealFiles() throws {
		guard let dir = ProcessInfo.processInfo.environment["TW_MP3"] else { throw XCTSkip("set TW_MP3") }
		guard let py = mutagenPython() else { throw XCTSkip("mutagen not available") }
		let files = FileManager.default.enumerator(atPath: dir)!.compactMap { $0 as? String }.filter { $0.lowercased().hasSuffix(".mp3") }.prefix(40)
		XCTAssertFalse(files.isEmpty)
		for rel in files {
			let u = FileManager.default.temporaryDirectory.appendingPathComponent("tw-real-\(UUID().uuidString).mp3")
			try FileManager.default.copyItem(atPath: dir + "/" + rel, toPath: u.path)
			defer { try? FileManager.default.removeItem(at: u) }
			let script = """
			import sys, mutagen.mp3 as m
			a = m.MP3(sys.argv[1]); t = a.tags or {}
			g = lambda k: str(t[k].text[0]) if k in t and t[k].text else ''
			print('|'.join([g('TIT2'), g('TPE1'), g('TALB'), g('TRCK').split('/')[0], str(round(a.info.length)), str(a.info.sample_rate), str(len(t.getall('APIC')) if t else 0)]))
			"""
			let want = try run(py, ["-c", script, u.path])
			var f = try AudioFile(url: u)
			let t = f.tags
			let got = [t.first("TITLE"), t.first("ARTIST"), t.first("ALBUM"), t.first("TRACKNUMBER"), "\(Int(f.info.duration.rounded()))", "\(f.info.sampleRate)", "\(f.pictures.count)"].joined(separator: "|")
			XCTAssertEqual(got, want, rel)
			let before = try audio(u)
			var t2 = t; t2["DYNAMIC_RANGE"] = ["9"]; f.tags = t2
			try f.save()
			XCTAssertEqual(try audio(u), before, "audio unchanged: \(rel)")
			XCTAssertEqual(try run(py, ["-c", script, u.path]), want, "mutagen reads the rewrite: \(rel)")
			print("OK", rel, got)
		}
	}

	// MARK: helpers

	func audio(_ u: URL) throws -> Data {
		let d = try Data(contentsOf: u)
		let b = [UInt8](d.prefix(10))
		let size = Mp3File.syncsafe(b[6...9]) + 10
		return d.dropFirst(size)
	}
	func mutagenPython() -> String? {
		let p = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../tagwright/.venv/bin/python").standardized.path
		return FileManager.default.isExecutableFile(atPath: p) ? p : nil
	}
	func run(_ exe: String, _ args: [String]) throws -> String {
		let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
		let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
		try p.run(); p.waitUntilExit()
		return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
