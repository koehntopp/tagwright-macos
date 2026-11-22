// Renders the web app's static/icon.svg into Resources/AppIcon.icns (macOS grid: 824 px artwork on a 1024 px canvas).
// Run: swift scripts/make-icon.swift ../tagwright/static/icon.svg Resources/AppIcon.icns
import AppKit

let a = CommandLine.arguments
guard a.count == 3, let svg = NSImage(contentsOfFile: a[1]) else { fatalError("usage: make-icon.swift <icon.svg> <out.icns>") }
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (pt, scale) in [16, 32, 128, 256, 512].flatMap({ p in [(p, 1), (p, 2)] }) {
	let px = pt * scale
	let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
	NSGraphicsContext.current?.imageInterpolation = .high
	let s = CGFloat(px) * 824 / 1024, o = (CGFloat(px) - s) / 2
	let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.shadowBlurRadius = CGFloat(px) * 10 / 1024; shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(px) * 10 / 1024); shadow.set()
	svg.draw(in: NSRect(x: o, y: o, width: s, height: s))
	NSGraphicsContext.restoreGraphicsState()
	let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
	try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", set.path, "-o", a[2]]
try p.run(); p.waitUntilExit()
print(a[2])
