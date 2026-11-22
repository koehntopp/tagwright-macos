import XCTest
@testable import Tagwright

/// Algorithm check against other tools on real files (read-only): TW_VERIFY_IN is a JSON file
/// {"files": [...], "albums": [[...]]}, TW_VERIFY_OUT the JSON this writes (compared by scratchpad/verify/compare.py).
final class VerifyTests: XCTestCase {
	func testVerify() throws {
		let env = ProcessInfo.processInfo.environment
		guard let inp = env["TW_VERIFY_IN"], let outp = env["TW_VERIFY_OUT"] else { throw XCTSkip("set TW_VERIFY_IN and TW_VERIFY_OUT") }
		let j = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: inp))) as! [String: Any]
		let files = j["files"] as! [String], albums = j["albums"] as! [[String]]
		var out: [String: Any] = [:]
		let q = DispatchQueue(label: "r"), lock = NSLock()
		var fres: [String: Any] = [:]
		DispatchQueue.concurrentPerform(iterations: files.count) { i in
			let u = URL(fileURLWithPath: files[i])
			var r: [String: Any] = [:]
			do {
				r["dr_score"] = try Pipeline.measureDRValue(u)
				let g = try Pipeline.replayGainValues(files: [u])
				r["gain"] = g.tracks[0].gain; r["peak"] = g.tracks[0].peak
				r["fp"] = try Chromaprint.raw(url: u).map { Int($0) }
			} catch { r["error"] = "\(error)" }
			lock.lock(); fres[files[i]] = r; lock.unlock()
		}
		_ = q
		out["files"] = fres
		var ares: [[String: Any]] = []
		for a in albums {
			let urls = a.map { URL(fileURLWithPath: $0) }
			var tracks: [String: Int] = [:]
			for (p, u) in zip(a, urls) { tracks[p] = (try? Pipeline.measureDR(u)) ?? 0 }
			let g = try Pipeline.replayGainValues(files: urls)
			ares.append(["files": a, "dr": Pipeline.albumDR(Array(tracks.values)), "tracks": tracks, "album_gain": g.albumGain, "album_peak": g.albumPeak, "gains": g.tracks.map { $0.gain }])
		}
		out["albums"] = ares
		try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: outp))
	}
}
