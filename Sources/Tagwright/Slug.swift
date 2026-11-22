import Foundation

/// The web app's naming.clean(): python-slugify's legacy pipeline (lowercase=False, separator "_") with Unidecode's
/// transliteration, then pathvalidate's sanitize_filename. The transliteration and HTML entity tables come from the
/// web app's own packages (scripts/gen-unidecode.py -> Resources/unidecode.bin), so names match character for
/// character (WebParityTests).
enum Slug {
	private static let tables: (chars: [UInt32: String], entities: [String: UInt32]) = {
		let url = Bundle.main.url(forResource: "unidecode", withExtension: "bin")
			?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/unidecode.bin").standardized
		guard let raw = try? (NSData(contentsOf: url)).decompressed(using: .zlib) as Data else { return ([:], [:]) }
		let b = [UInt8](raw)
		var chars: [UInt32: String] = [:], i = 0
		while i + 4 <= b.count {
			let cp = UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]); i += 4
			if cp == 0xFFFF_FFFF { break }
			let n = Int(b[i]); i += 1
			chars[cp] = String(decoding: b[i..<i + n], as: UTF8.self); i += n
		}
		var entities: [String: UInt32] = [:]
		for line in String(decoding: b[i...], as: UTF8.self).split(separator: "\n") {
			let p = line.split(separator: "\t"); if p.count == 2, let c = UInt32(p[1]) { entities[String(p[0])] = c }
		}
		return (chars, entities)
	}()

	/// Unidecode: ASCII as it is, everything else from the table (unknown characters are dropped).
	static func unidecode(_ s: String) -> String {
		var out = ""
		for u in s.unicodeScalars { if u.isASCII { out.unicodeScalars.append(u) } else if let r = tables.chars[u.value] { out += r } }
		return out
	}

	private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
	private static let apos = re("'+"), named = re("&([A-Za-z0-9]+);"), dec = re("&#(\\d+);"), hex = re("&#x([\\da-fA-F]+);"),
		digitComma = re("(?<=\\d),(?=\\d)"), nonWord = re("[^-a-zA-Z0-9]+"), dashes = re("-{2,}")
	private static func rep(_ s: String, _ r: NSRegularExpression, _ t: String) -> String {
		r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
	}

	private static func sub(_ s: String, _ re: NSRegularExpression, _ f: (NSTextCheckingResult, NSString) -> String?) -> String {
		let ns = s as NSString
		var out = "", last = 0
		for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
			out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
			out += f(m, ns) ?? ns.substring(with: m.range)
			last = m.range.location + m.range.length
		}
		return out + ns.substring(from: last)
	}
	private static func char(_ v: UInt32?) -> String? { v.flatMap(Unicode.Scalar.init).map { String(Character($0)) } }

	static let reserved: Set<String> = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })

	static func clean(_ text: String) -> String {
		var s = rep(text, apos, "-")
		s = s.decomposedStringWithCompatibilityMapping
		if !s.unicodeScalars.allSatisfy(\.isASCII) { s = unidecode(s) }
		if s.contains("&") {
			s = sub(s, named) { m, ns in tables.entities[ns.substring(with: m.range(at: 1))].flatMap { char($0) } }
			s = sub(s, dec) { m, ns in char(UInt32(ns.substring(with: m.range(at: 1)))) }
			s = sub(s, hex) { m, ns in char(UInt32(ns.substring(with: m.range(at: 1)), radix: 16)) }
		}
		s = s.decomposedStringWithCompatibilityMapping
		s = rep(s, apos, "")
		s = rep(s, digitComma, "")
		s = rep(s, nonWord, "-")
		s = rep(s, dashes, "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
		s = s.replacingOccurrences(of: "-", with: "_")
		if s.utf8.count > 255 { s = String(decoding: s.utf8.prefix(255), as: UTF8.self) }   // pathvalidate max_len (ASCII here)
		return reserved.contains(s.uppercased()) ? s + "_" : s   // pathvalidate: a reserved device name gets "_"
	}
}
