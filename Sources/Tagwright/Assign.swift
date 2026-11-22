import Foundation

/// Discogs tags step and track assignment (ADR 0013, 0053, 0078, 0079, 0080), a port of the web app's fixtags.py.
enum Assign {
	static let catalogSpellings = ["CATALOGNUMBER", "CATALOG NUMBER", "CATALOG_NUMBER", "CATALOGNO"]
	static let managedOptional = ["ALBUM_EDITION", "ALBUM_DR", "ALBUM_RELEASE_YEAR", "ALBUM_RELEASE_COUNTRY", "ALBUM_RELEASE_LABEL"]
	static let extraFixed = ["ALBUM_RELEASE_LABELS", "ALBUM_RELEASE_CATALOGNUMBERS", "ALBUM_RELEASE_FORMAT", "ALBUM_RELEASE_FORMAT_DESCRIPTIONS", "ALBUM_RELEASE_FORMAT_TEXT",
		"ALBUM_RELEASE_GENRES", "ALBUM_RELEASE_STYLES", "ALBUM_RELEASE_NOTES", "ALBUM_RELEASE_DATE_FULL", "ALBUM_RELEASE_DATA_QUALITY", "ALBUM_RELEASE_SERIES"]
	static let extraPrefixes = ["ALBUM_COMPANY_", "ALBUM_CREDIT_", "ALBUM_IDENT_"]

	static func maxResolution(_ hz: Int) -> String {
		hz <= 0 ? "44.1kHz" : String(format: "%.1fkHz", Double(hz) / 1000).replacingOccurrences(of: ".0kHz", with: "kHz")
	}

