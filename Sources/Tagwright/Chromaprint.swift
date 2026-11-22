import AVFoundation

/// AcoustID fingerprints (Chromaprint algorithm 2, "test2" preset), natively: a Swift port of rusty-chromaprint
/// (MIT), which is what fpscan uses (ADR 0075). Decoding and resampling to 11025 Hz mono go through AVFoundation,
/// so the result differs from fpcalc's in about 0.03 % of the bits (measured on five albums, `testAgainstFpcalc`).
enum Chromaprint {
	static let rate = 11025.0
	static let frameSize = 4096
	static let frameOverlap = 4096 - 4096 / 3
	static let minFreq = 28.0, maxFreq = 3520.0
	static let coefficients: [Double] = [0.25, 0.75, 1.0, 0.75, 0.25]

	struct Classifier { var kind: Int, y: Int, h: Int, w: Int, t0: Double, t1: Double, t2: Double }
	/// (filter kind, y, height, width, quantizer thresholds) of the 16 classifiers of preset test2.
	static let classifiers: [Classifier] = [
		(0, 4, 3, 15, 1.98215, 2.35817, 2.63523), (4, 4, 6, 15, -1.03809, -0.651211, -0.282167), (1, 0, 4, 16, -0.298702, 0.119262, 0.558497),
		(3, 8, 2, 12, -0.105439, 0.0153946, 0.135898), (3, 4, 4, 8, -0.142891, 0.0258736, 0.200632), (4, 0, 3, 5, -0.826319, -0.590612, -0.368214),
		(1, 2, 2, 9, -0.557409, -0.233035, 0.0534525), (2, 7, 3, 4, -0.0646826, 0.00620476, 0.0784847), (2, 6, 2, 16, -0.192387, -0.029699, 0.215855),
		(2, 1, 3, 2, -0.0397818, -0.00568076, 0.0292026), (5, 10, 1, 15, -0.53823, -0.369934, -0.190235), (3, 6, 2, 10, -0.124877, 0.0296483, 0.139239),
		(2, 1, 1, 14, -0.101475, 0.0225617, 0.231971), (3, 5, 6, 4, -0.0799915, -0.00729616, 0.063262), (1, 9, 2, 12, -0.272556, 0.019424, 0.302559),
		(3, 4, 2, 14, -0.164292, -0.0321188, 0.0846339),
	].map { Classifier(kind: $0.0, y: $0.1, h: $0.2, w: $0.3, t0: $0.4, t1: $0.5, t2: $0.6) }

	// MARK: samples -> sub-fingerprints

