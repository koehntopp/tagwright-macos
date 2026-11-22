import XCTest
@testable import Tagwright

/// The web app is the reference (sync layer 3): each test sends cases to scripts/web-oracle.py, which runs the web
/// app's own functions, and compares the native answer. A change of behaviour in the web app fails here until the
/// port follows. Skipped when ../tagwright or its .venv is missing.
final class WebParityTests: XCTestCase {
	static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
	static let python = root.appendingPathComponent("../tagwright/.venv/bin/python").standardized.path

	func web(_ fn: String, _ cases: [Any]) throws -> [Any] {
		guard FileManager.default.isExecutableFile(atPath: Self.python) else { throw XCTSkip("the web app and its .venv are not next to this repo") }
		let p = Process(); p.executableURL = URL(fileURLWithPath: Self.python)
		p.arguments = [Self.root.appendingPathComponent("scripts/web-oracle.py").path]
		let inp = Pipe(), out = Pipe(), err = Pipe()
		p.standardInput = inp; p.standardOutput = out; p.standardError = err
		try p.run()
		inp.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: ["fn": fn, "cases": cases]))
		try inp.fileHandleForWriting.close()
		let data = out.fileHandleForReading.readDataToEndOfFile()
		p.waitUntilExit()
		guard p.terminationStatus == 0 else { throw StepError("web-oracle \(fn): " + String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
		return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
	}

	static let titles = ["Stay The Night", "We Can Stop The Hurtin'", "Héllo / Wörld?", "AC/DC: Live (2003 Remaster) [Bonus]", "Ça ira — part 2", "日本語のタイトル",
		"Rock'n'Roll Ain't Noise Pollution", "...And Justice for All", "  spaces  ", "Smörgåsbord & Ångström", "Track #1 (feat. Someone)", String(repeating: "Very Long Title ", count: 30), "Ænima", "Öl", "ß"]

	func testNaming() throws {
		let names = Self.titles.enumerated().map { i, t in ["TITLE": [t], "TRACKNUMBER": ["\(i + 1)/\(Self.titles.count)"], "DISCNUMBER": [i % 3 == 0 ? "2" : "1"]] as Tags }
			+ [["TITLE": ["x"], "TRACKNUMBER": ["1"]], ["TITLE": [""], "TRACKNUMBER": ["1"], "DISCNUMBER": ["1"]]]
		for (c, w) in zip(names, try web("bliss_name", names)) { XCTAssertEqual(Naming.blissName(c), w as? String, "bliss_name \(c)") }
		for (c, w) in zip(Self.titles, try web("clean", Self.titles)) { XCTAssertEqual(Naming.clean(c), w as? String, "clean \(c)") }
		let albums: [Tags] = [["ALBUM": ["Chicago 17"], "ALBUMARTIST": ["Chicago"], "VERSION": ["1984 DR13 CD (9 25060-2)"]], ["ALBUM": ["Out Of The Blue"], "ALBUMARTIST": ["Electric Light Orchestra"]],
			["ALBUM": ["Hits 1984 DR13 CD"], "ALBUMARTIST": ["Wham!"], "VERSION": ["1984 DR13 CD"]], ["ALBUM": ["x"]], ["ALBUM": ["Björk's Homogenic"], "ALBUMARTIST": ["Björk"]]]
		for (c, w) in zip(albums, try web("bliss_album", albums)) { XCTAssertEqual(Naming.blissAlbum(c) ?? "", w as? String, "bliss_album \(c)") }
		let versions: [[Any]] = [[1984, "13", "CD", "", "9 25060-2"], [0, "", "Vinyl", "Remastered", "none"], [2007, "8", "SACD", "Limited Edition", ""], [1999, "", "", "", ""]]
		for (c, w) in zip(versions, try web("version_string", versions)) {
			XCTAssertEqual(Naming.versionString(year: "\(c[0])" == "0" ? "" : "\(c[0])", dr: c[1] as! String, format: c[2] as! String, edition: c[3] as! String, catalog: c[4] as! String), w as? String, "version_string \(c)")
		}
	}

	func testLyricKind() throws {
		let cases: [Tags] = [["LYRICS": ["[00:01.00] hi\n[00:02.00] there"]], ["LYRICS": ["just text"]], ["LYRICS": ["[instrumental:true]"]], ["LYRICS": ["[00:00.00] [Instrumental]"]],
			["LYRICS_LANGUAGE": ["zxx"]], [:], ["LYRICS": ["[0:01.00] loose timestamp"]], ["LYRICS": ["  "]], ["LYRICS": ["[00:00.00](Spoken Intro)"]], ["UNSYNCEDLYRICS": ["plain in the other key"]]]
		let name: [LyricsKind: String] = [.lrc: "lrc", .txt: "txt", .instr: "instr", .none: "none"]
		for (c, w) in zip(cases, try web("lyric_kind", cases)) {
			XCTAssertEqual(name[Track(url: URL(fileURLWithPath: "/x.flac"), tags: c, info: StreamInfo()).lyricsKind], w as? String, "lyric_kind \(c)")
		}
	}

	func testAlbumIssues() throws {
		let full: Tags = ["DISCOGS_RELEASE_ID": ["1"], "ALBUMARTIST": ["A"], "CATALOGNUMBER": ["X1"], "ALBUM_FORMAT": ["CD"], "DISCNUMBER": ["1"], "TITLE": ["t"], "ARTIST": ["a"]]
		func with(_ t: Tags, _ k: String, _ v: [String]?) -> Tags { var x = t; x[k] = v; return x }
		let sets: [([Tags], (Int, Int)?, Int)] = [
			([["TITLE": ["a"]], [:]], nil, 1400),
			([with(full, "TRACKNUMBER", ["1"]), with(full, "TRACKNUMBER", ["2"])], (1500, 1500), 1400),
			([with(full, "TRACKNUMBER", ["1"]), with(with(full, "TRACKNUMBER", ["1"]), "ALBUMARTIST", ["B"])], (599, 595), 1400),
			([with(with(full, "TRACKNUMBER", ["1"]), "ALBUM_EDITION", ["Gold"]), with(full, "TRACKNUMBER", ["2"])], nil, 0),
			([with(with(full, "TRACKNUMBER", ["1"]), "CATALOGNUMBER", nil), with(with(with(full, "TRACKNUMBER", ["2"]), "ARTIST", nil), "CATALOGNUMBER", nil)], (1400, 1399), 1400),
			([with(with(full, "TRACKNUMBER", ["3"]), "DISCOGS_RELEASE_ID", nil), with(full, "TRACKNUMBER", ["4"])], (2000, 2000), 1400),
		]
		let cases: [[String: Any]] = sets.map { tags, cov, min in
			["tags": tags, "small_cover": min > 0 && (cov == nil || cov!.0 < min || cov!.1 < min), "cover": cov.map { ["w": $0.0, "h": $0.1] } ?? NSNull(), "min_cover": min]
		}
		let lv: [Issue.Level: String] = [.error: "error", .warn: "warn", .ingest: "ingest", .info: "info"]
		for ((tags, cov, min), w) in zip(sets, try web("album_issues", cases)) {
			var a = Album(url: URL(fileURLWithPath: "/a"), tracks: tags.map { Track(url: URL(fileURLWithPath: "/a/x.flac"), tags: $0, info: StreamInfo()) },
				cover: cov.map { Cover(width: $0.0, height: $0.1, data: Data(), embedded: true) })
			a.minCover = min
			let want = (w as? [[String: String]] ?? []).map { "\($0["level"]!)|\($0["action"]!)|\($0["text"]!)" }
			XCTAssertEqual(a.issues.map { "\(lv[$0.level]!)|\($0.action)|\($0.text)" }, want, "album_issues \(tags)")
		}
	}

	func testLibraryTemplate() throws {
		let base = ["ALBUMARTIST": "Chicago", "ALBUM": "Chicago 17", "VERSION": "1984 DR13 CD (9 25060-2)", "DISCNUMBER": "1", "TRACKNUMBER": "3", "TITLE": "Hard Habit To Break"]
		func with(_ k: String, _ v: String?) -> [String: String] { var x = base; x[k] = v; return x }
		let cases: [([String: String], String)] = [(base, ".flac"), (with("DISCNUMBER", "2/2"), ".mp3"), (with("ALBUMARTIST", nil), ".flac"), (with("TITLE", "???"), ".flac"),
			(with("ALBUM", "Out Of The Blue 1984 DR13 CD (9 25060-2)"), ".flac"), (with("TRACKNUMBER", "12/14"), ".flac"), (with("TITLE", "Ça ira / Ångström"), ".flac")]
		let w = try web("template_target", cases.map { ["tags": $0.0, "suffix": $0.1] })
		for ((tags, suffix), want) in zip(cases, w) {
			let want = want as? [String: Any] ?? [:]
			do {
				let t = try LibTemplate.target(LibTemplate.default, tags, suffix: suffix)
				XCTAssertEqual(t.albumDir, want["album_dir"] as? [String], "album_dir \(tags)")
				XCTAssertEqual(t.discDir, want["disc_dir"] as? String, "disc_dir \(tags)")
				XCTAssertEqual(t.filename, want["filename"] as? String, "filename \(tags)")
			} catch is LibTemplate.MissingTag { XCTAssertEqual(want["error"] as? String, "MissingTag", "\(tags)")
			} catch { XCTAssertEqual(want["error"] as? String, "ValueError", "\(tags): \(error)") }
		}
	}

	func testLyricsDecisions() async throws {
		let lrc = "[00:01.00] i don't want you\n[00:05.00] to misunderstand me"
		let found: [String: Any] = ["syncedLyrics": lrc, "plainLyrics": "i don't want you\nto misunderstand me", "duration": 200, "instrumental": false]
		let base: Tags = ["ALBUMARTIST": ["Chicago"], "TITLE": ["Stay The Night"], "ALBUM": ["Chicago 17"]]
		func with(_ k: String, _ v: [String]?) -> Tags { var x = base; x[k] = v; return x }
		let cases: [(Tags, [Any])] = [
			(base, [found]),
			(base, [["plainLyrics": "plain only", "duration": 200]]),
			(base, [[String: Any](), [String: Any](), [String: Any](), [String: Any]()]),
			(base, [NSNull()]),
			(base, [["instrumental": true, "duration": 200]]),
			(with("TITLE", ["Stay The Night (Remastered)"]), [[String: Any](), [String: Any](), found]),
			(with("ALBUMARTIST", ["Various Artists"]).merging(["ARTIST": ["Chicago"]]) { $1 }, [[String: Any](), [String: Any](), found]),
			(with("LYRICS", ["[00:01.00] already synced"]), []),
			(with("LYRICS", ["plain text already"]), [found]),
			(with("LYRICS_LANGUAGE", ["zxx"]), []),
			(with("ALBUMARTIST", nil), [found]),
		]
		let w = try web("lyrics_fetch", cases.map { ["tags": $0.0, "length": 200.0, "answers": $0.1] as [String: Any] })
		for ((tags, answers), want) in zip(cases, w) {
			let want = want as? [String: Any] ?? [:]
			var left = answers, calls = 0
			let r = await Lrc.decide(tags: tags, length: 200, log: { _ in }) { _ in
				calls += 1
				guard !left.isEmpty else { return .notFound }
				let a = left.removeFirst()
				if a is NSNull { return .failed }
				let d = a as? [String: Any] ?? [:]
				return d.isEmpty ? .notFound : .found(d)
			}
			XCTAssertEqual(r.action, want["action"] as? String, "action \(tags)")
			XCTAssertEqual(r.kind, want["kind"] as? String, "kind \(tags)")
			XCTAssertEqual(r.lyrics, want["lyrics"] as? String, "lyrics \(tags)")
			XCTAssertEqual(calls, want["calls"] as? Int, "lookups \(tags)")
		}
	}

	func testReleaseTags() throws {
		for id in ["9886890", "1524544"] {
			let json = Self.root.appendingPathComponent("Tests/TagwrightTests/Fixtures/discogs/\(id).json")
			let r = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
			let w = try XCTUnwrap(try web("release_tags", [json.path]).first as? [String: [String: [String]]])
			XCTAssertEqual(Discogs.discogsTags(r), w["discogs"], "DISCOGS_* of \(id)")
			var player = Discogs.playerTags(r); player["COMPOSER"] = nil   // the web app keeps the writers apart
			XCTAssertEqual(player, w["player"], "player tags of \(id)")
		}
	}
}
