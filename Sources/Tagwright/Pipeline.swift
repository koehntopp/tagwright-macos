import AVFoundation
import Foundation

struct StepError: Error, LocalizedError {
	var message: String
	var errorDescription: String? { message }
	init(_ m: String) { message = m }
}

typealias Log = @Sendable (String) -> Void

/// The six steps of ADR 0054, in process (ADR 0004's external scripts are replaced by native code).
enum Pipeline {
	/// Removes ID3v1 tags appended after the audio (they make FLAC decoders fail at the end). Returns the files changed.
	@discardableResult
	static func stripID3v1(_ files: [URL], log: Log) throws -> Int {
		var n = 0
		for f in files where f.pathExtension.lowercased() == "flac" && FlacFile.id3v1Trailer(f) > 0 {
			var flac = try FlacFile(url: f)
			try flac.save()   // the rewrite does not copy the trailer
			log("removed ID3v1 tag  \(f.lastPathComponent)"); n += 1
		}
		return n
	}

	// MARK: tag writes (ADR 0032: reopen right before saving)

	static func update(_ files: [URL], _ change: (URL, inout Tags) -> Void) throws {
		for f in files {
			var flac = try AudioFile(url: f)
			var t = flac.tags
			change(f, &t)
			flac.tags = t
			try flac.save()
		}
	}

	// MARK: 1. dynamic range (TT DR algorithm: 3 s blocks, 20 % loudest, 2nd peak)

	static func dynamicRange(files: [URL], log: Log) throws {
		var values: [Int] = []
		for f in files {
			try Task.checkCancellation()
			let dr = try measureDR(f)
			log("DR \(dr)  \(f.lastPathComponent)")
			values.append(dr)
			try update([f]) { _, t in t["DYNAMIC_RANGE"] = ["\(dr)"] }
		}
		let album = albumDR(values)
		try update(files) { _, t in t["ALBUM_DR"] = ["\(album)"] }
		log("Album DR \(album)")
	}

	/// As calculate_dr.py / drcalc: the mean of the rounded track values, tracks with DR 0 left out; ties to even.
	static func albumDR(_ tracks: [Int]) -> Int {
		let rated = tracks.filter { $0 > 0 }
		return rated.isEmpty ? 0 : Int((Double(rated.reduce(0, +)) / Double(rated.count)).rounded(.toNearestOrEven))
	}

	/// Reads the next chunk; false at the end. A damaged tail (a decoder error after audio was read) ends the
	/// stream instead of failing the whole file, as the reference tools do (ADR 0073).
	static func readChunk(_ af: AVAudioFile, _ buf: AVAudioPCMBuffer) throws -> Bool {
		guard af.framePosition < af.length else { return false }
		do { try af.read(into: buf) } catch { if af.framePosition > 0 { return false }; throw error }
		return buf.frameLength > 0
	}

	static func measureDR(_ url: URL) throws -> Int { Int(try measureDRValue(url).rounded(.toNearestOrEven)) }

