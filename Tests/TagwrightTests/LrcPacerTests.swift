import XCTest
@testable import Tagwright

/// lrclib.py Pacer: spacing, 429 slow-down and recovery, circuit breaker.
final class LrcPacerTests: XCTestCase {
	func testSpacingAndRateLimit() async {
		let p = LrcPacer()
		let a = await p.acquire(); await p.release()
		let b = await p.acquire(); await p.release()
		XCTAssertGreaterThanOrEqual(b.timeIntervalSince(a), 0.5, "the next request starts at least 0.5 s later")
		await p.failure(startedAt: Date(), retryAfter: nil, rateLimited: true)
		let doubled = await p.currentInterval
		XCTAssertEqual(doubled, 1)
		for _ in 0..<10 { await p.success() }
		let relaxed = await p.currentInterval
		XCTAssertEqual(relaxed, 0.75, "ten successes shrink it again")
		for _ in 0..<5 { await p.failure(startedAt: .distantPast, retryAfter: nil, rateLimited: false) }
		let down = await p.isDown
		XCTAssertFalse(down, "five failures open the circuit only after 60 s without a success")
		await p.rejectCredentials()
		let rejected = await p.isDown
		XCTAssertTrue(rejected)
		await p.closeCircuit()
		let closed = await p.isDown
		XCTAssertFalse(closed)
	}

	func testLiveLookup() async throws {
		guard ProcessInfo.processInfo.environment["TW_NET"] != nil else { throw XCTSkip("TW_NET not set") }
		guard case .found(let j) = await Lrc.get(LrcPacer(), ["artist_name": "Chicago", "track_name": "Stay the Night"]) else { return XCTFail("not found") }
		XCTAssertFalse((j["plainLyrics"] as? String ?? "").isEmpty)
	}
}
