import XCTest
@testable import Tagwright

/// TW_RSGAIN=<album folder>: native gains and peaks against rsgain run with the web app's preset (replaygain.py) on
/// a copy of the same album.
final class ReplayGainTests: XCTestCase {
	func testMatchesRsgain() throws {
		guard let src = ProcessInfo.processInfo.environment["TW_RSGAIN"] else { throw XCTSkip("set TW_RSGAIN") }
		let rsgain = "/opt/homebrew/bin/rsgain"
		guard FileManager.default.isExecutableFile(atPath: rsgain) else { throw XCTSkip("rsgain not installed") }
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tw-rg-\(UUID().uuidString)")
		try FileManager.default.copyItem(at: URL(fileURLWithPath: src), to: tmp)
		defer { try? FileManager.default.removeItem(at: tmp) }
		let files = Scanner.flacs(in: tmp, recursive: true)
		let native = try Pipeline.replayGainValues(files: files)

		let preset = tmp.appendingPathComponent("preset.ini")
		try "[Global]\nTargetLoudness=-14\nClipMode=a\nMaxPeakLevel=-1.0\nTruePeak=true\nAlbum=true\nTagMode=i\n".write(to: preset, atomically: true, encoding: .utf8)
		let p = Process(); p.executableURL = URL(fileURLWithPath: rsgain); p.arguments = ["easy", "-q", "-p", preset.path, tmp.path]
		try p.run(); p.waitUntilExit()
		XCTAssertEqual(p.terminationStatus, 0)

		func db(_ s: String) -> Double { Double(s.replacingOccurrences(of: " dB", with: "")) ?? .nan }
		for (i, f) in files.enumerated() {
			let t = try AudioFile(url: f).tags
			let g = db(t.first("REPLAYGAIN_TRACK_GAIN")), pk = Double(t.first("REPLAYGAIN_TRACK_PEAK")) ?? .nan
			print(String(format: "%@  gain %+.2f / rsgain %+.2f   peak %.6f / rsgain %.6f", f.lastPathComponent, native.tracks[i].gain, g, native.tracks[i].peak, pk))
			XCTAssertEqual(native.tracks[i].gain, g, accuracy: 0.02, f.lastPathComponent)
			XCTAssertEqual(native.tracks[i].peak, pk, accuracy: 0.002, f.lastPathComponent)
		}
		let t0 = try AudioFile(url: files[0]).tags
		print(String(format: "album gain %+.2f / rsgain %@   peak %.6f / rsgain %@", native.albumGain, t0.first("REPLAYGAIN_ALBUM_GAIN"), native.albumPeak, t0.first("REPLAYGAIN_ALBUM_PEAK")))
		XCTAssertEqual(native.albumGain, db(t0.first("REPLAYGAIN_ALBUM_GAIN")), accuracy: 0.02)
		XCTAssertEqual(native.albumPeak, Double(t0.first("REPLAYGAIN_ALBUM_PEAK")) ?? .nan, accuracy: 0.002)
	}
}