	/// The album-level tags every file should carry (fixtags.plan_tags).
	static func plan(first: Tags, release r: [String: Any], masterTitle: String, masterYear: Int?, maxRate: Int) -> Tags {
		let releaseTitle = (r["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
		let albumName = first.first("ALBUM_TITLE_OVERRIDE").isEmpty ? masterTitle : first.first("ALBUM_TITLE_OVERRIDE")
		let override = first.first("ALBUM_ARTIST_OVERRIDE").trimmingCharacters(in: .whitespaces)
		let albumArtist = override.isEmpty ? Discogs.artistNames(r["artists"] as? [[String: Any]] ?? []) : override
		let releaseYear = (r["year"] as? Int) ?? 0
		var yearRelease = releaseYear, yearMaster = masterYear ?? 0
		if yearRelease == 0 && yearMaster != 0 { yearRelease = yearMaster }
		if yearRelease != 0 && yearMaster == 0 { yearMaster = yearRelease }
		let format = !first.first("ALBUM_FORMAT").isEmpty ? first.first("ALBUM_FORMAT") : (!first.first("SUBTITLE").isEmpty ? first.first("SUBTITLE") : "CD")
		let edition = first.first("ALBUM_EDITION"), dr = first.first("ALBUM_DR"), catalog = first.first(catalogSpellings[0], catalogSpellings[1], catalogSpellings[2], catalogSpellings[3])
		let version = Naming.versionString(year: yearRelease == 0 ? "" : "\(yearRelease)", dr: dr, format: format, edition: edition, catalog: catalog)
		var t: Tags = [
			"RELEASEDATE": ["\(yearRelease)"], "DATE": ["\(yearRelease)"], "YEAR": ["\(yearRelease)"],
			"ORIGINALDATE": ["\(yearMaster)"], "ORIGINALRELEASEDATE": ["\(yearMaster)"], "ORIGINAL DATE": ["\(yearMaster)"], "ORIGINAL YEAR": ["\(yearMaster)"],
			"ALBUM_MASTER_TITLE": [masterTitle], "ALBUM_RELEASE_TITLE": [releaseTitle], "ALBUM_MASTER_YEAR": ["\(yearMaster)"], "ALBUM_FORMAT": [format],
			"ALBUM_MAX_RESOLUTION": [maxResolution(maxRate)], "ALBUM": [albumName], "VERSION": [version], "ORIGINAL_TITLE": [masterTitle],
		]
		if releaseYear != 0 { t["ALBUM_RELEASE_YEAR"] = ["\(releaseYear)"] }
		if !edition.isEmpty { t["ALBUM_EDITION"] = [edition] }
		if !dr.isEmpty { t["ALBUM_DR"] = [dr] }
		if !albumArtist.isEmpty { t["ALBUMARTIST"] = [albumArtist] }
		if let c = (r["country"] as? String)?.trimmingCharacters(in: .whitespaces), !c.isEmpty { t["ALBUM_RELEASE_COUNTRY"] = [c] }
		if let l = ((r["labels"] as? [[String: Any]])?.first?["name"] as? String)?.trimmingCharacters(in: .whitespaces), !l.isEmpty { t["ALBUM_RELEASE_LABEL"] = [l] }
		for (k, v) in Discogs.extraTags(r) { t[k] = v }
		return t
	}

	/// The Tags & cover step: rewrite every file with the Discogs data (fixtags.fix_album). The album must have a release ID.
	static func fixTags(album: Album, log: Log) async throws {
		guard let firstURL = album.tracks.first?.url, let first = try? AudioFile(url: firstURL).tags else { throw StepError("No readable file") }
		guard let id = Int(first.first("DISCOGS_RELEASE_ID")) else { throw StepError("No Discogs release ID") }
		let r = try await Discogs.release(id)
		let (mTitle, mYear) = await Discogs.master(of: r)
		let maxRate = album.tracks.map(\.info.sampleRate).max() ?? 44100
		let plan = Self.plan(first: first, release: r, masterTitle: mTitle, masterYear: mYear, maxRate: maxRate)
		let urls = album.tracks.map(\.url)
		let mbid = first.first("MUSICBRAINZ_ALBUMID", "MUSICBRAINZ ALBUM ID").trimmingCharacters(in: .whitespaces)
		let langs = mbid.isEmpty ? nil : await MusicBrainz.trackLanguages(mbid)
		if !mbid.isEmpty, langs == nil { log("MusicBrainz lookup failed for \(mbid): LYRICS_LANGUAGE left as it is") }
		let maxCover = UserDefaults.standard.object(forKey: "maxCover") as? Int ?? 1500
		let changed = try await Task.detached { () -> Int in
			var n = 0
			try Pipeline.update(urls) { _, t in
				let before = t
				for k in managedOptional + extraFixed + t.keys.filter({ k in extraPrefixes.contains { k.hasPrefix($0) } }) where plan[k] == nil { t[k] = nil }
				for (k, v) in plan { t[k] = v }
				for k in ["WORK", "PART"] { t[k] = nil }
				let set = t.first("SET SUBTITLE").trimmingCharacters(in: .whitespaces)
				t["DISCSUBTITLE"] = set.isEmpty ? nil : [set]
				// A matched track with no sung language loses the tag, except the instrumental marker of the lyrics step.
				if let langs, let m = MusicBrainz.findTrack(langs, tags: t) {
					if !m.languages.isEmpty { t["LYRICS_LANGUAGE"] = m.languages }
					else if t.first("LYRICS_LANGUAGE").lowercased() != "zxx" { t["LYRICS_LANGUAGE"] = nil }
				}
				if NSDictionary(dictionary: before) != NSDictionary(dictionary: t) { n += 1 }
			}
			return n
		}.value
		let resized = try await Task.detached { try Pipeline.resizeCovers(files: urls, max: maxCover) }.value
		if resized > 0 { log("Album art resized to at most \(maxCover) px in \(resized) files") }
		log("Discogs tags refreshed on \(changed) of \(urls.count) files [\(plan["VERSION"]?.first ?? "")]")
	}

	// MARK: proposal (ADR 0053: title 0.6, duration 0.25 within 8 s, same disc/track 0.15, threshold 0.35, greedy)

	static func similarity(_ a: String, _ b: String) -> Double {
		let x = Array(Naming.clean(a).lowercased()), y = Array(Naming.clean(b).lowercased())
		if x.isEmpty || y.isEmpty { return 0 }
		var prev = Array(0...y.count)
		for i in 1...x.count {
			var cur = [i] + [Int](repeating: 0, count: y.count)
			for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
			prev = cur
		}
		return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
	}

	/// For every file the index of its release track, or nil.
	static func propose(files: [Track], release: [DTrack]) -> [Int?] { proposeScored(files: files, release: release).map(\.0) }

	/// The proposal with each file's score; the dialogs show "match" from 0.6, "check" below (web conf).
	static func proposeScored(files: [Track], release: [DTrack]) -> [(Int?, Double)] {
		var scores: [(Double, Int, Int)] = []
		for (i, f) in files.enumerated() {
			for (j, t) in release.enumerated() {
				var s = similarity(f.title, t.title) * 0.6
				if t.seconds > 0, abs(Int(f.info.duration.rounded()) - t.seconds) <= 8 { s += 0.25 * (1 - Double(abs(Int(f.info.duration.rounded()) - t.seconds)) / 8) }
				if Int(f.disc) == t.disc && Int(f.number) == t.number { s += 0.15 }
				scores.append((s, i, j))
			}
		}
		var out = [(Int?, Double)](repeating: (nil, 0), count: files.count), usedT = Set<Int>()
		for (s, i, j) in scores.sorted(by: { $0.0 > $1.0 }) where s >= 0.35 && out[i].0 == nil && !usedT.contains(j) { out[i] = (j, (s * 100).rounded() / 100); usedT.insert(j) }
		return out
	}

	// MARK: apply (ADR 0053, 0078, 0079, 0080)

	struct Item { var url: URL; var track: DTrack; var disc: Int; var number: Int; var title: String; var subtitle = "" }

	static func apply(album: Album, release r: [String: Any], id: Int, items: [Item], importTitles: Bool, total: (disc: [Int: Int], discs: Int)) async throws {
		let artists = Discogs.artistNames(r["artists"] as? [[String: Any]] ?? [])
		let labels = r["labels"] as? [[String: Any]] ?? []
		let fmts = (r["formats"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.filter { !["Box Set", "All Media"].contains($0) }
		let cat = (labels.first?["catno"] as? String ?? "").trimmingCharacters(in: .whitespaces)
		var realCat = cat
		if cat.lowercased() == "none" || cat.isEmpty { realCat = labels.compactMap { $0["catno"] as? String }.first { $0.lowercased() != "none" && !$0.isEmpty } ?? "none" }
		let player = Discogs.playerTags(r), owned = Discogs.discogsTags(r)
		let image = album.cover == nil ? await Discogs.imageData(r) : nil
		let byURL = Dictionary(uniqueKeysWithValues: items.map { ($0.url.path, $0) })
		let urls = items.map(\.url)
		try await Task.detached {
			try Pipeline.update(urls) { url, t in
				guard let it = byURL[url.path] else { return }
				t["DISCOGS_RELEASE_ID"] = ["\(id)"]
				if t.first("ALBUM_ARTIST_OVERRIDE").isEmpty, !artists.isEmpty { t["ALBUMARTIST"] = [artists] }
				if t.first("ALBUM_FORMAT_OVERRIDE").isEmpty, let f = fmts.first { t["ALBUM_FORMAT"] = [f] }
				if t.first("CATALOGNUMBER_OVERRIDE").isEmpty {
					for k in catalogSpellings { t[k] = nil }
					t["CATALOGNUMBER"] = [realCat]
				}
				// ADR 0080 / app.py tracks_apply: the release leads its player tags (replaced, so a re-assignment
				// leaves nothing of the previous release); nothing is written where the release has no value
				for (k, v) in player where !["COMPOSER", "PRODUCER", "ENGINEER"].contains(k) { t[k] = v }
				for (k, roles) in [("COMPOSER", it.track.writers), ("PRODUCER", it.track.producers), ("ENGINEER", it.track.engineers)] {
					let v = roles.isEmpty ? (player[k] ?? []) : roles
					if !v.isEmpty { t[k] = v }
				}
				for k in t.keys where k.hasPrefix("DISCOGS_") && k != "DISCOGS_RELEASE_ID" { t[k] = nil }   // Discogs-owned: this release's only
				for (k, v) in owned { t[k] = v }
				t["DISCOGS_RELEASE_ORDINAL_POSITION"] = ["\(it.track.id)"]
				if !it.track.position.isEmpty { t["TRACK_NUMBER_TEXT"] = [it.track.position] }
				if importTitles {
					t["TITLE"] = [it.title]; t["ARTIST"] = [it.track.artist.isEmpty ? artists : it.track.artist]
					t["TRACKNUMBER"] = ["\(it.number)"]; t["DISCNUMBER"] = ["\(it.disc)"]
					t["TRACKTOTAL"] = ["\(total.disc[it.disc] ?? 0)"]; t["TOTALTRACKS"] = ["\(total.disc[it.disc] ?? 0)"]
					t["DISCTOTAL"] = ["\(total.discs)"]; t["TOTALDISCS"] = ["\(total.discs)"]
					if !it.subtitle.isEmpty { t["SET SUBTITLE"] = [it.subtitle] }
				} else {
					if t.first("TITLE").isEmpty { t["TITLE"] = [it.title] }
					if t.first("DISCNUMBER").isEmpty { t["DISCNUMBER"] = ["\(it.disc)"] }
					if t.first("TRACKNUMBER").isEmpty { t["TRACKNUMBER"] = ["\(it.number)"] }
					if t.first("ARTIST").isEmpty { t["ARTIST"] = [it.track.artist.isEmpty ? artists : it.track.artist] }
				}
			}
			if let image, let first = urls.first, ImageSize.of(image) != nil {
				var f = try AudioFile(url: first)
				if f.pictures.isEmpty { for u in urls { var g = try AudioFile(url: u); g.pictures.append(Picture(type: 3, mime: image.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg", desc: "", width: UInt32(ImageSize.of(image)!.0), height: UInt32(ImageSize.of(image)!.1), data: image)); try g.save() } }
				_ = f
			}
		}.value
	}
}
