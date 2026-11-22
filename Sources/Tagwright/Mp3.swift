import Foundation

/// Port of pipeline/mp3.py (ADR 0059): an MP3 file with the surface of a FLAC file. The program keeps thinking in
/// Vorbis-style tags (upper-case keys, lists of strings); this maps them onto ID3 frames:
/// - the usual fields are their text frames (`textFrames`), `DATE` is TDRC and `ORIGINALDATE` TDOR;
/// - TRACKNUMBER / TRACKTOTAL / TOTALTRACKS are the halves of TRCK ("3/12"), DISCNUMBER / DISCTOTAL / TOTALDISCS of TPOS;
/// - LYRICS is USLT, COMMENT is COMM;
/// - every other key is a TXXX frame whose description is the key (read in any case).
/// ID3v2.3 and v2.4 are read, v2.4 is written (UTF-8, several values in one frame). Frames without a key (ratings,
/// play counts, private frames) are kept as they are. A trailing ID3v1 block is kept; the audio is copied unchanged.
struct Mp3File {
	static let textFrames: [(key: String, frame: String)] = [
		("TITLE", "TIT2"), ("ARTIST", "TPE1"), ("ALBUMARTIST", "TPE2"), ("ALBUM", "TALB"), ("DATE", "TDRC"), ("ORIGINALDATE", "TDOR"),
		("GENRE", "TCON"), ("COMPOSER", "TCOM"), ("PUBLISHER", "TPUB"), ("LABEL", "TPUB"), ("COPYRIGHT", "TCOP"), ("SUBTITLE", "TIT3"),
		("DISCSUBTITLE", "TSST"), ("ENCODER", "TSSE"), ("BPM", "TBPM"), ("ISRC", "TSRC"), ("LANGUAGE", "TLAN"), ("MOOD", "TMOO"),
		("MEDIA", "TMED"), ("ARTISTSORT", "TSOP"), ("ALBUMARTISTSORT", "TSO2"), ("ALBUMSORT", "TSOA"), ("TITLESORT", "TSOT"),
		("COMPOSERSORT", "TSOC"), ("LYRICIST", "TEXT"), ("CONDUCTOR", "TPE3"), ("REMIXER", "TPE4"), ("GROUPING", "TIT1"),
	]
	static let frameOfKey = Dictionary(textFrames.map { ($0.key, $0.frame) }, uniquingKeysWith: { a, _ in a })
	static let keyOfFrame = Dictionary(textFrames.map { ($0.frame, $0.key) }, uniquingKeysWith: { a, _ in a })   // LABEL and PUBLISHER share TPUB: the first names it
	static let numberKeys: [String: (frame: String, part: Int)] = [
		"TRACKNUMBER": ("TRCK", 0), "TRACKTOTAL": ("TRCK", 1), "TOTALTRACKS": ("TRCK", 1),
		"DISCNUMBER": ("TPOS", 0), "DISCTOTAL": ("TPOS", 1), "TOTALDISCS": ("TPOS", 1),
	]

	static let v22: [String: String] = [
		"TT1": "TIT1", "TT2": "TIT2", "TT3": "TIT3", "TP1": "TPE1", "TP2": "TPE2", "TP3": "TPE3", "TP4": "TPE4", "TAL": "TALB",
		"TRK": "TRCK", "TPA": "TPOS", "TYE": "TYER", "TDA": "TDAT", "TOR": "TORY", "TCO": "TCON", "TCM": "TCOM", "TPB": "TPUB",
		"TCR": "TCOP", "TEN": "TENC", "TSS": "TSSE", "TBP": "TBPM", "TRC": "TSRC", "TLA": "TLAN", "TXT": "TEXT", "TXX": "TXXX",
		"ULT": "USLT", "COM": "COMM", "PIC": "APIC", "TS2": "TSO2", "TSA": "TSOA", "TST": "TSOT", "TSP": "TSOP", "TSC": "TSOC",
	]

	var url: URL
	var info = StreamInfo()
	var tags = Tags()
	var pictures: [Picture] = []
	private var other: [(id: String, body: Data)] = []   // frames without a key, written back as they were
	private var txxxDesc: [String: String] = [:]          // key -> description as the file had it
	private var tagSize = 0                               // bytes of the ID3v2 tag at the start (header and footer included)

