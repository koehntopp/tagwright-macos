# Gaps against the web app (ADRs and CHANGELOG up to 0093)

Done in this port: status model and steps (0054), bliss names (0010), layout and move (0011/0037), top bar, Staging/Library switch, cards and list (0031/0038/0085-0087), inspector with unified notes (0083), four artwork fields with drop/paste (0090/0092), Discogs release search and assignment with proposal, Import song titles, rate limiting, track counts, MusicBrainz match (0013/0053/0078-0080), MusicBrainz search and assignment with Discogs-ID/barcode/catalogue matches and year/Discogs-link/track-count checks (0023/0083), Tags & cover step ported from fixtags.py (0036), tag editor with five tabs, overrides, drag renumbering and read-only tag tabs (0014/0057), lyrics editor (0015/0021), leftover-folder dialog (0072), playback marker and stop (0015/0068), double-click runs one step (0051), stored album summaries for Staging and Library (0067, `Summaries.swift`: binary plist in Application Support, one entry per folder keyed by path/mtime/size of every FLAC and the folder image, 640 px cover thumbnail, fingerprint values replaced by a marker; artwork is read when an album is selected or moved; `Summaries.version` replaces SUMMARY_VERSION).

## Still missing
Nothing known. Sync with the web app: `SYNC` holds the web commit the port matches; `scripts/sync-check` lists newer web changes (see CLAUDE.md).

Tested by hand 2026-11-22 (driven through Accessibility on scratch copies: Chicago 17 FLAC, ELO 2-disc, a 3-track MP3 album): list sort, column resize (kept), row and card hover, Run fixes on MP3 (all six steps, checked with mutagen), lyrics search list, LRC pick and save, tag editor Tracks tab (shift-click range, Set, Renumber, Clear, drag reorder, + divider here, Return, Save with rename), Edit album set and clear (Discogs restore), Discogs search list, track counts, select, re-assign, MusicBrainz apply, cover paste via the menu, back cover delete, Remove cover dialog, image drop from Finder, Settings save, Library tab chip drag and reorder, Move to library with folder.jpg, leftover dialog delete, playback with the Stop pill and card badge, Esc closes dialogs.
Fixed from that run: lrclib time badges truncated; a new divider field did not take focus; the top-bar search kept focus under an open dialog; Return in a dialog field triggered the primary button instead of the field (removed, as in the web dialogs); Markdown italics in two hint texts; oversized icons in the cover menu.

