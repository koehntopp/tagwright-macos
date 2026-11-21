# ADR 0094: A native macOS app in Rust (Tagwright macOS)

- **Status**: Accepted
- **Date**: 2026-11-21

## Context

Tagwright started as a self-hosted web app in Docker on a Linux server (ADR 0003), and that ADR explicitly rejected a native macOS app because the pipeline tools and the long-running work live next to the files on the NAS. The owner now wants a native macOS client as well: the same job, the same behaviour, but a real Mac application with standard macOS controls instead of a browser tab, running the pipeline locally on the Mac (where `drcalc`, `rsgain` and `fpscan` already exist, they are the owner's own tools).

The behaviour of Tagwright — what makes a step done, who owns which tag, how files are named and laid out, how the screens look and what the colours mean — is the specification. That specification lives in the ADRs of the `tagwright` repository, and it must hold here. Only the platform and the language change.

## Decision

- **Tagwright macOS is a native macOS application written in Rust.** It is a separate repository, `tagwright-macos`, that reuses the `tagwright` ADR set as its specification. The domain ADRs (use cases 0002, status model 0054, tag ownership 0014, naming 0010, layout and watcher 0037, the UI design system 0030/0031/0086–0088, cover fields 0090/0092/0093, and every consolidated rule) remain binding and are implemented identically, except where this ADR or a later one says otherwise.
- **The same machine is the client and the host.** There are no HTTP endpoints; the paths of the tagwright web API become internal functions with the same rules: the path guard (`safe()`), the one-job-at-a-time model with a write lock (0008), settings stored in `DATA_DIR/settings.json` (0009), and secrets kept out of logs (0007) all keep their meaning. The staging and library folders still come from the environment only (`STAGING_FOLDER`, `LIBRARY_FOLDER`, `DATA_DIR`), with no defaults and absolute paths (0045, 0055).
- **UI**: AppKit, through the `cacao` crate (safe Rust bindings), so the controls are the standard macOS ones (windows, toolbars, tables, sheets, popovers, segmented controls, split views). The design follows ADRs 0030/0031 and 0086–0088: a top bar with the filters, Rescan, the card/list switch, the Staging/Library switch and the search; a board (card grid and the full-bleed data table) beside a fixed-width inspector (600 px, 720 px from a 1600 px window); dialogs as sheets or popovers.
- **Audio access**: the `lofty` crate is the single seam that reads and writes FLAC (Vorbis comments, pictures) and MP3 (ID3 v2.4), replacing `mutagen` (0058, 0059). Everything else works on the Vorbis-style tag model (upper-case keys, lists of strings) through one module, as 0058 demands.
- **Pipeline**: the six steps and their order (dynamic range, ReplayGain, fingerprints, tags and cover, lyrics, filenames) are unchanged (0036, 0054). The external tools `drcalc`, `rsgain` and `fpscan` are found on `PATH` and run as child processes; `drcalc` stays a Rust binary (0036).
- **Storage**: `DATA_DIR/summaries.db` stays SQLite (0067), through the `rusqlite` crate.
- **Tooling**: Rust conventions replace the Python ones — `cargo fmt`, `cargo clippy` and `cargo test` (0034, 0035). Dependency updates use Dependabot rather than Renovate (0061). The licence stays GPL-3.0-or-later (0062); the NOTICE is rewritten for the Rust dependencies.
- **Deployment**: no Docker image; a release is a signed `.app` bundle (or a `cargo build --release` binary). GitHub Actions builds and smoke-tests the app; releases are tagged `vX.Y.Z` with release notes, as in 0069–0071.

### What this supersedes

- **ADR 0003** (deployment as a web app in Docker): superseded for this repository. The reasons 0003 gave against a native app still describe real work, so this first version runs the pipeline and the scan locally and lists the folders the Mac can reach; the web app remains the deployment for running next to the files.
- **ADR 0002**: the out-of-scope line "A native macOS app (rejected)" is removed by this ADR.
- **ADR 0005** (technology stack): the Backend and Frontend bullets (Python, FastAPI, Next.js) are superseded by Rust + AppKit here. The FLAC/MP3 tag rules, the Discogs access rules and the style rules stand.
- **ADR 0029** (Next.js frontend): superseded by the native AppKit UI.
- **ADR 0034, 0035** (ruff, pytest): the Python rules do not apply; `cargo fmt`/`clippy`/`test` replace them.
- **ADR 0036**: the pipeline structure stands; the "Language: Python" parts are superseded by Rust.
- **ADR 0061** (Renovate): Dependabot replaces it here.
- **ADR 0063, 0084** (image on ghcr.io): no image; releases are `.app` bundles.

## Consequences

- One specification, two deliveries: a change to a domain ADR in `tagwright` (a status rule, a tag, a colour) must be mirrored here, and the reverse.
- The native app edits the same folders directly. Running it against a library on a NAS share is slower than the server-side app; this is accepted and matches 0003's original concern.
- The first release focuses on the parts the owner does most on a Mac: scan, see what each album needs, the tag editor, covers and the move to the library. The pipeline, Discogs/MusicBrainz/lrclib clients and the library watcher are brought up in the order the ADRs describe, behind the same seams.
- Web-only details (HTTP status codes, polling, the CSV endpoint 0077) do not apply; their behaviour maps to internal equivalents or is not needed. The CSV export is recreated as a file the user can save from the app.
