import Foundation

/// Vorbis comments, keys upper-cased (ADR 0005): key -> values in file order.
typealias Tags = [String: [String]]

struct StreamInfo: Codable {
	var sampleRate = 0, channels = 0, bits = 0
	var totalSamples: UInt64 = 0
	var duration: Double { sampleRate > 0 ? Double(totalSamples) / Double(sampleRate) : 0 }
}

struct Picture: Equatable {
	var type: UInt32 = 3
	var mime = "image/jpeg"
	var desc = ""
	var width: UInt32 = 0, height: UInt32 = 0
	var data = Data()
}

enum FlacError: Error, LocalizedError {
	case notFlac(String), truncated(String)
	var errorDescription: String? {
		switch self {
		case .notFlac(let n): "\(n) is not a FLAC file"
		case .truncated(let n): "\(n) is truncated"
		}
	}
}

/// Reads and rewrites the metadata of a FLAC file; the audio frames are copied byte for byte.
struct FlacFile {
	var url: URL
	var info = StreamInfo()
	var vendor = "Tagwright"
	var comments: [(key: String, value: String)] = []
	var pictures: [Picture] = []
	private var streamInfoRaw = Data()
	private var otherBlocks: [(type: UInt8, data: Data)] = []
	private var audioOffset: UInt64 = 0

	/// An empty file object for quickRead (index.swift), which fills it from the headers only.
	init(url: URL, empty: Bool) { self.url = url }
	mutating func parseStreamInfoPublic(_ d: Data) { parseStreamInfo(d) }
	mutating func parseCommentsPublic(_ d: Data) { parseComments(d) }

	init(url: URL) throws {
		self.url = url
		let h = try FileHandle(forReadingFrom: url)
		defer { try? h.close() }
		guard let magic = try h.read(upToCount: 4), magic == Data("fLaC".utf8) else { throw FlacError.notFlac(url.lastPathComponent) }
		var pos: UInt64 = 4
		var last = false
		while !last {
			guard let head = try h.read(upToCount: 4), head.count == 4 else { throw FlacError.truncated(url.lastPathComponent) }
			last = head[0] & 0x80 != 0
			let type = head[0] & 0x7f
			let len = Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
			let body = len > 0 ? (try h.read(upToCount: len) ?? Data()) : Data()
			guard body.count == len else { throw FlacError.truncated(url.lastPathComponent) }
			pos += 4 + UInt64(len)
			switch type {
			case 0: parseStreamInfo(body)
			case 4: parseComments(body)
			case 6: if let p = Self.parsePicture(body) { pictures.append(p) }
			case 1: break  // padding is regenerated
			default: otherBlocks.append((type, body))
			}
		}
		audioOffset = pos
	}

	private mutating func parseStreamInfo(_ d: Data) {
		streamInfoRaw = d
		guard d.count >= 18 else { return }
		let b = [UInt8](d)
		info.sampleRate = Int(b[10]) << 12 | Int(b[11]) << 4 | Int(b[12]) >> 4
		info.channels = Int((b[12] >> 1) & 7) + 1
		info.bits = Int((b[12] & 1)) << 4 | Int(b[13] >> 4) + 1
		info.totalSamples = UInt64(b[13] & 0xf) << 32 | UInt64(b[14]) << 24 | UInt64(b[15]) << 16 | UInt64(b[16]) << 8 | UInt64(b[17])
	}

	private mutating func parseComments(_ d: Data) {
		let b = [UInt8](d)
		var i = 0
		func u32() -> Int? {
			guard i + 4 <= b.count else { return nil }
			defer { i += 4 }
			return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
		}
		guard let vl = u32(), i + vl <= b.count else { return }
		vendor = String(decoding: b[i..<i + vl], as: UTF8.self); i += vl
		guard let n = u32() else { return }
		for _ in 0..<n {
			guard let l = u32(), i + l <= b.count else { return }
			let s = String(decoding: b[i..<i + l], as: UTF8.self); i += l
			if let eq = s.firstIndex(of: "=") {
				comments.append((String(s[..<eq]).uppercased(), String(s[s.index(after: eq)...])))
			}
		}
	}

