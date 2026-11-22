import XCTest
@testable import Tagwright

final class LrcTests: XCTestCase {
	func testHeadersRefreshInPlaceAndInsert() {
		let out = Lrc.applyHeaders("[ti:Old]\n[re:x]\n[00:01.00]hi", artist: "A", title: "T", album: "B", length: 125)
		XCTAssertEqual(out, "[ar:A]\n[al:B]\n[length:02:05]\n[ti:T]\n[re:x]\n[00:01.00]hi")
	}
	func testEmptyFreshValueKeepsOldHeader() {
		XCTAssertEqual(Lrc.applyHeaders("[al:Keep]\n[00:01.00]x", artist: "", title: "", album: "", length: 0), "[al:Keep]\n[00:01.00]x")
	}
	func testNormalize() {
		XCTAssertEqual(Lrc.normalizeText("don\u{2019}t\u{200B} \u{201C}go\u{201D} \u{2013} now\u{2026}"), "don't \"go\" - now...")
		XCTAssertEqual(Lrc.normalizeText("don\u{00B4}t"), "don't")
		XCTAssertEqual(Lrc.normalizeText("a \u{00B4} b"), "a \u{00B4} b")
		XCTAssertEqual(Lrc.normalizeLrc("[ti:It\u{2019}s]\n[00:01.00]It\u{2019}s"), "[ti:It\u{2019}s]\n[00:01.00]It's")
	}
	func testCapitalize() {
		XCTAssertEqual(Lrc.capitalizeLrc("[ar:x]\n[00:01.00]  hello"), "[ar:x]\n[00:01.00]Hello")
		XCTAssertEqual(Lrc.capitalizeTxt("  one\ntwo"), "  One\nTwo")
	}
	func testInstrumentalBlock() {
		XCTAssertEqual(Lrc.instrumental(artist: "A", title: "T", album: "B", length: 61), "[ar:A]\n[ti:T]\n[al:B]\n[length:01:01]\n[la:zxx]\n[instrumental:true]\n[00:00.00](Instrumental)")
		XCTAssertTrue(Lrc.hasManualInstrumentalMarker("[00:00.00][Instrumental]"))
		XCTAssertFalse(Lrc.hasManualInstrumentalMarker("[00:00.00][instrumental:true]"))
	}
	func testSuspect() {
		let same = "[00:05.00]a\n[00:05.00]b\n[00:05.00]c"
		XCTAssertEqual(Lrc.suspectReasons(same), ["one_timestamp"])
		XCTAssertEqual(Lrc.problemLineCount(same), 3)
		XCTAssertEqual(Lrc.suspectReasons("[00:01.00]a\n[00:02.00]b\n[00:03.00]\u{2661}c", length: 600), ["ends_early", "junk_hearts"])
		XCTAssertEqual(Lrc.suspectReasons("[00:00.00][instrumental:true]"), [])
	}
	func testSearchParams() {
		let p = Lrc.searchParams(artist: "VA", trackArtist: "X", title: "Song (Live)", album: "Al", duration: "10")
		XCTAssertEqual(p.count, 8)
		XCTAssertEqual(p[2]["track_name"], "Song")
		XCTAssertEqual(p[4]["artist_name"], "X")
	}

	func decide(_ tags: Tags, _ body: [String: Any]?, failed: Bool = false) async -> Lrc.Result {
		await Lrc.decide(tags: tags, length: 100, log: { _ in }) { _ in failed ? .failed : body.map { .found($0) } ?? .notFound }
	}
	let base: Tags = ["ALBUMARTIST": ["A"], "TITLE": ["T"], "ALBUM": ["B"]]

	func testDecisions() async throws {
		var r = await decide(base, nil, failed: true); XCTAssertEqual(r.action, "failed")
		r = await decide(base, nil); XCTAssertEqual(r.action, "skip"); XCTAssertEqual(r.kind, "none")
		r = await decide(base, ["syncedLyrics": "[00:01.123]it\u{2019}s"])
		XCTAssertEqual(r.action, "new"); XCTAssertEqual(r.lyrics, "[ar:A]\n[ti:T]\n[al:B]\n[length:01:40]\n[00:01.12]It's".replacingOccurrences(of: "[ar:A]\n[ti:T]\n[al:B]\n[length:01:40]\n", with: "[ar:A]\n[ti:T]\n[al:B]\n[length:01:40]\n"))
		r = await decide(base, ["plainLyrics": "hello"]); XCTAssertEqual(r.kind, "txt"); XCTAssertEqual(r.lyrics, "Hello")
		r = await decide(base, ["instrumental": true]); XCTAssertEqual(r.kind, "instrumental")
		var t = base; t["LYRICS_LANGUAGE"] = ["zxx"]
		r = await decide(t, nil); XCTAssertEqual(r.kind, "instrumental"); XCTAssertEqual(r.action, "new")
		t = base; t["LYRICS"] = ["[00:01.00]it\u{2019}s fine"]   // existing LRC: fixed in place, never replaced
		r = await decide(t, ["syncedLyrics": "[00:09.00]other"]); XCTAssertEqual(r.action, "fix"); XCTAssertTrue(r.lyrics.contains("[00:01.00]It's fine"))
		t = base; t["LYRICS"] = ["[00:00.00][Instrumental]"]
		r = await decide(t, nil); XCTAssertEqual(r.action, "fix"); XCTAssertTrue(r.lyrics.contains("[instrumental:true]"))
		r = await decide(["TITLE": ["T"]], nil); XCTAssertEqual(r.action, "error")
		r = await decide(base, ["syncedLyrics": "[100:00:01.00]x"]); XCTAssertNotEqual(r.kind, "lrc")
	}
}
