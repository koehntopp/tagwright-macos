//! Domain model shared with the `tagwright` repository (ADR 0054, 0014, 0037).
//!
//! Everything here is a faithful port of the tagwright logic; the tags are already
//! normalised to upper-case keys by the audio seam, so the model works on `TagMap`.

pub mod channels;
pub mod layout;
pub mod lyrics;
pub mod model;
pub mod naming;
pub mod status;

use std::collections::BTreeMap;

pub use channels::channel_label;
pub use lyrics::{LyricsKind, lyrics_kind};
pub use model::{
    Album, AlbumStatus, AlbumSummary, CoverInfo, Issue, IssueAction, IssueLevel, MissingItem,
    Picture, Step, StepStatus, SummaryConfig, Track, TrackRow,
};
pub use status::{status_of, summarize};

/// A file's tags in the Vorbis model: upper-case keys, lists of string values (ADR 0005, 0059).
pub type TagMap = BTreeMap<String, Vec<String>>;

/// The first non-empty value of `keys`, in order (`""` when none) — the `tag()` helper of the
/// tagwright pipeline (ADR 0054).
pub fn tag(tags: &TagMap, keys: &[&str]) -> String {
    for k in keys {
        if let Some(v) = tags.get(*k)
            && let Some(first) = v.first()
            && !first.is_empty()
        {
            return first.clone();
        }
    }
    String::new()
}

/// True when any of `keys` has a non-empty value.
pub fn has(tags: &TagMap, keys: &[&str]) -> bool {
    !tag(tags, keys).is_empty()
}
