import XCTest
@testable import Tagwright

/// TW_LIBRARY=<library root> (TW_STAGING=1: a staging root): cold vs warm load of every album with a scratch summary store.
final class SummariesTiming: XCTestCase {
	func testColdWarm() throws {
		guard let p = ProcessInfo.processInfo.environment["TW_LIBRARY"] else { throw XCTSkip("set TW_LIBRARY") }
		let root = URL(fileURLWithPath: p), staging = ProcessInfo.processInfo.environment["TW_STAGING"] == "1"
		let store = FileManager.default.temporaryDirectory.appendingPathComponent("tw-sum-\(UUID().uuidString).plist")
		defer { if ProcessInfo.processInfo.environment["TW_KEEP"] == nil { try? FileManager.default.removeItem(at: store) } else { print("STORE", store.path) } }
		func pass(_ s: Summaries) -> (Int, Double) {
			let t = Date(); var hits = 0
			for (dir, extra) in Scanner.albumFolders(root: root, staging: staging) {
				let files = staging ? extra : Scanner.flacs(in: dir, recursive: false) + extra
				let sig = Summaries.signature(folder: dir, files: files)
				if s.album(folder: dir, sig: sig, minCover: 1000) != nil { hits += 1; continue }
				if let a = Scanner.loadAlbum(folder: dir, files: files, minCover: 1000) { s.put(a, sig: sig) }
			}
			s.save()
			return (hits, Date().timeIntervalSince(t))
		}
		let cold = pass(Summaries(url: store)), warm = pass(Summaries(url: store))
		let size = (try? FileManager.default.attributesOfItem(atPath: store.path)[.size] as? Int) ?? 0
		print("TIMING cold \(cold) warm \(warm) store \(size / 1024) KiB")
		XCTAssertEqual(cold.0, 0); XCTAssertGreaterThan(warm.0, 0)
	}
}
