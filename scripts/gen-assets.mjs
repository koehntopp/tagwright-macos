// Generates Sources/Tagwright/Assets.swift: lucide icons (from the web app's lucide-react) and the web app's static images.
import fs from 'fs'
const web = '/Users/koehntopp/src/tagwright', out = process.argv[2]
// the component names the web UI imports from lucide-react
const components = ['Pencil','Play','Pause','Copy','RefreshCw','LayoutGrid','List','Search','Settings','Square','ChartColumn','Volume2','Fingerprint','Tags','Mic','FileText','Check','TriangleAlert','OctagonX','ChevronDown','Ellipsis','Upload','ClipboardPaste','Trash2','X','Plus','GripVertical','RotateCw','Loader2']
const index = fs.readFileSync(`${web}/ui/node_modules/lucide-react/dist/esm/lucide-react.mjs`, 'utf8')
const fileOf = c => index.match(new RegExp(`default as ${c},[^\\n]*from './icons/([a-z0-9-]+)\\.mjs'`))[1]
const names = components.map(fileOf)
const esc = s => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
let icons = []
for (const n of names) {
  const src = fs.readFileSync(`${web}/ui/node_modules/lucide-react/dist/esm/icons/${n}.mjs`, 'utf8')
  const m = src.match(/const __iconData = (\{[\s\S]*?\n\});/)
  const node = Function('return ' + m[1])().node
  const svg = node.map(([tag, attrs]) => `<${tag} ${Object.entries(attrs).filter(([k]) => k !== 'key').map(([k, v]) => `${k}="${v}"`).join(' ')}/>`).join('')
  const c = components[names.indexOf(n)], id = c[0].toLowerCase() + c.slice(1)
  icons.push(`\t\tcase .${id}: "${esc(svg)}"`)
  names[names.indexOf(n)] = id
}
const assets = { logo: 'icon.svg', discogs: 'discogs.png', musicbrainz: 'musicbrainz.ico', lrclib: 'lrclib.ico', musichoarders: 'musichoarders.svg', albumartexchange: 'albumartexchange.ico' }
const data = Object.entries(assets).map(([k, f]) => `\t\tcase .${k}: "${fs.readFileSync(`${web}/static/${f}`).toString('base64')}"`)
fs.writeFileSync(out, `import AppKit

// Generated from the web app (ui/node_modules/lucide-react 1.71, ISC licence; static/*): do not edit by hand.

/// The web app's lucide icons: outline glyphs, 2 px stroke on a 24 px grid, drawn from SVG as template images.
enum Lucide: String, CaseIterable {
	case ${names.join(', ')}
	var body: String {
		switch self {
${icons.join('\n')}
		}
	}
	@MainActor private static var cache: [Lucide: NSImage] = [:]
	@MainActor var image: NSImage {
		if let i = Self.cache[self] { return i }
		let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">"# + body + "</svg>"
		let i = NSImage(data: Data(svg.utf8)) ?? NSImage()
		i.isTemplate = true
		Self.cache[self] = i
		return i
	}
}

/// The web app's static images: logo and service icons.
enum Asset: CaseIterable {
	case ${Object.keys(assets).join(', ')}
	private var base64: String {
		switch self {
${data.join('\n')}
		}
	}
	@MainActor private static var cache: [Asset: NSImage] = [:]
	@MainActor var image: NSImage {
		if let i = Self.cache[self] { return i }
		let i = Data(base64Encoded: base64).flatMap(NSImage.init(data:)) ?? NSImage()
		Self.cache[self] = i
		return i
	}
}
`)
console.log(names.length, 'icons', Object.keys(assets).length, 'assets')
