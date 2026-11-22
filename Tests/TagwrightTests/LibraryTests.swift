import XCTest
@testable import Tagwright

final class LibraryTests: XCTestCase {
	let t = LibTemplate.default
	func item(_ path: String, _ tags: [String: String]) -> LibPlanner.Item { .init(path: path, tags: tags) }
	func tags(_ artist: String = "Enya", _ album: String = "Shepherd Moons", _ disc: String = "1", _ no: String = "1", _ title: String = "Shepherd Moons") -> [String: String] {
		["ALBUMARTIST": artist, "ALBUM": album, "DISCNUMBER": disc, "TRACKNUMBER": no, "TITLE": title]
	}

	func tg(disc: String = "1", no: String = "1", title: String = "Shepherd Moons") -> [String: String] { tags("Enya", "Shepherd Moons", disc, no, title) }

	func testDefaultLayoutMatchesBliss() throws {
		let g = try LibTemplate.target(t, tags("Björk", "Vespertine", "1", "3/12", "Hidden Place") .merging(["VERSION": "2001 DR12 CD"]) { $1 })
		XCTAssertEqual(g.albumDir, ["Bjork", "Vespertine_2001_DR12_CD"])
		XCTAssertEqual(g.filename, "01_03_Hidden_Place.flac")
		XCTAssertEqual(g.discDir, "Disc 1")
		// the version is not repeated when the album already contains it
		XCTAssertEqual(try LibTemplate.target(t, tags("A", "B 2001 DR12 CD", "1", "1", "T").merging(["VERSION": "2001 DR12 CD"]) { $1 }).albumDir[1], "B_2001_DR12_CD")
	}

	func testMissingTagAndValidation() {
		XCTAssertThrowsError(try LibTemplate.target(t, tg(title: "")))
		XCTAssertTrue(LibTemplate.validate(t).errors.isEmpty)
		var bad = t; bad.filename = []
		XCTAssertFalse(LibTemplate.validate(bad).errors.isEmpty)
		bad = t; bad.folders[0].append(.init(text: "a/b"))
		XCTAssertFalse(LibTemplate.validate(bad).errors.isEmpty)
		bad = t; bad.filename = [.init(text: "x")]
		XCTAssertTrue(LibTemplate.validate(bad).errors.contains { $0.contains("at least one tag") })
	}

	func testPlanMovesAndInPlace() {
		let p = LibPlanner.plan([item("in/a.flac", tags()), item("Enya/Shepherd_Moons/01_01_Shepherd_Moons.flac", tags())], t)
		XCTAssertEqual(p.inPlace, 1)
		XCTAssertEqual(p.moves.map(\.dst), ["Enya/Shepherd_Moons/01_01_Shepherd_Moons.flac"].filter { _ in false } + [])   // same destination claimed twice: the second is skipped
		XCTAssertEqual(p.moves.count + p.skipped.count, 1)
	}

	func testMultiDiscGetsDiscFolderForAllFiles() {
		let p = LibPlanner.plan([item("x/1.flac", tg(disc: "1", no: "1", title: "A")), item("x/2.flac", tg(disc: "2", no: "1", title: "B"))], t)
		XCTAssertEqual(Set(p.moves.map(\.dst)), ["Enya/Shepherd_Moons/Disc 1/01_01_A.flac", "Enya/Shepherd_Moons/Disc 2/02_01_B.flac"])
		var one = tags(); one["DISCNUMBER"] = "1/2"
		XCTAssertTrue(LibPlanner.isMultiDisc(one))
		XCTAssertFalse(LibPlanner.isMultiDisc(tags()))
	}

	func testExistingDiscFoldersPullSingleDiscFilesIn() {
		let p = LibPlanner.plan([item("x/1.flac", tg(title: "A"))], t, hasDiscDirs: { $0 == ["Enya", "Shepherd_Moons"] })
		XCTAssertEqual(p.moves.first?.dst, "Enya/Shepherd_Moons/Disc 1/01_01_A.flac")
		XCTAssertEqual(LibPlanner.albumDirsWithDiscs(["Enya/Shepherd_Moons/Disc 1/a.flac", "Enya/B/c.flac"]), [["Enya", "Shepherd_Moons"]])
	}

