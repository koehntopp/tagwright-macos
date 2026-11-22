import XCTest
@testable import Tagwright

/// Album folders in the library follow layout.py: `Disc N` / `CD N` folders belong to their parent, everything
/// below a disc folder is part of the album, and a disc folder directly in the root is an album of its own.
final class LayoutTests: XCTestCase {
	func testLibraryDiscFolders() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-layout-\(UUID().uuidString)").resolvingSymlinksInPath()
		defer { try? FileManager.default.removeItem(at: root) }
		for p in ["A/Album/Disc 1/01.flac", "A/Album/CD  2/01.flac", "A/Album/cd3/Part/01.flac", "A/Album/Bonus/01.flac",
				  "CD1/01.flac", "A/Single/01.flac", "A/Single/.hidden.flac"] {
			let u = root.appendingPathComponent(p)
			try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data().write(to: u)
		}
		let got = Scanner.albumFolders(root: root, staging: false).map { ($0.0.resolvingSymlinksInPath().path.replacingOccurrences(of: root.path + "/", with: ""), $0.1.count) }
		XCTAssertEqual(got.map(\.0).sorted(), ["A/Album", "A/Album/Bonus", "A/Single", "CD1"])
		XCTAssertEqual(Dictionary(uniqueKeysWithValues: got)["A/Album"], 3, "Disc 1, CD  2 and cd3/Part")
		XCTAssertEqual(Dictionary(uniqueKeysWithValues: got)["A/Single"], 0)
		XCTAssertTrue(Scanner.isDisc("Disc 1") && Scanner.isDisc("CD2") && Scanner.isDisc("disc  3") && !Scanner.isDisc("Disc 1 - Outtakes"))
	}

	/// TW_MULTIDISC=<multi-disc album folder with Disc N subfolders>: linked into a library layout, it must come back
	/// as one album with every track, discs in order.
	func testRealMultiDisc() throws {
		guard let src = ProcessInfo.processInfo.environment["TW_MULTIDISC"] else { throw XCTSkip("set TW_MULTIDISC") }
		let srcURL = URL(fileURLWithPath: src)
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("tw-mdisc-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let album = root.appendingPathComponent("Artist/Album")
		let all = Scanner.flacs(in: srcURL, recursive: true)
		for f in all {
			let disc = f.deletingLastPathComponent().lastPathComponent
			let d = album.appendingPathComponent(Scanner.isDisc(disc) ? disc : "")
			try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
			try FileManager.default.createSymbolicLink(at: d.appendingPathComponent(f.lastPathComponent), withDestinationURL: f)
		}
		let folders = Scanner.albumFolders(root: root, staging: false)
		XCTAssertEqual(folders.count, 1)
		let (dir, discs) = try XCTUnwrap(folders.first)
		let a = try XCTUnwrap(Scanner.loadAlbum(folder: dir, files: Scanner.flacs(in: dir, recursive: false) + discs, minCover: 1000))
		XCTAssertEqual(a.tracks.count, all.count)
		let discNos = a.tracks.map { Int($0.disc) ?? 1 }
		XCTAssertEqual(discNos, discNos.sorted())
		print("MULTIDISC", a.tracks.count, "tracks, discs", Set(discNos).sorted(), "multiDisc", a.multiDisc)
	}
}
