import XCTest

/// Sync layer 2: warns (as a skip with a message, never a failure) when the web app has changes the port does not
/// have yet. `scripts/sync-check` lists them.
final class SyncTests: XCTestCase {
	func testWebChangesPorted() throws {
		let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
		let p = Process(); p.executableURL = root.appendingPathComponent("scripts/sync-check"); p.arguments = ["--count"]
		let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
		try p.run(); p.waitUntilExit()
		guard p.terminationStatus == 0, let n = Int(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
			throw XCTSkip("no web repository next to this one")
		}
		if n > 0 { throw XCTSkip("WARNING: the web app has \(n) changed file(s) not yet in the macOS port: run scripts/sync-check") }
	}
}