	init(url: URL) throws {
		self.url = url
		let h = try FileHandle(forReadingFrom: url)
		defer { try? h.close() }
		let head = try h.read(upToCount: 10) ?? Data()
		var frameStart = 0
		if head.count == 10, head.starts(with: Data("ID3".utf8)) {
			let b = [UInt8](head)
			let size = Self.syncsafe(b[6...9])
			tagSize = 10 + size + (b[5] & 0x10 != 0 ? 10 : 0)
			let body = try h.read(upToCount: size) ?? Data()
			if (2...4).contains(b[3]) { parse(version: Int(b[3]), flags: b[5], body: [UInt8](body)) }
			frameStart = tagSize
		}
		try h.seek(toOffset: UInt64(frameStart))
		let audioHead = try h.read(upToCount: 4096) ?? Data()
		let total = try h.seekToEnd()
		readStream([UInt8](audioHead), audioBytes: Int(total) - frameStart - (Self.id3v1(url) ? 128 : 0))
	}

	// MARK: reading

	static func syncsafe(_ b: ArraySlice<UInt8>) -> Int { b.reduce(0) { $0 << 7 | Int($1 & 0x7f) } }
	static func be32(_ b: ArraySlice<UInt8>) -> Int { b.reduce(0) { $0 << 8 | Int($1) } }
	static func unsync(_ b: [UInt8]) -> [UInt8] {
		var out: [UInt8] = []; out.reserveCapacity(b.count)
		var i = 0
		while i < b.count { out.append(b[i]); if b[i] == 0xff, i + 1 < b.count, b[i + 1] == 0 { i += 1 }; i += 1 }
		return out
	}
	static func id3v1(_ url: URL) -> Bool { FlacFile.id3v1Trailer(url) > 0 }

	private mutating func parse(version: Int, flags: UInt8, body raw: [UInt8]) {
		if version == 2 && flags & 0x40 != 0 { return }   // a compressed v2.2 tag: no defined scheme, nothing to read
		var b = version <= 3 && flags & 0x80 != 0 ? Self.unsync(raw) : raw
		var i = 0
		if version >= 3, flags & 0x40 != 0, b.count >= 4 {   // extended header
			i = version == 4 ? Self.syncsafe(b[0..<4]) : Self.be32(b[0..<4]) + 4
		}
		var date = "", tdat = ""
		let hdr = version == 2 ? 6 : 10
		while i + hdr <= b.count, b[i] != 0 {
			var id = String(decoding: b[i..<i + (version == 2 ? 3 : 4)], as: UTF8.self)
			let size = version == 2 ? Self.be32(b[i + 3..<i + 6]) : version == 4 ? Self.syncsafe(b[i + 4..<i + 8]) : Self.be32(b[i + 4..<i + 8])
			let f2 = version == 2 ? 0 : b[i + 9]
			i += hdr
			guard size > 0, i + size <= b.count else { break }
			var body = Array(b[i..<i + size]); i += size
			if version == 2 {   // iTunes-style v2.2: three-letter frames, upgraded as mutagen does; the rest is dropped
				guard let v4 = Self.v22[id] else { continue }
				id = v4
				if id == "APIC", body.count > 4 {   // PIC: encoding, 3-letter image format, type, description, data
					let fmt = String(decoding: body[1..<4], as: UTF8.self).uppercased()
					body = [body[0]] + Array((fmt == "PNG" ? "image/png" : "image/jpeg").utf8) + [0] + Array(body[4...])
				}
			} else if version == 4 {
				if f2 & 0x0c != 0 { continue }                   // compressed or encrypted: not ours to read
				if f2 & 0x02 != 0 || flags & 0x80 != 0 { body = Self.unsync(body) }
				if f2 & 0x01 != 0, body.count >= 4 { body.removeFirst(4) }   // data length indicator
			} else if f2 & 0xc0 != 0 { continue }
			switch id {
			case "TXXX":
				let (desc, vals) = Self.textWithDesc(body)
				let key = desc.uppercased()
				txxxDesc[key] = desc; tags[key] = vals.filter { !$0.isEmpty }
			case "TRCK", "TPOS":
				let v = Self.texts(body).first ?? ""
				let p = v.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
				let (n, t) = id == "TRCK" ? ("TRACKNUMBER", ["TRACKTOTAL", "TOTALTRACKS"]) : ("DISCNUMBER", ["DISCTOTAL", "TOTALDISCS"])
				if let a = p.first, !a.isEmpty { tags[n] = [a] }
				if p.count > 1, !p[1].isEmpty { for k in t { tags[k] = [p[1]] } }
			case "USLT", "COMM":
				guard body.count > 4 else { continue }
				let (_, vals) = Self.textWithDesc([body[0]] + body[4...])
				let v = vals.joined(separator: "\n")
				if !v.isEmpty, tags[id == "USLT" ? "LYRICS" : "COMMENT"] == nil { tags[id == "USLT" ? "LYRICS" : "COMMENT"] = [v] }
			case "APIC": if let p = Self.picture(body, version: version) { pictures.append(p) }
			case "TYER" where version <= 3: date = Self.texts(body).first ?? ""
			case "TDAT" where version <= 3: tdat = Self.texts(body).first ?? ""
			case "TORY" where version <= 3: tags["ORIGINALDATE"] = Self.texts(body)
			default:
				if let key = Self.keyOfFrame[id], id.hasPrefix("T") { tags[key] = Self.texts(body).filter { !$0.isEmpty } }
				else if id != "TDAT", id != "TIME" { other.append((id, Data(body))) }
			}
		}
		if !date.isEmpty, tags["DATE"] == nil {   // v2.3 TYER + TDAT (DDMM) become TDRC, as mutagen's upgrade does
			tags["DATE"] = [tdat.count == 4 ? "\(date)-\(tdat.suffix(2))-\(tdat.prefix(2))" : date]
		}
		b = []
		tags = tags.filter { !$0.key.isEmpty && !$0.value.isEmpty }
		other.removeAll { ["TRDA", "TSIZ", "EQUA", "RVAD", "IPLS"].contains($0.id) }   // ID3v2.3-only frames (mutagen drops them too)
	}

