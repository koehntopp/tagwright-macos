import XCTest
@testable import Tagwright

/// ADR 0102: one release track on several discs of the album (Phil Collins, Face Value: one Discogs list per group
/// of mixes, a disc per mix in the album).
final class AssignCopiesTests: XCTestCase {
	let titles = ["In The Air Tonight", "This Must Be Love"]
	let mixes = ["2026 Atmos Mix", "2026 Stereo Mix", "Original 1981 Stereo Mix - 2015 Remaster"]

	func album() -> Album {
		var tracks: [Track] = [], n = 0
		for (d, mix) in mixes.enumerated() {
			for t in titles {
				n += 1
				let tags: Tags = ["TITLE": [t], "DISCNUMBER": ["\(d + 1)"], "TRACKNUMBER": ["\(n)"], "SET SUBTITLE": [mix]]
				tracks.append(Track(url: URL(fileURLWithPath: "/fv/Disc \(d + 1)/\(n).flac"), tags: tags, info: StreamInfo()))
			}
		}
		return Album(url: URL(fileURLWithPath: "/fv"), tracks: tracks, cover: nil)
	}

	var release: [DTrack] {
		(0..<4).map { i in DTrack(id: i, disc: 1, number: i + 1, title: titles[i % 2], artist: "Phil Collins", seconds: 0,
			subtitle: i < 2 ? "2026 Atmos Mix - 2026 Stereo Mix" : "Original 1981 Stereo Mix - 2015 Remaster") }
	}

	func testProposalAndNumbering() {
		let a = album(), asg = Assignment(album: a, tracks: release)
		XCTAssertEqual(asg.files.map { [$0.copy, $0.rel ?? -1] }, [[1, 0], [1, 1], [2, 0], [2, 1], [3, 2], [3, 3]])
		XCTAssertEqual(asg.files.map { [$0.ad, $0.at] }, [[1, 1], [1, 2], [2, 1], [2, 2], [3, 1], [3, 2]])
		XCTAssertFalse(asg.dup); XCTAssertEqual(asg.n, 6)
		XCTAssertEqual(asg.runs(a).runs.map(\.disc), [1, 2, 3], "a divider per disc of the album")
	}

	func testTwiceOnOneDiscIsRefused() {
		var asg = Assignment(album: album(), tracks: release)
		asg.files[1].rel = 0
		XCTAssertTrue(asg.dup); XCTAssertEqual(asg.twice, [asg.files[0].key, asg.files[1].key])
	}

	func testWithoutReuseTheReleaseDiscsStay() {
		var asg = Assignment(album: album(), tracks: [
			DTrack(id: 0, disc: 1, number: 1, title: "A", artist: "", seconds: 0, subtitle: ""),
			DTrack(id: 1, disc: 2, number: 1, title: "B", artist: "", seconds: 0, subtitle: ""),
		])
		for k in asg.files.indices { asg.files[k].rel = nil; asg.files[k].copy = 5 }
		asg.files[0].rel = 0; asg.files[1].rel = 1; asg.number()
		XCTAssertEqual([asg.files[0].ad, asg.files[1].ad], [1, 2])
	}
}
