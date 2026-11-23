import Foundation

/// Port of pipeline/positions.py (ADR 0053, 0101): disc and track from Discogs positions, read in tracklist order.
/// `D-T`/`D.T` with or without a media label (`CD2-3`, `SACD1-4`, `BD1-2`); a label without a disc number (`SACD-1`,
/// `CD-1`, `DVD-1`) is on the disc of the last heading that names one, else every new label is the next disc; plain
/// numbers restart under a disc heading. Vinyl sides (`A1`), plain numbers without a heading and empty positions
/// give nil.
struct Positions {
	/// A heading that names a disc: `Disc 2`, `CD 2`, `SACD 1`, `BD 1`, `Blu-ray 1`, `Disk 3`.
	static let discHeading = #"(?:SA-?CD|HDCD|CD|DVD|BD|Blu-?ray|Disc|Disk)\s*(\d+)\b"#
	private(set) var head = 0
	private var labels: [String: Int] = [:]
	private var top = 0

	mutating func heading(_ title: String) {
		let t = title.trimmingCharacters(in: .whitespaces)
		if let m = try? NSRegularExpression(pattern: "^" + Self.discHeading, options: .caseInsensitive).firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
		   let r = Range(m.range(at: 1), in: t) { head = Int(t[r]) ?? head }
	}

	mutating func place(_ position: String) -> (Int, Int)? {
		let pos = position.trimmingCharacters(in: .whitespaces)
		var out: (Int, Int)
		if let g = Self.groups(#"(?:[A-Za-z]{2,})?(\d+)[-.](\d+)"#, pos) {
			out = (Int(g[0])!, Int(g[1])!)
		} else if let g = Self.groups(#"([A-Za-z]{2,})[-.]?(\d+)"#, pos) {
			let label = g[0].uppercased()
			if head == 0, labels[label] == nil { labels[label] = top + 1 }
			out = (head > 0 ? head : labels[label]!, Int(g[1])!)
		} else if head > 0, !pos.isEmpty, pos.allSatisfy(\.isASCII), let n = Int(pos) {
			out = (head, n)
		} else { return nil }
		top = max(top, out.0)
		return out
	}

	/// The capture groups of a whole-string match.
	private static func groups(_ pattern: String, _ s: String) -> [String]? {
		guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
		      let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
		return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
	}
}