	/// Sub-fingerprints (one 32-bit value per 1365 samples) of mono samples at 11025 Hz.
	static func subFingerprints(_ samples: [Float]) -> [UInt32] {
		let n = frameSize
		let window = (0..<n).map { 0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
		let minIndex = max(1, Int((Double(n) * minFreq / rate).rounded())), maxIndex = min(n / 2, Int((Double(n) * maxFreq / rate).rounded()))
		var notes = [Int](repeating: 0, count: n)
		for i in minIndex..<maxIndex {
			let octave = log2(Double(i) * rate / Double(n) / (440.0 / 16.0))
			notes[i] = Int((12 * (octave - octave.rounded(.down))).rounded(.down))
		}
		var fft = FFT(n)
		var re = [Double](repeating: 0, count: n), im = re
		var chromaRows: [[Double]] = []   // after the 5-row blur, normalised
		var raw: [[Double]] = []
		var integral: [[Double]] = []
		var maxW = classifiers.map(\.w).max()!
		maxW = max(maxW, 1)
		var out: [UInt32] = []
		var start = 0
		while start + n <= samples.count {
			for i in 0..<n { re[i] = Double(samples[start + i]) * window[i]; im[i] = 0 }
			fft.transform(&re, &im)
			var f = [Double](repeating: 0, count: 12)
			for i in minIndex..<maxIndex { f[notes[i]] += re[i] * re[i] + im[i] * im[i] }
			raw.append(f)
			if raw.count >= coefficients.count {
				var r = [Double](repeating: 0, count: 12)
				for i in 0..<12 { for j in 0..<coefficients.count { r[i] += raw[raw.count - coefficients.count + j][i] * coefficients[j] } }
				let norm = r.reduce(0) { $0 + $1 * $1 }.squareRoot()
				if norm < 0.01 { r = [Double](repeating: 0, count: 12) } else { for i in 0..<12 { r[i] /= norm } }
				chromaRows.append(r)
				// integral image: cumulative over columns, then over rows
				var row = [Double](repeating: 0, count: 12), s = 0.0
				for i in 0..<12 { s += r[i]; row[i] = s + (integral.last?[i] ?? 0) }
				integral.append(row)
				if integral.count >= maxW { out.append(subFingerprint(integral, offset: integral.count - maxW)) }
			}
			start += n - frameOverlap
		}
		return out
	}

	/// Sum of the cells [r1, r2) x [c1, c2) from the integral image.
	private static func area(_ im: [[Double]], _ r1: Int, _ c1: Int, _ r2: Int, _ c2: Int) -> Double {
		if r1 == r2 || c1 == c2 { return 0 }
		if r1 == 0 { return c1 == 0 ? im[r2 - 1][c2 - 1] : im[r2 - 1][c2 - 1] - im[r2 - 1][c1 - 1] }
		return c1 == 0 ? im[r2 - 1][c2 - 1] - im[r1 - 1][c2 - 1] : im[r2 - 1][c2 - 1] - im[r1 - 1][c2 - 1] - im[r2 - 1][c1 - 1] + im[r1 - 1][c1 - 1]
	}

	private static func subFingerprint(_ im: [[Double]], offset x: Int) -> UInt32 {
		var bits: UInt32 = 0
		for c in classifiers {
			let y = c.y, w = c.w, h = c.h
			let a: Double, b: Double
			switch c.kind {
			case 0: a = area(im, x, y, x + w, y + h); b = 0
			case 1: let h2 = h / 2; a = area(im, x, y + h2, x + w, y + h); b = area(im, x, y, x + w, y + h2)
			case 2: let w2 = w / 2; a = area(im, x + w2, y, x + w, y + h); b = area(im, x, y, x + w2, y + h)
			case 3:
				let w2 = w / 2, h2 = h / 2
				a = area(im, x, y + h2, x + w2, y + h) + area(im, x + w2, y, x + w, y + h2)
				b = area(im, x, y, x + w2, y + h2) + area(im, x + w2, y + h2, x + w, y + h)
			case 4: let h3 = h / 3; a = area(im, x, y + h3, x + w, y + 2 * h3); b = area(im, x, y, x + w, y + h3) + area(im, x, y + 2 * h3, x + w, y + h)
			default: let w3 = w / 3; a = area(im, x + w3, y, x + 2 * w3, y + h); b = area(im, x, y, x + w3, y + h) + area(im, x + 2 * w3, y, x + w, y + h)
			}
			let v = log((1 + a) / (1 + b))
			let q: UInt32 = v < c.t1 ? (v < c.t0 ? 0 : 1) : (v < c.t2 ? 2 : 3)
			bits = (bits << 2) | [0, 1, 3, 2][Int(q)]
		}
		return bits
	}

	// MARK: compression and encoding (algorithm id 1)

	static func compress(_ fp: [UInt32]) -> [UInt8] {
		var normal: [UInt8] = [], exceptional: [UInt8] = []
		var last: UInt32 = 0
		for cur in fp {
			let v = cur ^ last; last = cur
			var lastBit = 0
			for i in 0..<32 where (v >> UInt32(i)) & 1 == 1 {
				let bit = i + 1, d = bit - lastBit
				if d >= 7 { normal.append(7); exceptional.append(UInt8(d - 7)) } else { normal.append(UInt8(d)) }
				lastBit = bit
			}
			normal.append(0)
		}
		let size = fp.count
		return [1, UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)] + pack(normal, 3) + pack(exceptional, 5)
	}

	/// Values of N bits each, least significant bit first; the last byte is padded with zeros.
	private static func pack(_ v: [UInt8], _ n: Int) -> [UInt8] {
		var out: [UInt8] = [], acc = 0, bits = 0
		for x in v {
			acc |= (Int(x) & ((1 << n) - 1)) << bits; bits += n
			while bits >= 8 { out.append(UInt8(acc & 0xFF)); acc >>= 8; bits -= 8 }
		}
		if bits > 0 { out.append(UInt8(acc & 0xFF)) }
		return out
	}

	static func base64url(_ d: [UInt8]) -> String {
		Data(d).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
	}

	// MARK: decoding

	/// The fingerprint of the first `seconds` of a file.
	static func fingerprint(url: URL, seconds: Double = 120) throws -> String {
		let fp = subFingerprints(try fingerprintSamples(url: url, seconds: seconds))
		guard !fp.isEmpty else { throw StepError("\(url.lastPathComponent) is too short to fingerprint") }
		return base64url(compress(fp))
	}