	/// Decodes text in an ID3 encoding (0 Latin-1, 1 UTF-16 with BOM, 2 UTF-16BE, 3 UTF-8); values split at NUL.
	static func decode(_ enc: UInt8, _ b: ArraySlice<UInt8>) -> [String] {
		switch enc {
		case 1, 2:
			var parts: [String] = [], cur: [UInt8] = []
			var i = b.startIndex
			while i + 1 < b.endIndex {
				if b[i] == 0 && b[i + 1] == 0 { parts.append(utf16(cur, bigEndian: enc == 2)); cur = [] } else { cur += [b[i], b[i + 1]] }
				i += 2
			}
			if !cur.isEmpty { parts.append(utf16(cur, bigEndian: enc == 2)) }
			while parts.last == "" { parts.removeLast() }
			return parts
		default:
			var parts = b.split(separator: 0, omittingEmptySubsequences: false).map { enc == 3 ? String(decoding: $0, as: UTF8.self) : String(bytes: $0, encoding: .isoLatin1) ?? "" }
			while parts.last == "" { parts.removeLast() }
			return parts
		}
	}
	static func utf16(_ b: [UInt8], bigEndian: Bool) -> String {
		var be = bigEndian, s = b[...]
		if s.count >= 2 { if s.starts(with: [0xff, 0xfe]) { be = false; s = s.dropFirst(2) } else if s.starts(with: [0xfe, 0xff]) { be = true; s = s.dropFirst(2) } }
		let units = stride(from: s.startIndex, to: s.endIndex - 1, by: 2).map { be ? UInt16(s[$0]) << 8 | UInt16(s[$0 + 1]) : UInt16(s[$0 + 1]) << 8 | UInt16(s[$0]) }
		return String(decoding: units, as: UTF16.self)
	}
	static func texts(_ body: [UInt8]) -> [String] { body.isEmpty ? [] : decode(body[0], body[1...]) }
	/// TXXX / USLT / COMM layout after the encoding byte: description, NUL, value(s).
	static func textWithDesc(_ body: [UInt8]) -> (String, [String]) {
		guard let enc = body.first else { return ("", []) }
		let rest = body[1...]
		let wide = enc == 1 || enc == 2
		var i = rest.startIndex
		while i < rest.endIndex { if wide ? (i + 1 < rest.endIndex && rest[i] == 0 && rest[i + 1] == 0 && (i - rest.startIndex) % 2 == 0) : rest[i] == 0 { break }; i += wide ? 1 : 1 }
		let desc = decode(enc, rest[rest.startIndex..<i]).first ?? ""
		let after = min(rest.endIndex, i + (wide ? 2 : 1))
		return (desc, decode(enc, rest[after...]))
	}
	static func picture(_ b: [UInt8], version: Int) -> Picture? {
		guard b.count > 4 else { return nil }
		let enc = b[0]
		var i = 1
		while i < b.count, b[i] != 0 { i += 1 }
		let mime = String(bytes: b[1..<i], encoding: .isoLatin1) ?? "image/jpeg"
		i += 1
		guard i < b.count else { return nil }
		let type = b[i]; i += 1
		let wide = enc == 1 || enc == 2
		let ds = i
		while i < b.count { if wide ? (i + 1 < b.count && b[i] == 0 && b[i + 1] == 0 && (i - ds) % 2 == 0) : b[i] == 0 { break }; i += 1 }
		let desc = decode(enc, b[ds..<i]).first ?? ""
		i += wide ? 2 : 1
		guard i <= b.count else { return nil }
		let data = Data(b[i...])
		let size = ImageSize.of(data)   // the pixel size is measured, as the web app does
		return Picture(type: UInt32(type), mime: mime.lowercased() == "jpg" ? "image/jpeg" : mime, desc: desc, width: UInt32(size?.0 ?? 0), height: UInt32(size?.1 ?? 0), data: data)
	}

