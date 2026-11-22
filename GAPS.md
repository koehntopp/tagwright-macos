# Gaps against the web app (ADRs and CHANGELOG up to 0093)

Done in this port: status model and steps (0054), bliss names (0010), layout and move (0011/0037), top bar, Staging/Library switch, cards and list (0031/0038/0085-0087), inspector with unified notes (0083), four artwork fields with drop/paste (0090/0092), Discogs release search and assignment with proposal, Import song titles, rate limiting, track counts, MusicBrainz match (0013/0053/0078-0080), MusicBrainz search and assignment with Discogs-ID/barcode/catalogue matches and year/Discogs-link/track-count checks (0023/0083), Tags & cover step ported from fixtags.py (0036), tag editor with five tabs, overrides, drag renumbering and read-only tag tabs (0014/0057), lyrics editor (0015/0021), leftover-folder dialog (0072), playback marker and stop (0015/0068), double-click runs one step (0051), stored album summaries for Staging and Library (0067, `Summaries.swift`: binary plist in Application Support, one entry per folder keyed by path/mtime/size of every FLAC and the folder image, 640 px cover thumbnail, fingerprint values replaced by a marker; artwork is read when an album is selected or moved; `Summaries.version` replaces SUMMARY_VERSION).

## Still missing
- MP3 (ID3v2.4): tagging, naming, analysis, mixed albums (0058/0059).
- Tag editor Tracks tab: subtitle dividers, "+ divider here", checkbox range selection (0081). Assignment dialogs: Release/Keep-mine subtitle choice (0081), re-assignment replacing the previous release's values (0053), disc order for multi-disc proposals (0089).
- MusicBrainz language tags (LYRICS_LANGUAGE) in the Tags step (0023); ReplayGain skip when album gain exists (0028); cover resize in Run fixes (0074).
- Settings: layout tab, per-step Settings of ReplayGain targets; logging to a file/syslog (0064-0066).
- Free-text fixes: Discogs master ID in the album summaries.
- Cover search links (0056), persistent column widths in the list (0086).

## Reverse-analysis comparison (RE-cue output vs. native, 2026-11-22)

RE-cue found 37 endpoints, 29 backend modules, 8 UI views. Field names and behaviour are not in its output (counts only); behaviour below comes from reading `pipeline/` and `library/` directly.

Endpoint coverage (native = equivalent in-process function):
- Covered: albums/album, cover get/put/delete, covers list, run/stop/job, move/move-preview, folder/folder-delete, discogs search/tracks, tracks propose/apply, track get/set, musicbrainz search/release/check/apply, tags get/set, overrides, lrclib search, audio playback, settings.
- Missing: `/api/library*` (versions, status, rescan, preview, albums.csv) = watcher, planner, executor, index, summaries, template modules (about 1,200 lines of web code, none ported).

Module coverage:
- Missing: `mp3.py` (295 lines, ID3v2.4), `library/*` (see above), `logconfig.py`, `languages.py` (LYRICS_LANGUAGE from MusicBrainz), `covers.py` (resize), `artwork.py` sidecar export (`sidecar_names`, `export`), `replaygain.has_album_gain` skip.
- Done, `lyrics.py` + `lrc_format.py` (Lrc.swift): existing-LRC repair, normalisation, capitalisation, search variants, failed vs not found, zxx marker, invalid-timestamp rejection, suspect reasons in the editor. Not ported: parallel lookups (8 workers) and the retry rounds / circuit breaker of `lrclib.py` (native: sequential, up to 3 attempts per lookup, failed tracks are reported and retried on the next run).
- Done, `layout.py` (`Scanner`): `Disc N` / `CD N` with any spacing, all audio below a disc folder, a disc folder directly in the library root is its own album; checked on 2- and 8-disc staging albums linked into a library layout (`LayoutTests`, `TW_MULTIDISC`). Differs on purpose: `Album/CD1/Bonus` stays part of `Album` (the web app also lists `Bonus` as a second album).

## Library subsystem (ported, Library*.swift and Lib*.swift)
Done: path template with editor and live preview (0037), planner, executor, cheap quick/full scans over a persisted index, watcher with cooldown and Report-only mode, status dialog with Re-analyze, top-bar status, Move to library through the template, "In your library" rows (0082), CSV export from the index (0077; file save, no HTTP endpoint).
Differences: index is JSON in Application Support, not SQLite; Apply defaults to OFF here (web: on) until the first report has been checked; sidecar artwork is not recreated from embedded art after a watcher move (0091); chips cannot be dragged, only moved with the menu; a watcher pass runs on the main actor between awaits (scan and moves run off it).