	/// Mono samples of the first `seconds` at 11025 Hz.
	static func fingerprintSamples(url: URL, seconds: Double) throws -> [Float] {
		let af = try AVAudioFile(forReading: url)
		let fmt = af.processingFormat, ch = Int(fmt.channelCount), sr = fmt.sampleRate
		guard sr > 1000, ch > 0 else { throw StepError("\(url.lastPathComponent): unsupported audio format") }
		let want = AVAudioFrameCount(min(Double(af.length), sr * seconds))
		guard want > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: want) else { throw StepError("\(url.lastPathComponent) has no audio") }
		do { try af.read(into: buf, frameCount: want) } catch { if buf.frameLength == 0 { throw error } }   // a damaged tail ends the audio (ADR 0073)
		let n = Int(buf.frameLength)
		var mono = [Float](repeating: 0, count: n)
		let data = buf.floatChannelData!
		let w = monoWeights(ch)
		for c in 0..<ch { let k = w[c]; if k != 0 { for i in 0..<n { mono[i] += data[c][i] * k } } }

		var samples = mono
		if sr != rate {
			let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
			let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
			guard let conv = AVAudioConverter(from: inF, to: outF), let src = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(n)) else { throw StepError("cannot resample \(url.lastPathComponent)") }
			conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
			conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
			src.frameLength = AVAudioFrameCount(n)
			mono.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
			samples = []
			let chunk = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: 65536)!
			var given = false
			while true {
				var err: NSError?
				let st = conv.convert(to: chunk, error: &err) { _, status in
					if given { status.pointee = .endOfStream; return nil }
					given = true; status.pointee = .haveData; return src
				}
				if st == .error { throw err ?? StepError("cannot resample \(url.lastPathComponent)") }
				samples += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
				if st == .endOfStream || (st == .inputRanDry && chunk.frameLength == 0) { break }
				if chunk.frameLength == 0 && given { break }
			}
		}
		return samples
	}

	/// The raw sub-fingerprints (what `fpcalc -raw` prints), for comparisons.
	static func raw(url: URL, seconds: Double = 120) throws -> [UInt32] {
		let s = try fingerprintSamples(url: url, seconds: seconds)
		return subFingerprints(s)
	}

	/// Mono mix as fpcalc gets it through FFmpeg's default downmix (centre and surrounds at -3 dB, LFE dropped,
	/// stereo then averaged); a plain average of all channels differs by 5-8 % of the bits on 5.1 and 7.1 files.
	/// Channel order as FLAC stores it: L R C LFE BL BR (SL SR).
	static func monoWeights(_ n: Int) -> [Float] {
		let h: Float = 0.70710678
		let (w, side): ([Float], Float)
		switch n {
		case 1: return [1]
		case 2: return [0.5, 0.5]
		case 3: (w, side) = ([1, 1, 2 * h], 1 + h)
		case 4: (w, side) = ([1, 1, h, h], 1 + h)
		case 5: (w, side) = ([1, 1, 2 * h, h, h], 1 + 2 * h)
		case 6: (w, side) = ([1, 1, 2 * h, 0, h, h], 1 + 2 * h)
		case 7: (w, side) = ([1, 1, 2 * h, 0, 2 * h, h, h], 1 + 3 * h)
		case 8: (w, side) = ([1, 1, 2 * h, 0, h, h, h, h], 1 + 3 * h)
		default: return [Float](repeating: 1 / Float(n), count: n)
		}
		return w.map { $0 * 0.5 / side }
	}

	// MARK: radix-2 FFT

	struct FFT {
		let n: Int
		private var cosT: [Double], sinT: [Double], rev: [Int]
		init(_ n: Int) {
			self.n = n
			cosT = (0..<n / 2).map { cos(2 * Double.pi * Double($0) / Double(n)) }
			sinT = (0..<n / 2).map { -sin(2 * Double.pi * Double($0) / Double(n)) }
			var bits = 0; while 1 << bits < n { bits += 1 }
			rev = (0..<n).map { i in var r = 0; for b in 0..<bits where i >> b & 1 == 1 { r |= 1 << (bits - 1 - b) }; return r }
		}
		func transform(_ re: inout [Double], _ im: inout [Double]) {
			for i in 0..<n where i < rev[i] { re.swapAt(i, rev[i]); im.swapAt(i, rev[i]) }
			var len = 2
			while len <= n {
				let half = len / 2, step = n / len
				var i = 0
				while i < n {
					for j in 0..<half {
						let c = cosT[j * step], s = sinT[j * step]
						let a = i + j, b = a + half
						let tr = re[b] * c - im[b] * s, ti = re[b] * s + im[b] * c
						re[b] = re[a] - tr; im[b] = im[a] - ti
						re[a] += tr; im[a] += ti
					}
					i += len
				}
				len <<= 1
			}
		}
	}
}
