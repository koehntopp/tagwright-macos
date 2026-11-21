//! The domain data types (ADR 0054, 0015, 0016).

use std::path::PathBuf;

use super::TagMap;
use super::lyrics::LyricsKind;

/// The six pipeline steps, in order (ADR 0036, 0054).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Step {
    DynamicRange,
    ReplayGain,
    Fingerprints,
    TagsAndCover,
    Lyrics,
    Filenames,
}

impl Step {
    pub const ALL: [Step; 6] = [
        Step::DynamicRange,
        Step::ReplayGain,
        Step::Fingerprints,
        Step::TagsAndCover,
        Step::Lyrics,
        Step::Filenames,
    ];

    /// The name the pipeline row shows.
    pub fn label(self) -> &'static str {
        match self {
            Step::DynamicRange => "Dynamic range",
            Step::ReplayGain => "ReplayGain",
            Step::Fingerprints => "Fingerprints",
            Step::TagsAndCover => "Tags and cover",
            Step::Lyrics => "Lyrics",
            Step::Filenames => "Filenames",
        }
    }

    /// The short missing-item label (ADR 0054).
    pub fn missing_label(self) -> &'static str {
        match self {
            Step::DynamicRange => "No DR",
            Step::ReplayGain => "No ReplayGain",
            Step::Fingerprints => "No fingerprints",
            Step::TagsAndCover => "Tags incomplete",
            Step::Lyrics => "No lyrics",
            Step::Filenames => "Names differ",
        }
    }

    /// Lyrics is the only optional step (ADR 0054).
    pub fn optional(self) -> bool {
        self == Step::Lyrics
    }
}

/// Album status (ADR 0054). The key names (`needs`, `ready`, `fixed`) are the tagwright keys.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlbumStatus {
    Needs,
    Ready,
    Fixed,
}

impl AlbumStatus {
    /// The word the UI shows (ADR 0030).
    pub fn label(self) -> &'static str {
        match self {
            AlbumStatus::Needs => "Needs input",
            AlbumStatus::Ready => "Incomplete",
            AlbumStatus::Fixed => "Fixed",
        }
    }
}

/// Issue severity (ADR 0054).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum IssueLevel {
    Info,
    Ingest,
    Warn,
    Error,
}

/// Which button the UI offers for an issue (ADR 0054).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IssueAction {
    Search,
    Album,
    Tracks,
    Cover,
}

/// A one-line, clearly identifiable problem (ADR 0054).
#[derive(Debug, Clone)]
pub struct Issue {
    pub text: String,
    pub action: IssueAction,
    pub level: IssueLevel,
}

/// One open step and the tracks that fail it (ADR 0054).
#[derive(Debug, Clone)]
pub struct MissingItem {
    pub step: Step,
    pub label: String,
    pub optional: bool,
    pub count: usize,
    pub of: usize,
    pub tracks: Vec<String>,
}

/// An embedded picture (its type, mime, dimensions and byte length).
#[derive(Debug, Clone)]
pub struct Picture {
    pub pic_type: u32,
    pub mime: String,
    pub width: u32,
    pub height: u32,
    pub len: usize,
}

/// The cover the UI serves: dimensions, byte size, embedded or a folder image (ADR 0016).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoverInfo {
    pub w: u32,
    pub h: u32,
    pub bytes: u64,
    pub embedded: bool,
}

/// One audio file, its tags and stream info, read through the audio seam (ADR 0058).
#[derive(Debug, Clone)]
pub struct Track {
    pub path: PathBuf,
    pub rel: String,
    pub name: String,
    pub extension: String,
    pub tags: TagMap,
    pub channels: u8,
    pub sample_rate: u32,
    pub bit_depth: u8,
    pub duration_secs: f64,
    pub size: u64,
    pub mtime_ns: i64,
    pub pictures: Vec<Picture>,
}

/// An album: a folder and its audio tracks (ADR 0054, 0076).
#[derive(Debug, Clone)]
pub struct Album {
    pub folder: PathBuf,
    pub name: String,
    /// The folder's path below the base (staging or library), for the "Current folder" line.
    pub current_folder: String,
    pub cover: Option<CoverInfo>,
    pub tracks: Vec<Track>,
}

/// Settings that change how a summary reads (ADR 0074, 0016).
#[derive(Debug, Clone, Copy)]
pub struct SummaryConfig {
    pub min_cover: u32,
    pub max_cover: u32,
}

impl Default for SummaryConfig {
    fn default() -> Self {
        SummaryConfig {
            min_cover: 1400,
            max_cover: 1500,
        }
    }
}

/// A step's state on the pipeline bar (ADR 0054).
#[derive(Debug, Clone)]
pub struct StepStatus {
    pub step: Step,
    pub done: bool,
    pub partial: bool,
    pub note: String,
}

/// Lyrics counts across the album (ADR 0054).
#[derive(Debug, Clone, Copy, Default)]
pub struct LyricsCounts {
    pub synced: usize,
    pub plain: usize,
    pub instrumental: usize,
    pub missing: usize,
}

/// A track row in the inspector's track list (ADR 0015).
#[derive(Debug, Clone)]
pub struct TrackRow {
    pub name: String,
    pub file: String,
    pub length_secs: i64,
    pub channels: u8,
    pub format: String,
    pub disc: String,
    pub track: String,
    pub title: String,
    pub dr: String,
    pub lyrics: LyricsKind,
    pub checks: [bool; 6],
}

/// The full per-album summary, a port of tagwright's `summarize()` (ADR 0054).
#[derive(Debug, Clone)]
pub struct AlbumSummary {
    pub folder: String,
    pub name: String,
    pub current_folder: String,
    pub artist: String,
    pub artist_is_albumartist: bool,
    pub new_title: String,
    pub album: String,
    pub cover: Option<CoverInfo>,
    pub artist_override: String,
    pub title_override: String,
    pub year: String,
    pub release_year: String,
    pub master_year: String,
    pub edition_name: String,
    pub catalog: String,
    pub country: String,
    pub media: String,
    pub version: String,
    pub discogs_id: String,
    pub master: String,
    pub musicbrainz_id: String,
    pub track_count: usize,
    pub edition: String,
    pub dr: String,
    pub lyrics: LyricsCounts,
    pub steps: Vec<StepStatus>,
    pub steps_done: usize,
    pub tags_ok: bool,
    pub missing: Vec<MissingItem>,
    pub issues: Vec<Issue>,
    pub status: AlbumStatus,
    pub tracks: Vec<TrackRow>,
    pub mtime: u64,
}
