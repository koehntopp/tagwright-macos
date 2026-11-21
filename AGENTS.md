# AGENTS.md: rules for AI agents working on Tagwright macOS

Tagwright macOS is a native macOS client in Rust for the Tagwright app, following the same ADR set
in `docs/adr/`. Those ADRs are **binding**; they are the specification. Code, comments and your own
judgement do not outrank them. The one decision that differs from Tagwright is the platform, in
[ADR 0094](docs/adr/0094-native-macos-app-in-rust.md).

## 1. Before any change

1. Read [docs/adr/README.md](docs/adr/README.md) and every ADR its "Which ADR covers what" table
   names for the area you touch. Read ADR 0001, 0002 and 0094 if you have not in this session.
2. State, before editing, which ADRs apply (number and the rule). Do the same in your commit message
   body when a change is non-trivial.

## 2. ADRs are followed strictly

- **Never contradict an accepted ADR.** If a request conflicts with one, **stop**, name the ADR and
  the rule, and ask the owner whether to supersede it.
- **A decision change needs a new ADR**, written before or together with the code: next free number,
  `Accepted` only after the owner agrees, and the old ADR marked `Superseded by ADR NNNN`. Update
  [docs/adr/README.md](docs/adr/README.md) when you add or supersede an ADR.
- **Behaviour an ADR describes changes together with that ADR**, in the same commit: tags, statuses,
  thresholds, colours, widths, constants. Tagwright's `docs/adr/` is the shared source; a change to
  a domain ADR there must be mirrored here and vice versa (ADR 0094).
- **Silence is not permission.** If no ADR covers a decision that matters, write the ADR.

## 3. Hard rules that come from the ADRs

- **Domain** (0054, 0036, 0010, 0037): the six steps and their order, the status model, `clean()`,
  the bliss names and the layout template are ports of Tagwright. `clean()` is pinned byte-for-byte
  by `src/domain/naming.rs`'s golden test — do not change it without the owner and a new ADR.
- **Tags** (0004, 0014, 0059): upper-case keys; never read a tag the tools wrote as input; never
  make a Discogs-owned tag editable; never overwrite a user-owned tag from automation.
- **Safety** (0007, 0008): every write goes through the path guard; one job at a time; never log a
  key. Secrets live only in `DATA_DIR/settings.json`.
- **Verification** (0018): never run against a real library. Use a scratch copy and say what was not
  verified.

## 4. Rust

- `cargo fmt`, `cargo clippy -- -D warnings` and `cargo test` are the tooling (ADR 0094). Run them
  before saying done.
- Follow the existing module split: `src/domain/` is pure and unit-tested; `src/audio.rs` is the only
  place that touches `lofty`; `src/ui.rs` is the only place that touches `cacao`.
- The UI thread is the only place that touches AppKit; background work (scanning) happens on a thread
  and posts a `Message` (see `src/state.rs`, `src/ui.rs`).

## 5. Git (ADR 0020, 0069)

- **Never create a branch.** Work and commit directly on `main`, then push. `main` is the only
  branch.
- Every commit has a detailed description: a subject line, then *why*, *what*, *how checked*, and
  *which ADRs apply*.
- Every functional change gets an entry under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md) in the
  same commit, written for a user of the app.
- Never commit `data/`, `target/`, keys or music files.

## 6. Before you say "done"

- [ ] The ADRs I named still hold, or the owner approved a superseding ADR.
- [ ] Changed behaviour is reflected in the ADRs and the README index.
- [ ] Verified on a copy, not real data; what was not verified is stated.
- [ ] Every commit has a detailed description and a changelog entry.
- [ ] No secrets in code, logs, commits or output.
- [ ] `cargo test` and `cargo clippy -- -D warnings` pass, or the failures are listed.