Done 2026-11-22:
- Re-assignment (0053/0080): the release's player tags lead; the previous release's DISCOGS_* tags are removed and the new ones written, with DISCOGS_RELEASE_ORDINAL_POSITION and TRACK_NUMBER_TEXT. Checked against the web's own release_tags() on two releases (`ReleaseTagsTests`). The Discogs master ID reaches the summaries with the other tags.
- Artwork sidecars (0091, `Artwork.swift`): folder.jpg and numbered Artwork/ files at Move to library and after a watcher move, listed in the Move dialog, never overwritten.
- MusicBrainz release lookups cached on disk for 30 days (~/Library/Caches/Tagwright/musicbrainz).
- lrclib pacing, circuit breaker and retry rounds (`LrcPacer`).
- ReplayGain with the web app's rsgain preset (-14 LUFS, clipping protection at -1 dBTP, true peak); equal to rsgain on a real album (`ReplayGainTests`, `TW_RSGAIN`). As `rsgain easy`, every disc folder is its own album (ADR 0076). Checked end to end against the web pipeline (drcalc, rsgain, fpscan, fixtags, lyrics, naming) on two copies of a FLAC, a 3-disc and an MP3 album: tags equal except fingerprints (~0.03 % of bits) and true peaks (5th decimal). The web app has no settings for the RG target, the RG skip or the language lookup (pipeline Config defaults), so none are added.
- Dynamic range (0036/0076): tags written as drcalc does, zero-padded (`08`), 0 never written; a track shorter than 12 s is skipped, the others and ALBUM_DR are still written, then the step fails. Measurements equal drcalc's on every track checked.
- Files whose tags would not change are not rewritten (DR, ReplayGain, tags steps), as drcalc and rsgain.
- Large libraries (817 albums, 11,090 tracks): album status is computed once per scan and per refreshed album, not per redraw; naming and lyrics-kind regexes are compiled once; the summary store (100+ MB) is written in the background. Selecting an album no longer stalls the app.
- Web-side MP3 fixes found by the end-to-end comparison (web c5c52ac): TXXX copies of mapped keys (ffmpeg's TXXX:DISCTOTAL, TXXX:LABEL ...) are read and moved into their frames; this port already did so.
- Logging (0064-0066, `AppLog.swift`): app, pipeline and library lines to ~/Library/Logs/Tagwright/tagwright.log and the unified log; `logLevel` default = LOG_LEVEL. SYSLOG_HOST not ported (Console takes that role on a Mac).

## Reverse-analysis comparison (RE-cue output vs. native, 2026-11-22)

RE-cue found 37 endpoints, 29 backend modules, 8 UI views. Field names and behaviour are not in its output (counts only); behaviour below comes from reading `pipeline/` and `library/` directly.

Endpoint coverage (native = equivalent in-process function):
- Covered: albums/album, cover get/put/delete, covers list, run/stop/job, move/move-preview, folder/folder-delete, discogs search/tracks, tracks propose/apply, track get/set, musicbrainz search/release/check/apply, tags get/set, overrides, lrclib search, audio playback, settings.
- `/api/library*` (versions, status, rescan, preview, albums.csv): ported as the library subsystem below (in-process, no HTTP).

Module coverage:
- Done: `mp3.py` and the `audio.py` seam (0058/0059) in `Mp3.swift` (`Mp3File`, `AudioFile`): ID3v2.2/2.3/2.4 read, v2.4 written (UTF-8, several values per frame), the web key mapping (text frames, TRCK/TPOS halves, USLT, COMM, TXXX for the rest, APIC with measured size), unknown frames and an ID3v1 block kept, audio copied byte for byte; stream info from the first frame and Xing/VBRI; MP3 in staging, library, naming (own extension), all six steps, mixed albums. Checked against mutagen on 40 real files (`Mp3Tests`, `TW_MP3`).
- Done: `logconfig.py` as `AppLog.swift` (no syslog forwarding; the access-log filter of 0065 has no counterpart without an HTTP server).
- Done in the Tags step (`Assign.fixTags`): `languages.py` (LYRICS_LANGUAGE per track from MUSICBRAINZ_ALBUMID, matched by release-track ID or disc/track plus title), `covers.py` resize to the maximum cover size; `replaygain.has_album_gain` skip in `Pipeline.replayGain`. Differences: a track MusicBrainz lists without a language keeps a `zxx` set by the lyrics step (web: removed, then set again by the next lyrics run).
- Done, `lyrics.py` + `lrc_format.py` (Lrc.swift): existing-LRC repair, normalisation, capitalisation, search variants, failed vs not found, zxx marker, invalid-timestamp rejection, suspect reasons in the editor. `lrclib.py` pacing ported (`LrcPacer`): one request at a time 0.5 s apart, 429 doubles the interval up to 8 s, Retry-After with jitter, 4 attempts, circuit breaker, retry rounds after 30 s and 60 s, the Lrclib-App-Id header. The web's 8 workers only overlap file work (its pacer also sends one request at a time); native handles tracks one after the other.
- Done, `layout.py` (`Scanner`): `Disc N` / `CD N` with any spacing, all audio below a disc folder, a disc folder directly in the library root is its own album; checked on 2- and 8-disc staging albums linked into a library layout (`LayoutTests`, `TW_MULTIDISC`). Differs on purpose: `Album/CD1/Bonus` stays part of `Album` (the web app also lists `Bonus` as a second album).

## Library subsystem (ported, Library*.swift and Lib*.swift)
Done: path template with editor and live preview (0037), planner, executor, cheap quick/full scans over a persisted index, watcher with cooldown and Report-only mode, status dialog with Re-analyze, top-bar status, Move to library through the template, "In your library" rows (0082), CSV export from the index (0077; file save, no HTTP endpoint).
Differences: index is JSON in Application Support, not SQLite; Apply defaults to OFF here (web: on) until the first report has been checked; a watcher pass runs on the main actor between awaits (scan and moves run off it).

## UI parity with the web app (2026-11-22)

Compared line by line: `ui/app/page.tsx`, `ui/components/{inspector,dialogs,releases,track-table,subtitle-divider,album-list,library}.tsx`, `app.py` (issues, steps) against the Swift views. One line per requirement; `[x]` once ported and checked by screenshot.

### Top bar (page.tsx)
- [x] T1 Logo: `static/icon.svg`, not a drawn tag glyph.
- [x] T2 Filters: 15 pt medium, 36 pt high, count in light slate; inactive slate-600 with a hover fill; tooltip "Sorted by X; click again to change"; choosing a filter resets the list-view column sort.
- [x] T3 Rescan: lucide RefreshCw, round hover, tooltip "Rescan folder"; reads every file again (bypasses the summary cache); toast "Rescanned".
- [x] T4 View: segmented pair (LayoutGrid / List), active one white, placed right after Rescan.
- [x] T5 Staging/Library switch pushed right (ml-auto), 192 pt wide, slate-300 border, 15 pt, inactive side slate-400 (not a weight change), whole control clickable, tooltip; the choice is remembered across launches.
- [x] T6 Search: 288 pt wide, lucide Search icon, tooltip "Search albums, artists, IDs (⌘K)", ⌘K hint; matches name, album, artist, Discogs ID, MBID.
- [x] T7 Stop playback: yellow pill next to the search (animated equaliser bars, square icon, "Stop"), not in the status area.
- [x] T8 Settings: lucide Settings icon, tooltip.
- [x] T9 Pipeline status: dot sky (pulsing) running / rose failed / amber stopped / emerald idle; text "Running: <title>", "Last run failed", "Last run stopped", "Idle"; Stop as an outlined rose pill.
- [x] T10 Toasts: "Running fixes on X…" / "Running <step> on X…" at start, "Run finished" / "Run finished with errors" / "Run stopped" at the end; success / error / warning styles.

### Cards (page.tsx)
- [x] C1 Radius 16, status-tinted 1 pt border (rose/sky/emerald-200), hover lift and shadow, selected = 2 pt slate-800 ring.
- [x] C2 Playing badge: yellow pill with animated equaliser bars, top right.
- [x] C3 Copy buttons after the title and after the artist.
- [x] C4 Third line is the edition (empty line kept), not the version line.
- [x] C5 ID badges: Discogs and MusicBrainz service icons (`discogs.png`, `musicbrainz.ico`) with the ID, grey pill, opening the release page.
- [x] C6 Second badge row: DR (white/70, emerald-800), LRC n, TXT n; no INS badge.
- [x] C7 Missing pills with a 1 pt ring and a tooltip "n of m tracks: titles…".
- [x] C8 Cover placeholder: hue gradient from the artist name with initials (no disc glyph).
- [x] C9 Loading: "Scanning albums…" with skeleton cards; empty filter: "No albums match “q”." / "No albums match."
- [x] C10 Progress bar 6 pt with a white/70 track, "n/6" tabular.

### List view (album-list.tsx)
- [x] L1 Columns Album artist / Release name / Media / Edition / Catalog # / DR / Release / Master; status is a coloured dot before the artist (no Status column); "No artist" when empty.
- [x] L2 Header slate-300 with slate-400 rules, sticky, ▲/▼ on the sorted column, tooltip "Sort by …"; empty values sort last both ways; DR and years numeric.
- [x] L3 Rows 13 pt, alternating slate-200 / slate-50, selected slate-300, hover; DR as two digits, bold, emerald ≥ 12 else amber, right-aligned.
- [x] L4 Column widths resizable and remembered (ADR 0086/0087).

### Inspector (inspector.tsx)
- [x] I1 Header sizes: artist 12 pt slate-500, title 20 pt semibold, version line 12 pt; pens 12 pt bare (no hover circle), copy buttons slate-400 with a black/5 hover.
- [x] I2 The header pens open an "Edit album" dialog (Album artist / Album title with copy buttons and the override help texts), not the tag editor; toast "Album saved".
- [x] I3 ID badges with the service icons; a missing ID is a rose "missing" link that searches Discogs / MusicBrainz for artist and title; pen tooltips "Change the Discogs release" / "Choose the MusicBrainz release"; DR pill emerald-100 with tooltip "Album dynamic range".
- [x] I4 Artwork fields: label + size (tooltip with bytes), status "1/3" for back/leaflet/media, image fills the square (cover-fit), double-click opens full size, footer buttons ‹ › (carousel), Upload (only when empty), Delete (rose), + (add another), front cover … menu (Upload image, Paste image, Search musichoarders, Search albumartexchange, Remove cover); small/missing cover: amber field with a warning icon; spinner overlay while embedding; drop replaces the shown image.
- [x] I5 Full-size cover: dark overlay, click or Esc closes (no sheet).
- [x] I6 Remove cover asks first ("Remove cover?" dialog with the explanation).
- [x] I7 Buttons: Tag Editor (dark), Run fixes (outline, rose "Running…" while running), Move to library (outline; tooltip "This album is already in the library" in the library).
- [x] I8 Note boxes: rose / amber / sky, 1 pt border, icon + uppercase label in a 128 pt column, 13 pt text, small outlined action button. Labels Problem / Warning / Note / Mismatch / Missing / Optional.
- [x] I9 Issue rules and texts from `app.py album_issues`: "Add a Discogs release ID before running fixes." (only line without an ID); "Set the album artist.", "Add a catalog number (enter 'none' …)", "Set the album format …", "n of m tracks have no …", "The files disagree on the …", "The … is set on only n of m tracks …", disc/track/title/artist counts, duplicate disc/track numbers, "Cover is WxH, below the minimum MxM." / "The album has no cover."; actions Search / Tag Editor (Album or Tracks tab) / Upload.
- [x] I10 Missing lines: "**No DR** on all 10 tracks" (label bold), click marks the step in the track list and opens it.
- [x] I11 Folder box: "Current folder" / "New folder" (path plus the title-and-version line, or "Not ready: artist or album is empty") / "In your library"; 128 pt label column, 12 pt code.
- [x] I12 Pipeline: lucide step icons (ChartColumn, Volume2, Fingerprint, Tags, Mic, FileText), running step sky with a spinning icon, partial amber with a warning badge, selected step label highlighted, tooltip = step note + "Double-click to run only this step."; double-click allowed on a `needs` album only for DR, ReplayGain and Fingerprints.
- [x] I13 Tracks: collapsible (chevron), selected step name shown in the header; 13 pt rows with 4 pt left border (yellow when playing), number 2 digits slate-400, title tooltip = file name, time, channel badge (Mono/Stereo slate-200, multichannel violet, tooltip), ✓/✗ for the selected step (amber ✓ for TXT lyrics), format pill, DR pill "DR14" / "DR —" 48 pt, lyrics pill 40 pt with tooltip (INS sky-100, --- rose-100), pen; list scrolls at 320 pt.
- [x] I14 Play: second click stops (as the web app), not pause/resume.
- [x] I15 Log: collapsible, dark slate-900 box, time column, green success lines, dimmed rename lines, "No runs yet".
- [x] I16 Empty inspector: "Select an album." (plain text).

### Dialog shell (dialogs.tsx Shell)
- [x] D1 One shell for every dialog: title 18 pt with optional header content beside it (file name, tabs), rounded 16, error line in rose above the footer, footer Cancel (outline) + primary (slate-800, rose when danger); no separate close row.

### Lyrics editor (dialogs.tsx LyricsEdit, ADR 0015)
- [x] Y1 Header: "Edit lyrics", file name in mono 12 pt slate-500, length as a grey badge.
- [x] Y2 Shaded search bar (slate-100, rounded): title and artist fields (placeholders), Enter searches, dark "Search lrclib.net" button with the lrclib icon, tooltip.
- [x] Y3 Search lists every lrclib result (not the pipeline's automatic pick): box at the right, sticky "N results on lrclib.net", sorted by closeness to the track length, within 3 s light green, each with a time badge, "artist - title", album, and buttons LRC / TXT / Instrumental that put that text in the field; the used result gets a ring; "Searching lrclib.net...", "No results.", errors in rose.
- [x] Y4 Lyrics header: format badge LRC / TXT / Empty (64 pt), "n lines"; ghost buttons Instrumental and Spoken Intro (`[00:00.00] [Instrumental]`, `[00:00.00](Spoken Intro)`); no Normalise.
- [x] Y5 Text area with the placeholder "Plain text (TXT) or synced [mm:ss.xx] lines (LRC). Empty removes the lyrics."; toast "Track saved".

### Tag editor (dialogs.tsx TagEditor, track-table.tsx)
- [x] E1 Tabs in the title row (right), 72 rem wide shell, content scrolls.
- [x] E2 Album tab: Year Release / Year Master Release as read-only inputs; ID rows with service icon badges (full ID) and pen tooltips; small "ALBUM FORMAT: …", "CATALOGNUMBER: …" lines under the overrides.
- [x] E3 Save closes at once; the inspector's step circles spin (Tags and cover + Filenames, or Filenames) until done; toast "Tags saved"; error "Title, disc and track must not be empty."
- [x] E4 Tracks tab: bulk bar ("Click the boxes (shift-click for a range) to select tracks" / "n selected", field select Disc/Artist/Track + value + Set, "Renumber from" + Renumber, Clear); checkbox column with shift-click ranges and select-all; grip handle, drag of one row or the selection, numbers and subtitles stay with the positions; compact inputs.
- [x] E5 Tracks tab subtitle dividers: "Disc N" chip for multi-disc, subtitle with pen and ×, "+ divider here" between rows, edit in place with Set / Cancel / Esc; DISCSUBTITLE saved per run.
- [x] E6 Discogs / MusicBrainz / Other tabs: the explanatory sentence above, key column 288 pt mono, values wrapped (Other: two lines), "n of m files · differs" at the right; empty texts as the web app.

### Discogs and MusicBrainz dialogs (releases.tsx)
- [x] R1 Search form: placeholder "Artist and album, or a Discogs release ID" / "… MusicBrainz release ID"; facts line Artist / Album / Year / Catalog # with copy buttons.
- [x] R2 Busy overlay over the results (spinner pill "Searching Discogs…", "Loading the release from Discogs…", "Assigning the tracks…").
- [x] R3 Results table: thumbnail, title + "MusicBrainz match" / "Discogs match" badge with tooltip, country · format · label · barcode, Year (sortable, empty last), Cat. no., Tracks (sortable; Discogs counts loaded 3 at a time, "…" / "?"), Select; the whole row clickable.
- [x] R4 Release line instead of a card: "artist - title" + "year · N tracks on release · M files", Import song titles checkbox at the right.
- [x] R5 MusicBrainz: Release / Release group (master) / Album artist table with links.
- [x] R6 Assignment table: "File: name · time" line, blue editable new title + channel badge, "Was: …" with copy; Disc / Track number inputs (greyed when titles are off); release-track select ("Skip (leave as is)", position, title, length, channels; rose border on duplicates); match / check / skip badges by confidence.
- [x] R7 Subtitle runs in the assignment: divider bands (Disc chip, text, "differs from your subtitles", "Was: …", Release / Keep mine pill, "n files", pen, ×, "+ divider here").
- [x] R8 Hints under the table (Import titles off/on, blue/grey legend, "Always written from Discogs …", "Not in this album: …" / MusicBrainz apply text).
- [x] R9 Footer: "Apply (n of m)", rose "Applying…", error "A release track is assigned to more than one file."; MusicBrainz dialog defaults Import song titles off (Discogs: remembered); toasts "Tracks assigned" / "MusicBrainz release applied".

### Move, cleanup, settings, library
- [x] M1 Move dialog "Move to the library?": sentence "“X” moves N tracks into the library…", grid Library / Album folder / File names (rose "(already exists)") / Cover files, the stays sentence, problems in rose; "Moving…" danger button.
- [x] M2 Cleanup "Delete the folder?": sentence with counts and sizes, table of subfolders and files with sizes, "n songs are still in this folder" blocks Delete; "Deleting…"; toast "Folder deleted (n files, size)".
- [x] S1 Settings General: field label + help text layout as the web app (Staging / Library folder, Minimum / Maximum cover size as number fields with help, the delete-after-move checkbox with its long help, Discogs key field "Leave blank to keep the stored key."); Save / Cancel (not Done, not auto-save); toast "Settings saved".
- [x] S2 Settings Library tab: Apply / Cooldown / Check every in one row with the help line; tag palette with drag into rows, chips dark (tags) or dashed (text) with ×, click selects a chip and shows Format / Digits / If empty use; rows "Folder level n", "Disc folder (multi-disc albums only)", "File name (the extension is added)"; "+ Folder level", "+ Disc folder", "Reset to bliss default"; preview box as the web app.
- [x] B1 Library dialog: three stat tiles, status sentence, root path, "Last scan …, last full pass …" + apply sentence, sections in web order (Recent activity, Waiting/Planned, Cannot be placed, Skipped) with limits, Re-analyze with its explanation, Close.

Deliberate differences, kept:
- Search buttons of the Discogs, MusicBrainz and lrclib dialogs stay clickable while a request runs; a new search replaces the running one (requested; the web app disables them).
- Discogs results show no barcode (the native search does not fetch it).
- Folders are chosen with "Choose…" in Settings (the web app reads them from the environment).
- Icons and images come from the web app (`scripts/gen-assets.mjs` regenerates `Sources/Tagwright/Assets.swift`).