	/// TT DR (drcalc, ADR 0027): 3 s blocks per channel (the last, partial block counts too), RMS of the loudest
	/// 20 % of the blocks (rounded to even), second-highest block peak; the channels' values are averaged.
	static func measureDRValue(_ url: URL) throws -> Double {
		let af = try AVAudioFile(forReading: url)
		let fmt = af.processingFormat
		let ch = Int(fmt.channelCount), block = Int((3 * fmt.sampleRate).rounded())
		let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 65536)!
		var sumsq = [Double](repeating: 0, count: ch), peak = [Double](repeating: 0, count: ch), filled = 0
		var rms = [[Double]](repeating: [], count: ch), peaks = [[Double]](repeating: [], count: ch)
		func flush() {
			guard filled > 0 else { return }
			for c in 0..<ch { rms[c].append((2 * sumsq[c] / Double(filled)).squareRoot()); peaks[c].append(peak[c]); sumsq[c] = 0; peak[c] = 0 }
			filled = 0
		}
		while try readChunk(af, buf) {
			let data = buf.floatChannelData!
			for i in 0..<Int(buf.frameLength) {
				for c in 0..<ch { let x = Double(data[c][i]); sumsq[c] += x * x; peak[c] = max(peak[c], abs(x)) }
				filled += 1
				if filled == block { flush() }
			}
		}
		flush()
		let total = rms[0].count
		guard total >= 4 else { throw StepError("\(url.lastPathComponent) is shorter than 12 s") }
		let upmost = Int((Double(total) * 0.2).rounded(.toNearestOrEven))
		var drs: [Double] = []
		for c in 0..<ch {
			let r = rms[c].sorted(), p = peaks[c].sorted()
			let top = (r[(total - upmost)...].reduce(0) { $0 + $1 * $1 } / Double(upmost)).squareRoot()
			drs.append(top > 0 ? 20 * log10(p[total - 2] / top) : 0)
		}
		return drs.reduce(0, +) / Double(ch)
	}

	// MARK: 2. ReplayGain 2.0 (EBU R128, reference -18 LUFS)

	private struct Biquad {
		var b0, b1, b2, a1, a2: Double
		var z1 = 0.0, z2 = 0.0
		mutating func run(_ x: Double) -> Double {
			let y = b0 * x + z1
			z1 = b1 * x - a1 * y + z2
			z2 = b2 * x - a2 * y
			return y
		}
	}

	private static func kWeighting(_ fs: Double) -> [Biquad] {
		var k = tan(Double.pi * 1681.974450955533 / fs)
		let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416), q1 = 0.7071752369554196
		var a0 = 1 + k / q1 + k * k
		let shelf = Biquad(b0: (vh + vb * k / q1 + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q1 + k * k) / a0, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q1 + k * k) / a0)
		k = tan(Double.pi * 38.13547087602444 / fs)
		let q2 = 0.5003270373238773
		a0 = 1 + k / q2 + k * k
		let hp = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q2 + k * k) / a0)
		return [shelf, hp]
	}

	/// libebur128's default channel map: L R C [LFE unused] Ls Rs, surround at 1.41, everything else unused.
	static func channelWeights(_ n: Int) -> [Double] {
		switch n {
		case 4: return [1, 1, 1.41, 1.41]
		case 5: return [1, 1, 1, 1.41, 1.41]
		default: return (0..<n).map { [1, 1, 1, 0, 1.41, 1.41][safe: $0] ?? ($0 < 3 ? 1 : 0) }
		}
	}

	/// Mean-square energy per 100 ms sub-block (channel-weighted) and the sample peak.
	private static func energies(_ url: URL) throws -> (blocks: [Double], peak: Float) {
		let af = try AVAudioFile(forReading: url)
		let fmt = af.processingFormat, ch = Int(fmt.channelCount), fs = fmt.sampleRate
		let sub = (Int(fs) + 5) / 10   // libebur128: samples in 100 ms
		var filters = (0..<ch).map { _ in kWeighting(fs) }
		let weights = channelWeights(ch)
		let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 65536)!
		var acc = [Double](repeating: 0, count: ch), n = 0, out: [Double] = [], peak: Float = 0
		while try readChunk(af, buf) {
			let len = Int(buf.frameLength)
			for i in 0..<len {
				for c in 0..<ch {
					let x = buf.floatChannelData![c][i]
					peak = max(peak, abs(x))
					var y = Double(x)
					y = filters[c][0].run(y); y = filters[c][1].run(y)
					acc[c] += y * y
				}
				n += 1
				if n == sub {
					var z = 0.0
					for c in 0..<ch { z += weights[c] * acc[c] / Double(sub) }
					out.append(z); acc = [Double](repeating: 0, count: ch); n = 0
				}
			}
		}
		return (out, peak)
	}

	/// 400 ms gating windows with a 100 ms hop, built per track (they never straddle two tracks, as in libebur128).
	private static func windows(_ sub: [Double]) -> [Double] {
		guard sub.count >= 4 else { return [] }
		return (0...(sub.count - 4)).map { (sub[$0] + sub[$0 + 1] + sub[$0 + 2] + sub[$0 + 3]) / 4 }
	}

	/// EBU R128 integrated loudness: absolute gate -70 LUFS, relative gate 10 LU below.
	private static func gated(_ blocks: [Double]) -> Double? {
		func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
		let a = blocks.filter { $0 > 0 && lufs($0) > -70 }
		guard !a.isEmpty else { return nil }
		let rel = lufs(a.reduce(0, +) / Double(a.count)) - 10
		let b = a.filter { lufs($0) > rel }
		guard !b.isEmpty else { return nil }
		return lufs(b.reduce(0, +) / Double(b.count))
	}

	struct GainResult { var tracks: [(gain: Double, peak: Double)]; var albumGain: Double; var albumPeak: Double }

	/// ReplayGain 2.0 (reference -18 LUFS) for the tracks of one album; writes nothing.
	static func replayGainValues(files: [URL]) throws -> GainResult {
		var per: [(blocks: [Double], peak: Double)] = []
		for f in files {
			try Task.checkCancellation()
			let e = try energies(f)
			per.append((windows(e.blocks), Double(e.peak)))
		}
		guard let album = gated(per.flatMap(\.blocks)) else { throw StepError("No measurable audio") }
		var out: [(Double, Double)] = []
		for (i, p) in per.enumerated() {
			guard let l = gated(p.blocks) else { throw StepError("\(files[i].lastPathComponent) is too quiet to measure") }
			out.append((-18 - l, p.peak))
		}
		return GainResult(tracks: out, albumGain: -18 - album, albumPeak: per.map(\.peak).max() ?? 0)
	}

	/// True when every file carries REPLAYGAIN_ALBUM_GAIN; track gain alone is not enough (ADR 0028).
	static func hasAlbumGain(_ files: [URL]) -> Bool {
		!files.isEmpty && files.allSatisfy { !((try? AudioFile(url: $0))?.tags.first("REPLAYGAIN_ALBUM_GAIN") ?? "").isEmpty }
	}

	static func replayGain(files: [URL], log: Log) throws {
		if hasAlbumGain(files) { log("Album gain already on every file: skipped"); return }
		let r = try replayGainValues(files: files)
		for (f, t) in zip(files, r.tracks) {
			log(String(format: "%+.2f dB  %@", t.gain, f.lastPathComponent))
			try update([f]) { _, tags in
				tags["REPLAYGAIN_TRACK_GAIN"] = [String(format: "%.2f dB", t.gain)]
				tags["REPLAYGAIN_TRACK_PEAK"] = [String(format: "%.6f", t.peak)]
				tags["REPLAYGAIN_ALBUM_GAIN"] = [String(format: "%.2f dB", r.albumGain)]
				tags["REPLAYGAIN_ALBUM_PEAK"] = [String(format: "%.6f", r.albumPeak)]
				tags["REPLAYGAIN_REFERENCE_LOUDNESS"] = ["-18.00 LUFS"]
			}
		}
		log(String(format: "Album gain %+.2f dB", r.albumGain))
	}

	/// Embedded JPEG/PNG pictures larger than `max` on either side are scaled down (ADR 0042/0074); returns the
	/// number of files rewritten. Undecodable or small pictures stay as they are.
	static func resizeCovers(files: [URL], max: Int) throws -> Int {
		var n = 0
		for u in files {
			var f = try AudioFile(url: u)
			var changed = false
			for (i, p) in f.pictures.enumerated() where ["image/jpeg", "image/png"].contains(p.mime) && p.data.count >= 100 {
				guard let (w, h) = ImageSize.of(p.data), Swift.max(w, h) > max, let (d, mime, nw, nh) = ImageSize.embeddable(p.data, max: max) else { continue }
				f.pictures[i] = Picture(type: p.type, mime: mime, desc: p.desc, width: UInt32(nw), height: UInt32(nh), data: d)
				changed = true
			}
			if changed { try f.save(); n += 1 }
		}
		return n
	}

	// MARK: 3. AcoustID fingerprints (native Chromaprint, ADR 0075)

	static func fingerprints(files: [URL], log: Log) throws {
		for f in files {
			try Task.checkCancellation()
			if let t = try? AudioFile(url: f).tags, !t.first("ACOUSTID_FINGERPRINT", "ACOUSTID FINGERPRINT").isEmpty { continue }
			let fp = try Chromaprint.fingerprint(url: f)
			try update([f]) { _, t in t["ACOUSTID FINGERPRINT"] = nil; t["ACOUSTID_FINGERPRINT"] = [fp] }
			log("fingerprint  \(f.lastPathComponent)")
		}
	}

	// MARK: 5. lyrics from LRCLIB (ADR 0021)

	static func lyrics(album: Album, log: Log) async throws {
		var stats = ["new": 0, "fixed": 0, "failed": 0, "none": 0]
		for t in album.tracks {
			try Task.checkCancellation()
			let tags = (try? AudioFile(url: t.url).tags) ?? t.tags
			let r = await Lrc.decide(tags: tags, length: t.info.duration, log: log, lookup: Lrc.lrclib)
			switch r.action {
			case "new", "fixed", "fix":
				try update([t.url]) { _, tags in tags["LYRICS"] = [r.lyrics]; tags["UNSYNCEDLYRICS"] = nil }
				stats[r.action == "new" ? "new" : "fixed", default: 0] += 1
				log((r.kind == "instrumental" ? "instrumental  " : r.action == "fix" ? "lyrics fixed  " : "\(r.kind.uppercased()) added  ") + t.title)
			case "failed": stats["failed", default: 0] += 1; log("lrclib did not answer  \(t.title)")
			case "error": log("skip \(t.url.lastPathComponent): ALBUMARTIST/ARTIST or TITLE is empty")
			default: if r.kind == "none" { stats["none", default: 0] += 1 }
			}
		}
		log("lyrics: \(stats["new"]!) new, \(stats["fixed"]!) fixed, \(stats["none"]!) not found" + (stats["failed"]! > 0 ? ", \(stats["failed"]!) lrclib failures (run again)" : ""))
	}

	// MARK: 6. filenames (ADR 0010)

	@discardableResult
	static func rename(album: Album, log: Log) throws -> Int {
		var n = 0
		let fm = FileManager.default
		for t in album.tracks {
			guard let new = Naming.blissName(((try? AudioFile(url: t.url).tags) ?? t.tags), suffix: t.suffix) else { log("skip \(t.url.lastPathComponent): title, track or disc is empty"); continue }
			if new == t.url.lastPathComponent { continue }
			let dest = t.url.deletingLastPathComponent().appendingPathComponent(new)
			if fm.fileExists(atPath: dest.path) && !Naming.sameName(dest.lastPathComponent, t.url.lastPathComponent) { log("skip \(t.url.lastPathComponent): \(new) already exists"); continue }
			try fm.moveItem(at: t.url, to: dest)
			log("renamed \(t.url.lastPathComponent) -> \(new)"); n += 1
		}
		return n
	}

	// MARK: move to library (ADR 0011, 0037, 0091)

	struct Plan { var moves: [(from: URL, to: URL)]; var folder: URL; var problems: [String] }

	static func movePlan(album: Album, library: URL, extra: [String] = [], template: LibTemplate.Template = LibrarySettings.load().template) -> Plan {
		var problems: [String] = extra.map { $0 + " Fix the release before moving." }
		var moves: [(URL, URL)] = []
		var seen = Set<String>()
		var folder = library
		var folderSet = false
		for t in album.tracks {
			let tags = t.tags.mapValues { $0.first ?? "" }
			do {
				let g = try LibTemplate.target(template, tags, suffix: "." + (t.url.pathExtension.isEmpty ? "flac" : t.url.pathExtension.lowercased()))
				let albumDir = g.albumDir.reduce(library) { $0.appendingPathComponent($1) }
				if !folderSet { folder = albumDir; folderSet = true }
				let dir = album.multiDisc && !g.discDir.isEmpty ? albumDir.appendingPathComponent(g.discDir) : albumDir
				let dest = dir.appendingPathComponent(g.filename)
				if FileManager.default.fileExists(atPath: dest.path) { problems.append("\(dest.lastPathComponent) already exists in the library") }
				if !seen.insert(dest.path.lowercased()).inserted { problems.append("two files want the name \(g.filename)") }
				moves.append((t.url, dest))
			} catch let e as LibTemplate.MissingTag {
				problems.append(t.url.lastPathComponent + ": " + (e.tag == "ALBUMARTIST" || e.tag == "ALBUM" || e.tag == "ALBUM_VERSION" ? "\(e.tag) is empty" : "\(e.tag) is empty (title, track or disc)"))
			} catch { problems.append("\(t.url.lastPathComponent): a name is empty after cleaning") }
		}
		if moves.isEmpty && problems.isEmpty { problems.append("no files to move") }
		if !album.canMove { problems.insert(album.status != .fixed ? "Album is not fixed" : "Cover is missing or too small", at: 0) }
		return Plan(moves: moves, folder: folder, problems: problems)
	}

	static func move(album: Album, library: URL, deleteSource: Bool, log: Log) throws {
		let plan = movePlan(album: album, library: library)
		guard plan.problems.isEmpty else { throw StepError(plan.problems[0]) }
		let fm = FileManager.default
		let art = Artwork.read(album.tracks.map(\.url))   // read before the files move away
		for (a, b) in plan.moves {
			try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
			try fm.moveItem(at: a, to: b)
			log("moved \(b.lastPathComponent)")
		}
		Artwork.export(art, target: plan.folder, log: log)   // ADR 0091: cover files from the embedded art
		if deleteSource { try? fm.removeItem(at: album.url) }
	}
}

private extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