	private static func parsePicture(_ d: Data) -> Picture? {
		let b = [UInt8](d)
		var i = 0
		func u32() -> Int? {
			guard i + 4 <= b.count else { return nil }
			defer { i += 4 }
			return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
		}
		func str() -> String? {
			guard let l = u32(), i + l <= b.count else { return nil }
			defer { i += l }
			return String(decoding: b[i..<i + l], as: UTF8.self)
		}
		guard let t = u32(), let mime = str(), let desc = str(), let w = u32(), let h = u32(), u32() != nil, u32() != nil,
			let dl = u32(), i + dl <= b.count else { return nil }
		return Picture(type: UInt32(t), mime: mime, desc: desc, width: UInt32(w), height: UInt32(h), data: Data(b[i..<i + dl]))
	}

	var tags: Tags {
		get { comments.reduce(into: Tags()) { $0[$1.key, default: []].append($1.value) } }
		set {
			comments = newValue.keys.sorted().flatMap { k in newValue[k]!.filter { !$0.isEmpty }.map { (k, $0) } }
		}
	}

	private func commentBlock() -> Data {
		var d = Data()
		func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
		let v = Data(vendor.utf8)
		u32(v.count); d.append(v); u32(comments.count)
		for c in comments { let s = Data("\(c.key)=\(c.value)".utf8); u32(s.count); d.append(s) }
		return d
	}

	private func pictureBlock(_ p: Picture) -> Data {
		var d = Data()
		func u32(_ v: Int) { var x = UInt32(v).bigEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
		u32(Int(p.type)); u32(p.mime.utf8.count); d.append(Data(p.mime.utf8))
		u32(p.desc.utf8.count); d.append(Data(p.desc.utf8))
		u32(Int(p.width)); u32(Int(p.height)); u32(24); u32(0); u32(p.data.count); d.append(p.data)
		return d
	}

	/// Size of an ID3v1 tag appended after the audio (128 bytes starting with "TAG"), else 0. Such a tag makes
	/// FLAC decoders report LOST_SYNC at the end; every rewrite of the file drops it.
	static func id3v1Trailer(_ url: URL) -> UInt64 {
		guard let h = try? FileHandle(forReadingFrom: url) else { return 0 }
		defer { try? h.close() }
		guard let size = try? h.seekToEnd(), size > 128, (try? h.seek(toOffset: size - 128)) != nil,
			let d = try? h.read(upToCount: 3), d == Data("TAG".utf8) else { return 0 }
		return 128
	}

	/// Rewrites the file with the current comments and pictures (temp file, then atomic replace). A trailing
	/// ID3v1 tag is not copied.
	mutating func save() throws {
		var blocks: [(UInt8, Data)] = [(0, streamInfoRaw)]
		blocks += otherBlocks.map { ($0.type, $0.data) }
		blocks.append((4, commentBlock()))
		blocks += pictures.map { (6, pictureBlock($0)) }
		blocks.append((1, Data(count: 1024)))
		let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tw-tmp")
		FileManager.default.createFile(atPath: tmp.path, contents: nil)
		let out = try FileHandle(forWritingTo: tmp)
		defer { try? out.close() }
		var head = Data("fLaC".utf8)
		for (i, b) in blocks.enumerated() {
			let n = b.1.count
			head.append(b.0 | (i == blocks.count - 1 ? 0x80 : 0))
			head.append(contentsOf: [UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
			head.append(b.1)
		}
		try out.write(contentsOf: head)
		let inp = try FileHandle(forReadingFrom: url)
		defer { try? inp.close() }
		try inp.seek(toOffset: audioOffset)
		var left = try inp.seekToEnd() - Self.id3v1Trailer(url) - audioOffset
		try inp.seek(toOffset: audioOffset)
		while left > 0, let chunk = try inp.read(upToCount: Int(min(left, 1 << 20))), !chunk.isEmpty { try out.write(contentsOf: chunk); left -= UInt64(chunk.count) }
		try out.close()
		_ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
		audioOffset = UInt64(head.count)
	}
}

extension Dictionary where Key == String, Value == [String] {
	func first(_ keys: String...) -> String {
		for k in keys { if let v = self[k]?.first, !v.isEmpty { return v } }
		return ""
	}
}
