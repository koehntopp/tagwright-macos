import AppKit
import ImageIO

enum ImageSize {
	static func of(_ d: Data) -> (Int, Int)? {
		guard let s = CGImageSourceCreateWithData(d as CFData, nil),
			let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
			let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
		return (w, h)
	}

	/// Downscaled copy for lists; the full data stays in the model.
	static func thumbnail(_ d: Data, max: Int) -> NSImage? {
		guard let s = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
		let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max]
		guard let c = CGImageSourceCreateThumbnailAtIndex(s, 0, o as CFDictionary) else { return nil }
		return NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
	}

	/// Cover for embedding: scaled down to `max` on the longer side (ADR 0042), JPEG unless the source is PNG at size.
	static func embeddable(_ d: Data, max: Int) -> (Data, String, Int, Int)? {
		guard let s = CGImageSourceCreateWithData(d as CFData, nil), let (w, h) = of(d) else { return nil }
		let isPNG = d.starts(with: [0x89, 0x50])
		if Swift.max(w, h) <= max { return (d, isPNG ? "image/png" : "image/jpeg", w, h) }
		let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max]
		guard let c = CGImageSourceCreateThumbnailAtIndex(s, 0, o as CFDictionary) else { return nil }
		let rep = NSBitmapImageRep(cgImage: c)
		guard let out = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { return nil }
		return (out, "image/jpeg", c.width, c.height)
	}
}
