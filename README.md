# Tagwright macOS

[![Licence: GPL-3.0-or-later](https://img.shields.io/github/license/koehntopp/tagwright-macos)](LICENSE)
[![Rust](https://img.shields.io/badge/rust-1.100%2B-orange)](https://www.rust-lang.org)

A native macOS client for [Tagwright](https://github.com/koehntopp/tagwright): a desktop app that
turns freshly downloaded FLAC and MP3 albums into clean, tagged, loudness-analysed albums with
lyrics, and keeps the music library in one canonical folder layout. One user, one window.

The behaviour is the specification: this app follows the [ADR set](docs/adr/README.md) shared with
Tagwright, and implements it with standard macOS controls (AppKit) in Rust. The one decision that
differs — a native app instead of a web app in Docker — is recorded in
[ADR 0094](docs/adr/0094-native-macos-app-in-rust.md).

## What it does

You point the app at two folders: a **staging folder** (where downloads land) and a **library
folder** (what the music server reads). It helps you take an album from one to the other:

1. **See what each album needs.** Every top-level folder in the staging folder is one album, shown
   as a row with artist, album, year, Discogs ID, dynamic range and pipeline progress. The top bar
   filters: *All albums*, *Needs input*, *Incomplete*, *Fixed*.
2. **Fix it.** *Run fixes* runs the pipeline on the album and streams a live log.
3. **Correct what automation cannot.** Assign the Discogs and MusicBrainz release, edit tags, fix
   lyrics, replace the cover.
4. **Move it to the library.** *Move to library* places the files in the library layout.

The status colours keep their meaning (ADR 0030): green *Fixed*, blue *Incomplete*, red *Needs
input*.

## The pipeline

One run does these steps in this order (ADR 0036, 0054):

1. **Dynamic range** with [`drcalc`](https://github.com/koehntopp/drcalc)
2. **ReplayGain** with `rsgain`
3. **Fingerprints** with [`fpscan`](https://github.com/koehntopp/fpscan) (AcoustID)
4. **Tags & cover** from the assigned Discogs release
5. **Lyrics** from [lrclib.net](https://lrclib.net)
6. **Filenames** in the layout's file name pattern

The inspector shows each step as done, partial or open, and which tracks lack it. Tags the app
writes are never read back as input, tags owned by Discogs are read-only in the editor, and a
user-owned tag is never overwritten by automation (ADR 0004, 0014).

## Run it

Requirements: a recent Rust toolchain, and on `PATH`: `drcalc`, `rsgain`, `fpscan`.

```bash
STAGING_FOLDER=/path/to/staging LIBRARY_FOLDER=/path/to/library DATA_DIR=./data cargo run --release
```

The three folders have no default and must be absolute (ADR 0045, 0055). In Settings enter your
**Discogs API key** (required for the Discogs step). It lives in `DATA_DIR/settings.json` and is
never logged.

## Status of this first version

The domain is complete and byte-for-byte faithful: `clean()` matches Tagwright's file-name rule
(verified against a golden set produced by the real implementation), the six-step status model,
the issue lines, the lyrics kinds, the channel badges, the library layout template and the default
bliss layout. FLAC and MP3 tags are read through one seam (`lofty`), preserving custom tags such as
`DYNAMIC_RANGE`, `DISCOGS_RELEASE_ID` and `ACOUSTID_FINGERPRINT`.

Not yet implemented (see ADR 0094 for the plan):

- **Discogs, MusicBrainz and lrclib.net clients** — the search and assignment dialogs.
- **Tag, cover and lyrics writing** — the app reads and evaluates tags; it does not yet edit them.
- **The library watcher** and the **move to library** executor.
- **The card view** — the board is the list view; the card grid is next.
- The **Settings** dialog — folders are read from the environment; the dialog and the layout editor
  are not yet wired.
- `drcalc`/`rsgain`/`fpscan` are invoked by *Run fixes*, but the Discogs and lyrics steps are
  stubbed until the clients above land.

## Development

```bash
cargo build                       # compile
cargo test                        # unit tests (domain) + a FLAC smoke test (needs flac/metaflac)
cargo clippy -- -D warnings       # lint
cargo fmt --check                 # formatting
```

Layout: `src/domain/` (the ADR-specified logic, pure and tested), `src/audio.rs` (the `lofty`
seam), `src/scan.rs` (album discovery), `src/settings.rs`, `src/state.rs` (shared app state),
`src/pipeline/`-equivalent (`src/pipeline.rs`), and `src/ui.rs` (the AppKit UI). `docs/adr/` is the
specification; [AGENTS.md](AGENTS.md) is binding for contributors and AI agents.

Never run the app against a real library (ADR 0018). Use a scratch copy.

## Licence

Tagwright macOS is free software under the [GNU General Public License, version 3 or
later](LICENSE) (ADR 0062). It builds on `lofty`, `cacao` and `deunicode`; [NOTICE](NOTICE) lists
the third-party software it uses.