	func testFolderSpellingsDifferingInCaseAreOneFolder() {
		let p = LibPlanner.plan([item("a/1.flac", tags("Enya", "Shepherd Moons", "1", "1", "A")), item("a/2.flac", tags("ENYA", "Shepherd Moons", "1", "2", "B"))], t)
		XCTAssertEqual(p.skipped.count, 1)
		XCTAssertTrue(p.skipped[0].reason.contains("differently"))
	}

	func testUnplaced() {
		let p = LibPlanner.plan([item("a.flac", tg(title: "")), item("b.flac", ["TITLE": "x"])], t)
		XCTAssertEqual(p.unplaced.count, 2)
		XCTAssertTrue(p.moves.isEmpty)
	}

	func testCaseOnlyMove() {
		let p = LibPlanner.plan([item("enya/shepherd_moons/01_01_Shepherd_Moons.flac", tags())], t)
		XCTAssertEqual(p.moves.first?.caseOnly, true)
	}

	// MARK: executor on a real folder

	func tmp() throws -> URL {
		let u = FileManager.default.temporaryDirectory.appendingPathComponent("tw-lib-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
		return u
	}
	func touch(_ u: URL) throws { try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("x".utf8).write(to: u) }

	func testExecutorMovesSidecarsAndPrunes() throws {
		let r = try tmp(); defer { try? FileManager.default.removeItem(at: r) }
		try touch(r.appendingPathComponent("in/a.flac")); try touch(r.appendingPathComponent("in/cover.jpg")); try touch(r.appendingPathComponent("in/.DS_Store"))
		let res = LibExecutor(root: r).run([.init(src: "in/a.flac", dst: "Enya/Moons/01_01_A.flac", caseOnly: false)])
		XCTAssertEqual(res.done.count, 1)
		XCTAssertEqual(res.sidecars, 1)
		XCTAssertTrue(FileManager.default.fileExists(atPath: r.appendingPathComponent("Enya/Moons/cover.jpg").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: r.appendingPathComponent("in").path), "emptied folder (litter aside) is removed")
		XCTAssertTrue(FileManager.default.fileExists(atPath: r.path), "never the root")
	}

	func testExecutorNeverOverwrites() throws {
		let r = try tmp(); defer { try? FileManager.default.removeItem(at: r) }
		try touch(r.appendingPathComponent("in/a.flac")); try touch(r.appendingPathComponent("E/M/a.flac"))
		let res = LibExecutor(root: r).run([.init(src: "in/a.flac", dst: "E/M/a.flac", caseOnly: false)])
		XCTAssertTrue(res.done.isEmpty)
		XCTAssertEqual(res.errors.count, 1)
		XCTAssertTrue(FileManager.default.fileExists(atPath: r.appendingPathComponent("in/a.flac").path))
	}

	func testExecutorRenamesFolderCaseInPlace() throws {
		let r = try tmp(); defer { try? FileManager.default.removeItem(at: r) }
		try touch(r.appendingPathComponent("enya/moons/01_01_A.flac"))
		let res = LibExecutor(root: r).run([.init(src: "enya/moons/01_01_A.flac", dst: "Enya/Moons/01_01_A.flac", caseOnly: true)])
		XCTAssertTrue(res.renamedDirs.contains("enya"), "the folder rename does the move; the index forgets the old tree and lists again")
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: r.path), ["Enya"])
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: r.appendingPathComponent("Enya").path), ["Moons"])
	}

	// MARK: index

	func testIndexRoundTripAndTree() throws {
		let r = try tmp(); defer { try? FileManager.default.removeItem(at: r) }
		let u = r.appendingPathComponent("i.json")
		let ix = LibIndex(url: u); ix.use(root: "/lib")
		ix.setDir("", 1); ix.setDir("A", 2); ix.setDir("A/B", 3)
		ix.upsert("A/B/x.flac", mtime: 5, size: 6, tags: ["ALBUMARTIST": "A"], error: "", changedAt: 7)
		ix.save()
		let again = LibIndex(url: u)
		XCTAssertEqual(again.childDirs("A"), ["A/B"])
		XCTAssertEqual(again.filesIn("A/B")["x.flac"]?.size, 6)
		XCTAssertEqual(again.counts().tracks, 1)
		again.moveFile("A/B/x.flac", "A/C/x.flac")
		XCTAssertEqual(again.items().map(\.path), ["A/C/x.flac"])
		XCTAssertEqual(again.deleteTree("A"), 1)
		XCTAssertTrue(again.childDirs("").isEmpty)
	}
}
