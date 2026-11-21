//! Album folders (ADR 0054, 0076) and the library layout template (ADR 0037).
//!
//! In the staging folder every folder directly below it is one album, with all audio below it.
//! Elsewhere a `Disc N` / `CD N` folder belongs to its parent album. The base folder itself is
//! never an album.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::naming::clean;

/// True for a disc subfolder name (`Disc 2`, `CD1`, `disc 2`).
pub fn is_disc_dir(name: &str) -> bool {
    use regex::Regex;
    use std::sync::OnceLock;
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"(?i)^(?:Disc|CD)\s*\d+$").unwrap());
    re.is_match(name)
}

/// True for an audio file name: extension `.flac` or `.mp3` in any case (ADR 0058, 0059).
pub fn is_audio(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.ends_with(".flac") || lower.ends_with(".mp3")
}

fn is_hidden(name: &str) -> bool {
    name.starts_with('.')
}

/// All audio files below `base`, sorted; hidden folders and files are skipped (ADR 0054).
pub fn find_audio_files(base: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut stack = vec![base.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if is_hidden(&name) {
                continue;
            }
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if is_audio(&name) {
                found.push(path);
            }
        }
    }
    found.sort();
    found
}

/// The audio files of an album: those in its own folder and those in its `Disc N` / `CD N` folders.
/// Other subfolders are other albums. In the staging folder the top-level folder is the album,
/// whatever is below it (ADR 0076).
pub fn album_files(album: &Path, staging: Option<&Path>) -> Vec<PathBuf> {
    if staging.is_some_and(|s| album.parent() == Some(s)) {
        return find_audio_files(album);
    }
    let mut found = Vec::new();
    let Ok(entries) = std::fs::read_dir(album) else {
        return found;
    };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if is_hidden(&name) {
            continue;
        }
        let path = entry.path();
        if path.is_file() && is_audio(&name) {
            found.push(path);
        } else if path.is_dir() && is_disc_dir(&name) {
            found.extend(find_audio_files(&path));
        }
    }
    found.sort();
    found
}

/// The albums below `base`. In the staging folder its top-level folders; elsewhere every folder with
/// audio, a `Disc N` folder counting as part of its parent. The base folder itself is never an album.
pub fn album_dirs(base: &Path, staging: Option<&Path>) -> Vec<PathBuf> {
    if staging.is_some_and(|s| base == s) {
        let Ok(entries) = std::fs::read_dir(base) else {
            return Vec::new();
        };
        let mut dirs: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_dir())
            .filter(|p| !is_hidden(&p.file_name().unwrap_or_default().to_string_lossy()))
            .filter(|p| !find_audio_files(p).is_empty())
            .collect();
        dirs.sort();
        return dirs;
    }
    let mut found = BTreeMap::<PathBuf, ()>::new();
    for f in find_audio_files(base) {
        let d = f.parent().unwrap_or(base).to_path_buf();
        if is_disc_dir(&d.file_name().unwrap_or_default().to_string_lossy())
            && d.parent() != Some(base)
        {
            found.insert(d.parent().unwrap().to_path_buf(), ());
        } else {
            found.insert(d, ());
        }
    }
    found.into_keys().collect()
}

// --- The layout template (ADR 0037) ---

/// The tags a template may use. `ALBUM_VERSION` is the bliss rule: `ALBUM` plus `VERSION` unless
/// the album already contains it.
pub const PALETTE: &[(&str, &str)] = &[
    ("ALBUMARTIST", "Album artist"),
    ("ARTIST", "Artist"),
    ("ALBUM", "Album"),
    ("VERSION", "Version"),
    ("ALBUM_VERSION", "Album + version"),
    ("ALBUM_EDITION", "Edition"),
    ("ALBUM_FORMAT", "Format"),
    ("CATALOGNUMBER", "Catalog #"),
    ("DATE", "Year"),
    ("ORIGINALDATE", "Original year"),
    ("DISCNUMBER", "Disc"),
    ("TRACKNUMBER", "Track"),
    ("TITLE", "Title"),
    ("DISCSUBTITLE", "Disc subtitle"),
];

pub const FORMATS: &[&str] = &["text", "num", "int", "year"];
pub const MAX_LEVELS: usize = 4;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Chip {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub tag: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub text: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub fmt: String,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub pad: usize,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub fallback: String,
}

fn is_zero(n: &usize) -> bool {
    *n == 0
}

impl Chip {
    pub fn literal(text: &str) -> Self {
        Chip {
            text: text.to_string(),
            ..Default::default()
        }
    }
    pub fn tag(tag: &str) -> Self {
        Chip {
            tag: tag.to_string(),
            fmt: "text".to_string(),
            ..Default::default()
        }
    }
}

impl Default for Chip {
    fn default() -> Self {
        Chip {
            tag: String::new(),
            text: String::new(),
            fmt: "text".to_string(),
            pad: 0,
            fallback: String::new(),
        }
    }
}

pub type Level = Vec<Chip>;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Template {
    pub folders: Vec<Level>,
    pub filename: Level,
    pub disc_folder: Option<Level>,
}

impl Template {
    /// The bliss layout (without the `ARTIST` fallback bliss has: ADR 0010 forbids it).
    pub fn bliss() -> Self {
        Template {
            folders: vec![
                vec![Chip::tag("ALBUMARTIST")],
                vec![Chip::tag("ALBUM_VERSION")],
            ],
            disc_folder: Some(vec![
                Chip::literal("Disc "),
                Chip {
                    tag: "DISCNUMBER".to_string(),
                    fmt: "int".to_string(),
                    ..Default::default()
                },
            ]),
            filename: vec![
                Chip {
                    tag: "DISCNUMBER".to_string(),
                    fmt: "num".to_string(),
                    pad: 2,
                    ..Default::default()
                },
                Chip::literal("_"),
                Chip {
                    tag: "TRACKNUMBER".to_string(),
                    fmt: "num".to_string(),
                    pad: 2,
                    ..Default::default()
                },
                Chip::literal("_"),
                Chip::tag("TITLE"),
            ],
        }
    }
}

