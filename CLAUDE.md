# Tagwright for macOS: rules for AI agents

This is a native SwiftUI port of the web app in `../tagwright`. The web app's ADRs (`../tagwright/docs/adr`) are the
specification for both; this app has no decisions of its own.

## 1. Keeping the two apps in sync

1. **Behaviour is decided in the web repository.** A change to what the app does (tags written, statuses, texts,
   names, steps, dialogs, settings) is written down there first: an ADR, or a CHANGELOG entry for a fix. Then both
   apps implement it. A bug or a better rule found here goes back as an ADR proposal or a note to the owner, never
   only into this code.
2. **Before working here, run `scripts/sync-check`.** It lists every web change since the commit in `SYNC`, with the
   files here that correspond. Port them first: read the ADR and the web code (component by component for the UI),
   port everything, then `scripts/sync-check --update` and commit `SYNC` together with the port.
3. **The web code is the test oracle.** `WebParityTests` runs the web app's own functions (`scripts/web-oracle.py`)
   on the same input and compares: naming, lyrics kind and decisions, album issues, the library layout, Discogs
   tags. When a ported rule has a web function, add cases there. `ReplayGainTests` (TW_RSGAIN) compares with rsgain,
   `Mp3Tests` with mutagen.
4. **UI changes are checked by screenshot** against the web app (`screencapture -l <window id>`), with the web
   component open beside the Swift view. Track UI gaps per element in `GAPS.md`, not per ADR.
5. Generated files: `Sources/Tagwright/Assets.swift` (`node scripts/gen-assets.mjs Sources/Tagwright/Assets.swift`),
   `Resources/unidecode.bin` (`../tagwright/.venv/bin/python scripts/gen-unidecode.py`),
   `Resources/AppIcon.icns` (`swift scripts/make-icon.swift ../tagwright/static/icon.svg Resources/AppIcon.icns`).
   Regenerate them when the web app's lucide-react, unidecode or icon changes.

## 2. Working here

- Build: `./build-app.sh`. Release (Developer ID, notarized, stapled zip in `build/`): `./release.sh <web version>`. Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- Test on copies, never on the real staging folder or library: start the app with
  `build/Tagwright.app/Contents/MacOS/Tagwright -staging <copy> -library <empty dir>`.
- `GAPS.md` lists what differs from the web app and why; keep it current in the same commit.
- Commit messages: what changed, why, how it was checked, which ADRs apply.
