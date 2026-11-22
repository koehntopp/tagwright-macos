# Tagwright for macOS

Native SwiftUI port of Tagwright (macOS 15+, no Docker, no Python). UI and rules follow the ADRs in `../tagwright/docs/adr`.

Build: `./build-app.sh` -> `build/Tagwright.app`. Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (`TW_FIXTURE=<staging dir>` also runs the pipeline test).

| ADR | Where |
|-----|-------|
| 0005 FLAC tags, upper-case keys | `Flac.swift` (own Vorbis-comment/picture reader and writer, audio frames copied) |
| 0054 status, steps, issues, missing | `Model.swift` |
| 0010 / 0037 bliss names and layout | `Model.swift` (`Naming`), `Pipeline.movePlan` |
| 0011 / 0091 move, cover recreated | `Pipeline.move` |
| 0031 / 0038 / 0085 top bar, Staging/Library, list view | `TagwrightApp.swift`, `Board.swift` |
| 0014 / 0053 tag editor, Discogs assignment | `Sheets.swift`, `Discogs.swift` |
| 0058 / 0059 MP3 (ID3v2.4) through one seam | `Mp3.swift` (`Mp3File`, `AudioFile`) |
| 0007 secrets | Discogs token in the Keychain |
| 0023 / 0083 MusicBrainz search and assignment | `Discogs.swift` (`MusicBrainz`), `Sheets.swift` |
| 0015 / 0021 lyrics editor, LRC repair | `Lrc.swift`, `Sheets.swift` |
| 0037 / 0067 / 0077 / 0082 library template, watcher, index, CSV | `Library*.swift`, `Lib*.swift` |

Steps run in process: dynamic range (TT DR), ReplayGain (EBU R128, the web app's rsgain preset: -14 LUFS, true peak, clipping protection at -1 dBTP), lyrics (LRCLIB), filenames. Fingerprints (Chromaprint algorithm 2) are computed natively: no external tools.

UI: dialogs, cards, inspector and list view follow `../tagwright/ui/components` (Tailwind/shadcn look rebuilt in `Theme.swift`); lucide icons and the web's static images are generated into `Assets.swift` by `node scripts/gen-assets.mjs Sources/Tagwright/Assets.swift`.

What is still missing compared with the web app: see `GAPS.md`.