impl Default for Template {
    fn default() -> Self {
        Template::bliss()
    }
}

/// Error raised when a chip's tag is empty (the file is "unplaced", ADR 0037).
#[derive(Debug, thiserror::Error)]
#[error("missing tag {0}")]
pub struct MissingTag(pub String);

fn leading_digits(value: &str) -> String {
    let s = value.trim_start();
    s.chars().take_while(|c| c.is_ascii_digit()).collect()
}

fn value_of<'a>(tags: &'a BTreeMap<String, String>, key: &str) -> &'a str {
    // ALBUM_VERSION is composite; handled specially in render_level via lookup below.
    tags.get(key).map(String::as_str).unwrap_or("")
}

fn render_level(level: &Level, tags: &BTreeMap<String, String>) -> Result<String, MissingTag> {
    let mut out = String::new();
    for c in level {
        if c.tag.is_empty() {
            out.push_str(&c.text);
            continue;
        }
        let raw = value_of(tags, &c.tag).trim().to_string();
        let raw = if raw.is_empty() && !c.fallback.is_empty() {
            value_of(tags, &c.fallback).trim().to_string()
        } else {
            raw
        };
        if raw.is_empty() {
            return Err(MissingTag(c.tag.clone()));
        }
        match c.fmt.as_str() {
            "num" => {
                let part = raw.split('/').next().unwrap_or("");
                if c.pad > part.len() {
                    out.push_str(&"0".repeat(c.pad - part.len()));
                }
                out.push_str(part);
            }
            "int" => {
                let n = leading_digits(&raw);
                if n.is_empty() {
                    return Err(MissingTag(c.tag.clone()));
                }
                out.push_str(&n.parse::<i64>().map(|v| v.to_string()).unwrap_or(n));
            }
            "year" => out.push_str(&clean(&raw.chars().take(4).collect::<String>())),
            _ => out.push_str(&clean(&raw)),
        }
    }
    Ok(out)
}

/// The tags the template reads, resolved to strings, with the composite `ALBUM_VERSION` filled.
pub fn resolve_tags(tags: &BTreeMap<String, Vec<String>>) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for (key, _) in PALETTE {
        if let Some(v) = tags.get(*key)
            && let Some(first) = v.first()
        {
            out.insert((*key).to_string(), first.clone());
        }
    }
    let album = out.get("ALBUM").cloned().unwrap_or_default();
    let version = out.get("VERSION").cloned().unwrap_or_default();
    let album_version = if !album.is_empty() && !version.is_empty() && !album.contains(&version) {
        format!("{album} {version}")
    } else {
        album
    };
    out.insert("ALBUM_VERSION".to_string(), album_version);
    out
}

/// Where a file belongs: the album folder levels, the disc folder if any, and the file name (ADR 0037).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub album_dir: Vec<String>,
    pub disc_dir: String,
    pub filename: String,
}

/// The path target of a file under the template; `Err` when a needed tag is empty.
pub fn target(
    t: &Template,
    tags: &BTreeMap<String, String>,
    suffix: &str,
) -> Result<Target, MissingTag> {
    let album_dir = t
        .folders
        .iter()
        .map(|level| render_level(level, tags))
        .collect::<Result<Vec<_>, _>>()?;
    let disc_dir = match &t.disc_folder {
        Some(level) => render_level(level, tags)?,
        None => String::new(),
    };
    let stem = render_level(&t.filename, tags)?;
    if stem.is_empty() || album_dir.iter().any(String::is_empty) {
        return Err(MissingTag("empty after cleaning".to_string()));
    }
    Ok(Target {
        album_dir,
        disc_dir,
        filename: format!("{stem}{suffix}"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disc_dir_detection() {
        assert!(is_disc_dir("Disc 2"));
        assert!(is_disc_dir("CD1"));
        assert!(is_disc_dir("disc 12"));
        assert!(!is_disc_dir("Discography"));
        assert!(!is_disc_dir("Bonus"));
        assert!(!is_disc_dir("CD"));
    }

    #[test]
    fn audio_extension() {
        assert!(is_audio("01_Title.flac"));
        assert!(is_audio("track.MP3"));
        assert!(!is_audio("cover.jpg"));
    }

    #[test]
    fn default_template_matches_bliss() {
        let mut tags = BTreeMap::new();
        tags.insert("ALBUMARTIST".to_string(), vec!["Pink Floyd".to_string()]);
        tags.insert("ALBUM".to_string(), vec!["The Wall".to_string()]);
        tags.insert("VERSION".to_string(), vec!["[2000]".to_string()]);
        tags.insert("DISCNUMBER".to_string(), vec!["1/2".to_string()]);
        tags.insert("TRACKNUMBER".to_string(), vec!["3".to_string()]);
        tags.insert("TITLE".to_string(), vec!["Another Brick".to_string()]);
        let resolved = resolve_tags(&tags);
        let t = target(&Template::default(), &resolved, ".flac").unwrap();
        assert_eq!(t.album_dir, vec!["Pink_Floyd", "The_Wall_2000"]);
        assert_eq!(t.disc_dir, "Disc 1");
        assert_eq!(t.filename, "01_03_Another_Brick.flac");
    }
}