	/// Sample rate, channels and length from the first MPEG frame and its Xing/Info/VBRI header, else from the bitrate.
	private mutating func readStream(_ b: [UInt8], audioBytes: Int) {
		var i = 0
		while i + 4 <= b.count, !(b[i] == 0xff && b[i + 1] & 0xe0 == 0xe0 && b[i + 1] & 0x06 != 0 && b[i + 2] & 0xf0 != 0xf0 && b[i + 2] & 0x0c != 0x0c) { i += 1 }
		guard i + 4 <= b.count else { return }
		let ver = (b[i + 1] >> 3) & 3, layer = (b[i + 1] >> 1) & 3   // ver: 3 MPEG1, 2 MPEG2, 0 MPEG2.5; layer 1 = III
		let rates: [[Int]] = [[11025, 12000, 8000], [], [22050, 24000, 16000], [44100, 48000, 32000]]
		guard ver != 1, layer != 0 else { return }
		let sr = rates[Int(ver)][Int((b[i + 2] >> 2) & 3)]
		let mono = (b[i + 3] >> 6) == 3
		let v1 = ver == 3
		let kbps: [Int] = layer == 1 ? (v1 ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320] : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])
			: layer == 2 ? (v1 ? [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384] : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])
			: (v1 ? [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448] : [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256])
		let bi = Int(b[i + 2] >> 4)
		let bitrate = bi < kbps.count ? kbps[bi] * 1000 : 0
		let spf = layer == 3 ? 384 : (layer == 1 && !v1) ? 576 : 1152
		info.sampleRate = sr; info.channels = mono ? 1 : 2; info.bits = 0
		let side = layer == 1 ? (v1 ? (mono ? 17 : 32) : (mono ? 9 : 17)) : 0
		let x = i + 4 + side
		if x + 12 <= b.count, ["Xing", "Info"].contains(String(decoding: b[x..<x + 4], as: UTF8.self)), b[x + 7] & 1 != 0 {
			info.totalSamples = UInt64(Self.be32(b[x + 8..<x + 12]) * spf); return
		}
		let v = i + 4 + 32
		if v + 18 <= b.count, String(decoding: b[v..<v + 4], as: UTF8.self) == "VBRI" {
			info.totalSamples = UInt64(Self.be32(b[v + 14..<v + 18]) * spf); return
		}
		if bitrate > 0 { info.totalSamples = UInt64(Double(max(0, audioBytes - i)) * 8 / Double(bitrate) * Double(sr)) }
	}

	// MARK: writing (ID3v2.4, UTF-8)

	private static func frame(_ id: String, _ body: Data) -> Data {
		var d = Data(id.utf8)
		let n = body.count
		d.append(contentsOf: [UInt8(n >> 21 & 0x7f), UInt8(n >> 14 & 0x7f), UInt8(n >> 7 & 0x7f), UInt8(n & 0x7f), 0, 0])
		d.append(body)
		return d
	}
	private static func text(_ values: [String]) -> Data { Data([3]) + Data(values.joined(separator: "\0").utf8) }

	func tagBlock() -> Data {
		var frames = Data()
		var done = Set<String>()
		for (key, frameID) in Self.textFrames where !done.contains(frameID) {
			let keys = Self.textFrames.filter { $0.frame == frameID }.map(\.key)
			if let v = keys.lazy.compactMap({ tags[$0]?.filter { !$0.isEmpty } }).first(where: { !$0.isEmpty }) { frames += Self.frame(frameID, Self.text(v)); done.insert(frameID) }
			_ = key
		}
		for (id, n, totals) in [("TRCK", "TRACKNUMBER", ["TRACKTOTAL", "TOTALTRACKS"]), ("TPOS", "DISCNUMBER", ["DISCTOTAL", "TOTALDISCS"])] {
			let num = tags.first(n).split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
			let tot = totals.lazy.map { tags.first($0) }.first { !$0.isEmpty } ?? ""
			let s = !num.isEmpty && !tot.isEmpty ? "\(num)/\(tot)" : !num.isEmpty ? num : !tot.isEmpty ? "/\(tot)" : ""
			if !s.isEmpty { frames += Self.frame(id, Self.text([s])) }
		}
		if let l = tags["LYRICS"]?.first, !l.isEmpty { frames += Self.frame("USLT", Data([3]) + Data("eng".utf8) + Data([0]) + Data(l.utf8)) }
		if let c = tags["COMMENT"]?.filter({ !$0.isEmpty }), !c.isEmpty { frames += Self.frame("COMM", Data([3]) + Data("eng".utf8) + Data([0]) + Data(c.joined(separator: "\0").utf8)) }
		let own = Set(Self.textFrames.map(\.key) + Array(Self.numberKeys.keys) + ["LYRICS", "COMMENT"])
		for k in tags.keys.sorted() where !own.contains(k) {
			let v = tags[k]!.filter { !$0.isEmpty }
			if !v.isEmpty { frames += Self.frame("TXXX", Data([3]) + Data((txxxDesc[k] ?? k).utf8) + Data([0]) + Data(v.joined(separator: "\0").utf8)) }
		}
		for p in pictures {
			frames += Self.frame("APIC", Data([3]) + Data(p.mime.utf8) + Data([0, UInt8(p.type & 0xff)]) + Data(p.desc.utf8) + Data([0]) + p.data)
		}
		for o in other { frames += Self.frame(o.id, o.body) }
		frames += Data(count: 1024)   // padding
		let n = frames.count
		var head = Data("ID3".utf8) + Data([4, 0, 0])
		head.append(contentsOf: [UInt8(n >> 21 & 0x7f), UInt8(n >> 14 & 0x7f), UInt8(n >> 7 & 0x7f), UInt8(n & 0x7f)])
		return head + frames
	}

	/// Rewrites the file: the new ID3v2.4 tag, then the audio (and an ID3v1 block) byte for byte (temp file, then
	/// atomic replace).
	mutating func save() throws {
		let tag = tagBlock()
		let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tw-tmp")
		FileManager.default.createFile(atPath: tmp.path, contents: nil)
		let out = try FileHandle(forWritingTo: tmp)
		defer { try? out.close() }
		try out.write(contentsOf: tag)
		let inp = try FileHandle(forReadingFrom: url)
		defer { try? inp.close() }
		try inp.seek(toOffset: UInt64(tagSize))
		while let chunk = try inp.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
		try out.close()
		_ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
		tagSize = tag.count
	}
}

