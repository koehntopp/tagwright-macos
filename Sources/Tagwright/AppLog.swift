import Foundation
import os

/// pipeline/logconfig.py (ADR 0064-0066) on the Mac: the program's own lines (`app`, `pipeline`, `library`) go to
/// the unified log (Console, subsystem com.koehntopp.tagwright) and to ~/Library/Logs/Tagwright/tagwright.log, with a
/// timestamp, the logger name and the level. They hold album folders, file names and tag text, never a key.
/// The level is the `logLevel` default (DEBUG, INFO, WARNING, ERROR; INFO when unset), like LOG_LEVEL.
enum AppLog {
	enum Level: Int, Comparable { case debug, info, warning, error
		static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
		var name: String { ["DEBUG", "INFO", "WARNING", "ERROR"][rawValue] }
	}
	static let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Tagwright/tagwright.log")
	private static let queue = DispatchQueue(label: "tagwright.log")
	private static let loggers = ["app", "pipeline", "library"].reduce(into: [String: Logger]()) { $0[$1] = Logger(subsystem: "com.koehntopp.tagwright", category: $1) }
	static var level: Level {
		switch (UserDefaults.standard.string(forKey: "logLevel") ?? "INFO").uppercased() { case "DEBUG": .debug; case "WARNING": .warning; case "ERROR": .error; default: .info }
	}

	static func log(_ name: String, _ lv: Level, _ msg: String) {
		guard lv >= level else { return }
		let l = loggers[name] ?? loggers["app"]!
		switch lv { case .debug: l.debug("\(msg, privacy: .public)"); case .info: l.info("\(msg, privacy: .public)"); case .warning: l.warning("\(msg, privacy: .public)"); case .error: l.error("\(msg, privacy: .public)") }
		let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"   // local time, as the container logs with TZ
		let line = "\(f.string(from: Date())) \(lv.name) \(name): \(msg)\n"
		queue.async {
			if !FileManager.default.fileExists(atPath: file.path) {
				try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
				FileManager.default.createFile(atPath: file.path, contents: nil)
			}
			guard let h = try? FileHandle(forWritingTo: file) else { return }
			defer { try? h.close() }
			_ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8))
		}
	}
	static func app(_ m: String, _ lv: Level = .info) { log("app", lv, m) }
	static func pipeline(_ m: String, _ lv: Level = .info) { log("pipeline", lv, m) }
	static func library(_ m: String, _ lv: Level = .info) { log("library", lv, m) }
}
