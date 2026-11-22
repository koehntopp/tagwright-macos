import XCTest
@testable import Tagwright

final class AssignTests: XCTestCase {
	/// Parsed from JSON: a nested [String: Any] literal crashes the test bundle with this toolchain.
	func release() throws -> [String: Any] {
		let json = """
		{"title":"Tunnel of Love","year":1987,"country":"US","artists":[{"name":"Bruce Springsteen","join":""}],
		 "labels":[{"name":"Columbia","catno":"CK 40999"}],"formats":[{"name":"CD","descriptions":["Album"]}],
		 "tracklist":[
		  {"type_":"heading","title":"Disc 1","position":""},
		  {"type_":"track","position":"1-1","title":"Ain't Got You","duration":"2:11"},
		  {"type_":"track","position":"1-2","title":"Tougher Than the Rest","duration":"4:34"},
		  {"type_":"heading","title":"Disc 2","position":""},
		  {"type_":"track","position":"5","title":"Brilliant Disguise","duration":"4:16"},
		  {"type_":"index","position":"","title":"Medley","sub_tracks":[{"position":"2-6.1","title":"A"},{"position":"2-6.2","title":"B"}]}]}
		"""
		return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
	}

	func testTracklist() throws {
		let t = Discogs.tracklist(try release())
		XCTAssertEqual(t.count, 4)
		XCTAssertEqual([t[0].disc, t[0].number, t[1].number], [1, 1, 2])
		XCTAssertEqual([t[2].disc, t[2].number], [2, 5])                       // plain number under a "Disc 2" heading
		XCTAssertEqual([t[3].disc, t[3].number], [2, 6]); XCTAssertEqual(t[3].title, "Medley")  // a medley is one release track
		XCTAssertEqual(t[0].seconds, 131)
	}

	func testPlan() throws {
		let p = Assign.plan(first: ["ALBUM_DR": ["11"], "ALBUM_FORMAT": ["CD"]], release: try release(), masterTitle: "Tunnel of Love", masterYear: nil, maxRate: 96000)
		XCTAssertEqual(p["VERSION"], ["1987 DR11 CD"])   // the catalogue number comes from the files, not the release
		XCTAssertEqual(p["ALBUMARTIST"], ["Bruce Springsteen"])
		XCTAssertEqual(p["ORIGINAL YEAR"], ["1987"])
		XCTAssertEqual(p["ALBUM_MAX_RESOLUTION"], ["96kHz"])
		XCTAssertEqual(p["ALBUM_RELEASE_LABELS"], ["Columbia"])
	}

	func testOverrideWins() throws {
		let p = Assign.plan(first: ["ALBUM_ARTIST_OVERRIDE": ["Springsteen"]], release: try release(), masterTitle: "M", masterYear: 1987, maxRate: 44100)
		XCTAssertEqual(p["ALBUMARTIST"], ["Springsteen"])
	}

	func testSimilarity() {
		XCTAssertGreaterThan(Assign.similarity("Brilliant Disguise", "brilliant disguise"), 0.99)
		XCTAssertLessThan(Assign.similarity("Frost", "Greenhouse"), 0.35)
	}
}
