import XCTest
@testable import Tagwright

/// Live MusicBrainz check, only with TW_NET=1 (no key needed).
final class NetworkTests: XCTestCase {
	func testMusicBrainzSearch() async throws {
		guard ProcessInfo.processInfo.environment["TW_NET"] != nil else { throw XCTSkip("TW_NET not set") }
		let hits = try await MusicBrainz.search(query: "Yes 90125", discogsID: "", barcode: "075679012524", catno: "")
		print("hits", hits.count, hits.first.map { "\($0.artist) - \($0.title) \($0.match) \($0.tracks)" } ?? "")
		XCTAssertFalse(hits.isEmpty)
		let d = try await MusicBrainz.detail(try XCTUnwrap(hits.first).id)
		print("tracks", d.tracks.count, d.tracks.first?.title ?? "")
		XCTAssertEqual(d.tracks.count, 9)
	}
}
