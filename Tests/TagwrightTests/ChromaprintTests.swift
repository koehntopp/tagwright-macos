import XCTest
@testable import Tagwright

final class ChromaprintTests: XCTestCase {
	/// Compression against a fixed vector computed by hand: [1, 3] -> xor 1, 2.
	func testCompressKnownVector() {
		// subfp 1: bit 1 -> value 1, end 0; subfp 3^1=2: bit 2 -> value 2, end 0 -> normal [1,0,2,0], no exceptional
		XCTAssertEqual(Chromaprint.compress([1, 3]), [1, 0, 0, 2, UInt8(0b001 | 0b000 << 3 | 0b010 << 6 & 0xFF), UInt8((0b010 >> 2) | 0b000 << 1)])
	}
	func testExceptionalBits() {
		let c = Chromaprint.compress([1 << 20])   // bit 21 -> 21 >= 7: normal 7, exceptional 14
		XCTAssertEqual(c.count, 4 + 1 + 1)         // 2 normals = 6 bits, 1 exceptional = 5 bits
		XCTAssertEqual(c[4], 0b00_000_111)
		XCTAssertEqual(c[5], 14)
	}
	func testBase64URL() { XCTAssertEqual(Chromaprint.base64url([0xfb, 0xff, 0xfe]), "-__-") }

	/// TW_FPFILE=<flac>: compare with `fpcalc -raw -length 120` (TW_FPCALC overrides the binary).
	func testAgainstFpcalc() throws {
		guard let f = ProcessInfo.processInfo.environment["TW_FPFILE"] else { throw XCTSkip("set TW_FPFILE") }
		let exe = ProcessInfo.processInfo.environment["TW_FPCALC"] ?? "/Applications/fpcalc"
		let p = Process(), pipe = Pipe()
		p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["-raw", "-length", "120", f]; p.standardOutput = pipe
		try p.run(); let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
		let line = out.split(separator: "\n").first { $0.hasPrefix("FINGERPRINT=") }!
		let ref = line.dropFirst(12).split(separator: ",").map { UInt32($0) ?? UInt32(bitPattern: Int32($0)!) }
		let mine = try Chromaprint.raw(url: URL(fileURLWithPath: f))
		var best = Double.infinity
		for shift in -3...3 {   // the resamplers delay the signal differently
			var diff = 0, total = 0
			for i in 0..<min(ref.count, mine.count) { let j = i + shift; guard j >= 0, j < mine.count else { continue }; diff += (ref[i] ^ mine[j]).nonzeroBitCount; total += 32 }
			best = min(best, Double(diff) / Double(max(total, 1)))
		}
		print("fpcalc \(ref.count) items, native \(mine.count) items, bit difference \(String(format: "%.2f", best * 100)) %")
		XCTAssertLessThan(best, 0.05)
	}
}

extension ChromaprintTests {
	/// TW_FPFILE: the encoded string has the same header and length class as fpcalc's.
	func testEncodedAgainstFpcalc() throws {
		guard let f = ProcessInfo.processInfo.environment["TW_FPFILE"] else { throw XCTSkip("set TW_FPFILE") }
		let p = Process(), pipe = Pipe()
		p.executableURL = URL(fileURLWithPath: "/Applications/fpcalc"); p.arguments = ["-json", "-length", "120", f]; p.standardOutput = pipe
		try p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
		let ref = (try JSONSerialization.jsonObject(with: d) as! [String: Any])["fingerprint"] as! String
		let mine = try Chromaprint.fingerprint(url: URL(fileURLWithPath: f))
		print("ref  \(ref.prefix(48)) \(ref.count)\nmine \(mine.prefix(48)) \(mine.count)")
		XCTAssertEqual(String(ref.prefix(8)), String(mine.prefix(8)))
		XCTAssertLessThan(abs(ref.count - mine.count), ref.count / 50)
	}
}
