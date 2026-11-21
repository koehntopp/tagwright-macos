# Changelog

All notable changes to Tagwright macOS are recorded here, in the style of the Tagwright changelog
(ADR 0069). Entries are written for a user of the app.

## Unreleased

### Added

- A native macOS app in Rust that follows the Tagwright ADR set ([0094](docs/adr/0094-native-macos-app-in-rust.md)).
- The domain core, byte-for-byte faithful to Tagwright: `clean()`, the six-step status model, issue
  lines, lyrics kinds, channel badges, the library layout template and the default bliss layout.
- FLAC and MP3 tag reading through one seam (`lofty`), preserving custom tags.
- A board (list view) and an inspector with the top-bar filters, the staging/library switch and the
  rescan action.
- A FLAC smoke test that builds a synthetic album and checks the scan + status pipeline.