/// ADR 0058: the one seam for audio files. FLAC and MP3 behind the same surface; everything else opens files here.
struct AudioFile {
	static let extensions = ["flac", "mp3"]
	static func isAudio(_ name: String) -> Bool { !name.hasPrefix(".") && extensions.contains((name as NSString).pathExtension.lowercased()) }

	private enum Kind { case flac(FlacFile), mp3(Mp3File) }
	private var kind: Kind
	let url: URL

	init(url: URL) throws {
		self.url = url
		kind = url.pathExtension.lowercased() == "mp3" ? .mp3(try Mp3File(url: url)) : .flac(try FlacFile(url: url))
	}

	/// Tags, stream info and the front cover's size for the library index; FLAC skips the picture data.
	static func quickRead(_ url: URL) throws -> (tags: Tags, info: StreamInfo, cover: (Int, Int)?) {
		guard url.pathExtension.lowercased() == "mp3" else { return try FlacFile.quickRead(url) }
		let m = try Mp3File(url: url)
		let c = m.pictures.first { $0.type == 3 } ?? m.pictures.first
		return (m.tags, m.info, c.map { (Int($0.width), Int($0.height)) })
	}

	var isMP3: Bool { if case .mp3 = kind { return true }; return false }
	var info: StreamInfo { switch kind { case .flac(let f): f.info; case .mp3(let m): m.info } }
	var tags: Tags {
		get { switch kind { case .flac(let f): f.tags; case .mp3(let m): m.tags } }
		set { switch kind { case .flac(var f): f.tags = newValue; kind = .flac(f); case .mp3(var m): m.tags = newValue.filter { !$0.value.isEmpty }; kind = .mp3(m) } }
	}
	var pictures: [Picture] {
		get { switch kind { case .flac(let f): f.pictures; case .mp3(let m): m.pictures } }
		set { switch kind { case .flac(var f): f.pictures = newValue; kind = .flac(f); case .mp3(var m): m.pictures = newValue; kind = .mp3(m) } }
	}
	mutating func save() throws {
		switch kind {
		case .flac(var f): try f.save(); kind = .flac(f)
		case .mp3(var m): try m.save(); kind = .mp3(m)
		}
	}
}
