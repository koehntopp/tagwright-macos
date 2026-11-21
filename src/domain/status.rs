//! Album status, pipeline steps and issue lines (ADR 0054) — a port of tagwright's
//! `summarize()`, `album_issues()`, `status()` and friends.

use std::path::Path;

use super::TagMap;
use super::lyrics::lyrics_kind;
use super::model::*;
use super::{has, tag};
use super::{layout, naming};

/// The four spellings of the catalogue number (ADR 0054).
pub const CATALOG_KEYS: [&str; 4] = [
    "CATALOGNUMBER",
    "CATALOG NUMBER",
    "CATALOG_NUMBER",
    "CATALOGNO",
];

/// One entry per required tag (alternative spellings together); an empty one means the album is
/// not ready (ADR 0054).
pub const REQUIRED_TAGS: [&[&str]; 8] = [
    &["ARTIST"],
    &["ALBUMARTIST"],
    &["TITLE"],
    &["ALBUM"],
    &["TRACKNUMBER"],
    &["DISCNUMBER"],
    &["ALBUM_FORMAT"],
    &[
        "CATALOGNUMBER",
        "CATALOG NUMBER",
        "CATALOG_NUMBER",
        "CATALOGNO",
    ],
];

/// Album-level tags the pipeline reads from the FIRST file only; all files must agree (ADR 0054).
const ALBUM_LEVEL: [(&str, &[&str], IssueAction, bool); 8] = [
    (
        "Discogs release ID",
        &["DISCOGS_RELEASE_ID"],
        IssueAction::Search,
        true,
    ),
    ("album artist", &["ALBUMARTIST"], IssueAction::Album, true),
    ("catalog number", &CATALOG_KEYS, IssueAction::Album, true),
    ("album format", &["ALBUM_FORMAT"], IssueAction::Album, true),
    ("edition", &["ALBUM_EDITION"], IssueAction::Album, false),
    (
        "MusicBrainz release ID",
        &["MUSICBRAINZ_ALBUMID", "MUSICBRAINZ ALBUM ID"],
        IssueAction::Album,
        false,
    ),
    (
        "album artist override",
        &["ALBUM_ARTIST_OVERRIDE"],
        IssueAction::Album,
        false,
    ),
    (
        "album title override",
        &["ALBUM_TITLE_OVERRIDE"],
        IssueAction::Album,
        false,
    ),
];

fn missing_text(label: &str) -> &'static str {
    match label {
        "album artist" => "Set the album artist.",
        "catalog number" => "Add a catalog number (enter 'none' if the release has none).",
        "album format" => "Set the album format (for example CD, SACD, Vinyl).",
        _ => "",
    }
}

fn all_have(tags: &[&TagMap], keys: &[&str]) -> bool {
    tags.iter().all(|t| has(t, keys))
}

/// Album DR: `ALBUM_DR`, else the rounded mean of the per-track `DYNAMIC_RANGE` values (ADR 0054).
pub fn track_dr_mean(tags: &[&TagMap]) -> String {
    let vals: Vec<i32> = tags
        .iter()
        .filter_map(|t| tag(t, &["DYNAMIC_RANGE"]).parse::<i32>().ok())
        .filter(|&v| v > 0)
        .collect();
    if vals.is_empty() {
        return String::new();
    }
    let mean = vals.iter().map(|&v| v as f64).sum::<f64>() / vals.len() as f64;
    format!("{:02}", mean.round() as i32)
}

/// Sample rate in kHz and bit depth as short as possible: `44.1/16`, `192/24`; the rate alone when
/// the format has no bit depth (MP3) (ADR 0015).
pub fn rate_bits(sample_rate: u32, bit_depth: u8) -> String {
    if sample_rate == 0 {
        return String::new();
    }
    let khz = format!("{}", sample_rate as f64 / 1000.0);
    if bit_depth > 0 {
        format!("{khz}/{bit_depth}")
    } else {
        khz
    }
}

fn count_text(n: usize, total: usize, what: &str) -> String {
    let short = what.split(' ').next_back().unwrap_or(what);
    if n == total {
        if total > 1 {
            format!("No track has {what}.")
        } else {
            format!("The track has no {short}.")
        }
    } else if n == 1 {
        format!("1 of {total} tracks has no {short}.")
    } else {
        format!("{n} of {total} tracks have no {short}.")
    }
}

fn cover_note(cov: Option<CoverInfo>, min_cover: u32) -> String {
    match cov {
        Some(c) => format!(
            "Cover is {}x{}, below the minimum {min_cover}x{min_cover}.",
            c.w, c.h
        ),
        None => "The album has no cover.".to_string(),
    }
}

/// The file name the layout gives a file (the bliss name with the default template), or `None` while
/// a tag it needs is empty (ADR 0038, 0010).
pub fn file_name(tags: &TagMap, suffix: &str) -> Option<String> {
    let resolved = layout::resolve_tags(tags);
    let target = layout::target(&layout::Template::default(), &resolved, suffix).ok()?;
    Some(target.filename)
}

/// The issue lines of an album, one line each (ADR 0054).
pub fn album_issues(
    discogs_id: &str,
    tags: &[&TagMap],
    small_cover: bool,
    cover: Option<CoverInfo>,
    min_cover: u32,
) -> Vec<Issue> {
    let n = tags.len();
    let mut issues = Vec::new();

    if discogs_id.is_empty() {
        issues.push(Issue {
            text: "Add a Discogs release ID before running fixes.".to_string(),
            action: IssueAction::Search,
            level: IssueLevel::Error,
        });
        return issues;
    }

    for (label, keys, action, required) in ALBUM_LEVEL {
        let values: Vec<String> = tags.iter().map(|t| tag(t, keys)).collect();
        let missing = values.iter().filter(|v| v.is_empty()).count();
        if required && missing > 0 && !(label == "Discogs release ID" && missing == n) {
            let text = if missing == n {
                missing_text(label).to_string()
            } else {
                format!("{missing} of {n} tracks have no {label}.")
            };
            issues.push(Issue {
                text,
                action,
                level: if label == "Discogs release ID" {
                    IssueLevel::Error
                } else {
                    IssueLevel::Warn
                },
            });
        }
        let filled: Vec<&String> = values.iter().filter(|v| !v.is_empty()).collect();
        let distinct = filled
            .iter()
            .map(|v| v.as_str())
            .collect::<std::collections::HashSet<_>>();
        if distinct.len() > 1 {
            issues.push(Issue {
                text: format!(
                    "The files disagree on the {label} ({} different values); it is read from the first file only.",
                    distinct.len()
                ),
                action,
                level: if label == "Discogs release ID" {
                    IssueLevel::Error
                } else {
                    IssueLevel::Warn
                },
            });
        } else if !required && !filled.is_empty() && filled.len() < n {
            issues.push(Issue {
                text: format!(
                    "The {label} is set on only {} of {n} tracks; it is read from the first file only.",
                    filled.len()
                ),
                action,
                level: IssueLevel::Warn,
            });
        }
    }

    for (key, what) in [
        ("DISCNUMBER", "a disc number"),
        ("TRACKNUMBER", "a track number"),
        ("TITLE", "a title"),
        ("ARTIST", "an artist"),
    ] {
        let missing = tags.iter().filter(|t| !has(t, &[key])).count();
        if missing > 0 {
            issues.push(Issue {
                text: count_text(missing, n, what),
                action: IssueAction::Tracks,
                level: IssueLevel::Warn,
            });
        }
    }

    let numbers: Vec<(String, String)> = tags
        .iter()
        .filter(|t| has(t, &["DISCNUMBER"]) && has(t, &["TRACKNUMBER"]))
        .map(|t| {
            (
                tag(t, &["DISCNUMBER"])
                    .split('/')
                    .next()
                    .unwrap_or("")
                    .to_string(),
                tag(t, &["TRACKNUMBER"])
                    .split('/')
                    .next()
                    .unwrap_or("")
                    .to_string(),
            )
        })
        .collect();
    let mut counts = std::collections::HashMap::new();
    for num in &numbers {
        *counts.entry(num.clone()).or_insert(0usize) += 1;
    }
    let dup = counts.values().filter(|&&c| c > 1).count();
    if dup > 0 {
        issues.push(Issue {
            text: format!(
                "{dup} disc/track number{} used by more than one file.",
                if dup == 1 { " is" } else { "s are" }
            ),
            action: IssueAction::Tracks,
            level: IssueLevel::Warn,
        });
    }

    if small_cover {
        issues.push(Issue {
            text: cover_note(cover, min_cover),
            action: IssueAction::Cover,
            level: IssueLevel::Ingest,
        });
    }

    // The Discogs lines always come first (ADR 0054).
    issues.sort_by_key(|i| i.level != IssueLevel::Error);
    issues
}

/// `needs` when a blocking issue, `fixed` when every required step is done, else `ready` (ADR 0054).
pub fn status_of(issues: &[Issue], steps: &[StepStatus]) -> AlbumStatus {
    if issues
        .iter()
        .any(|i| i.level == IssueLevel::Warn || i.level == IssueLevel::Error)
    {
        return AlbumStatus::Needs;
    }
    let required_done = steps.iter().filter(|s| !s.step.optional()).all(|s| s.done);
    if required_done {
        AlbumStatus::Fixed
    } else {
        AlbumStatus::Ready
    }
}

/// The full summary of an album, from its already-read tracks (ADR 0054).
pub fn summarize(album: &Album, cfg: &SummaryConfig) -> AlbumSummary {
    let tracks = &album.tracks;
    let tags: Vec<&TagMap> = tracks.iter().map(|t| &t.tags).collect();
    let t0 = &tags[0];

    let did = tag(t0, &["DISCOGS_RELEASE_ID"]);
    let mid = tag(t0, &["MUSICBRAINZ_ALBUMID", "MUSICBRAINZ ALBUM ID"]);

    let album_title = tag(t0, &["ALBUM"]);
    let album_artist = tag(t0, &["ALBUMARTIST"]);
    let version = tag(t0, &["VERSION"]);
    let catalog = tag(t0, &CATALOG_KEYS[..1]);

    let n = tags.len();
    let kinds: Vec<_> = tracks
        .iter()
        .map(|t| {
            lyrics_kind(
                &tag(&t.tags, &["LYRICS"]),
                &tag(&t.tags, &["LYRICS_LANGUAGE"]),
            )
        })
        .collect();

    let syn = kinds
        .iter()
        .filter(|&&k| k == super::lyrics::LyricsKind::Lrc)
        .count();
    let pla = kinds
        .iter()
        .filter(|&&k| k == super::lyrics::LyricsKind::Txt)
        .count();
    let ins = kinds
        .iter()
        .filter(|&&k| k == super::lyrics::LyricsKind::Instrumental)
        .count();
    let mis = kinds
        .iter()
        .filter(|&&k| k == super::lyrics::LyricsKind::None)
        .count();

    let req = REQUIRED_TAGS.iter().all(|k| all_have(&tags, k))
        && all_have(&tags, &["DATE", "YEAR"])
        && all_have(&tags, &["VERSION"]);
    let small_cover = cfg.min_cover > 0
        && match album.cover {
            Some(c) => c.w < cfg.min_cover || c.h < cfg.min_cover,
            None => true,
        };

    let step_done = [
        all_have(&tags, &["DYNAMIC_RANGE"]),
        all_have(&tags, &["REPLAYGAIN_ALBUM_GAIN"]),
        all_have(&tags, &["ACOUSTID_FINGERPRINT", "ACOUSTID FINGERPRINT"]),
        !did.is_empty() && req,
        mis == 0,
        tracks.iter().all(|t| {
            file_name(&t.tags, &format!(".{}", t.extension)).is_some_and(|name| name == t.name)
        }),
    ];

    let track_rows: Vec<TrackRow> = tracks
        .iter()
        .map(|t| {
            let kind = lyrics_kind(
                &tag(&t.tags, &["LYRICS"]),
                &tag(&t.tags, &["LYRICS_LANGUAGE"]),
            );
            let tags_ok = !did.is_empty()
                && REQUIRED_TAGS.iter().all(|k| has(&t.tags, k))
                && has(&t.tags, &["DATE", "YEAR"])
                && has(&t.tags, &["VERSION"]);
            let name = file_name(&t.tags, &format!(".{}", t.extension));
            let title = tag(&t.tags, &["TITLE"]);
            TrackRow {
                name: t.name.clone(),
                file: t.rel.clone(),
                length_secs: t.duration_secs.round() as i64,
                channels: t.channels,
                format: rate_bits(t.sample_rate, t.bit_depth),
                disc: tag(&t.tags, &["DISCNUMBER"]),
                track: tag(&t.tags, &["TRACKNUMBER"]),
                title: if title.is_empty() {
                    Path::new(&t.name)
                        .file_stem()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned()
                } else {
                    title
                },
                dr: tag(&t.tags, &["DYNAMIC_RANGE"]),
                lyrics: kind,
                checks: [
                    has(&t.tags, &["DYNAMIC_RANGE"]),
                    has(&t.tags, &["REPLAYGAIN_ALBUM_GAIN"]),
                    has(&t.tags, &["ACOUSTID_FINGERPRINT", "ACOUSTID FINGERPRINT"]),
                    tags_ok,
                    kind != super::lyrics::LyricsKind::None,
                    name.is_some_and(|n| n == t.name),
                ],
            }
        })
        .collect();

    let steps: Vec<StepStatus> = Step::ALL
        .iter()
        .map(|&step| {
            let i = Step::ALL.iter().position(|&s| s == step).unwrap();
            let done = step_done[i];
            let partial = done
                && ((step == Step::Lyrics && pla > 0)
                    || (step == Step::TagsAndCover && small_cover));
            let note = if step == Step::TagsAndCover && small_cover {
                cover_note(album.cover, cfg.min_cover)
            } else {
                String::new()
            };
            StepStatus {
                step,
                done,
                partial,
                note,
            }
        })
        .collect();

    // What is open: per open step the tracks that fail it (ADR 0054). A release comes first.
    let missing = if did.is_empty() {
        Vec::new()
    } else {
        steps
            .iter()
            .filter(|s| !s.done)
            .map(|s| {
                let i = Step::ALL.iter().position(|&x| x == s.step).unwrap();
                let bad: Vec<&TrackRow> = track_rows.iter().filter(|r| !r.checks[i]).collect();
                MissingItem {
                    step: s.step,
                    label: s.step.missing_label().to_string(),
                    optional: s.step.optional(),
                    count: bad.len(),
                    of: track_rows.len(),
                    tracks: bad.iter().take(12).map(|r| r.title.clone()).collect(),
                }
            })
            .collect()
    };

    let issues = album_issues(&did, &tags, small_cover, album.cover, cfg.min_cover);
    let status = status_of(&issues, &steps);
    let edition = [version.as_str(), catalog.as_str()]
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" · ");

    AlbumSummary {
        folder: album.folder.to_string_lossy().into_owned(),
        name: album.name.clone(),
        current_folder: album.current_folder.clone(),
        artist: tag(t0, &["ALBUMARTIST", "ARTIST"]),
        artist_is_albumartist: has(t0, &["ALBUMARTIST"]),
        new_title: naming::bliss_album(&album_title, &album_artist, &version),
        album: album_title,
        cover: album.cover,
        artist_override: tag(t0, &["ALBUM_ARTIST_OVERRIDE"]),
        title_override: tag(t0, &["ALBUM_TITLE_OVERRIDE"]),
        year: first4(&tag(t0, &["DATE", "YEAR"])),
        release_year: first4(&tag(
            t0,
            &["ALBUM_RELEASE_YEAR", "RELEASEDATE", "DATE", "YEAR"],
        )),
        master_year: first4(&tag(
            t0,
            &["ALBUM_MASTER_YEAR", "ORIGINAL YEAR", "ORIGINALDATE"],
        )),
        edition_name: tag(t0, &["ALBUM_EDITION"]),
        catalog,
        country: tag(
            t0,
            &[
                "DISCOGS_ALBUM_RELEASECOUNTRY",
                "COUNTRY",
                "MUSICBRAINZ_ALBUM_RELEASECOUNTRY",
            ],
        ),
        media: tag(t0, &["ALBUM_FORMAT"]),
        version,
        discogs_id: did,
        master: tag(t0, &["DISCOGS_MASTER_ID"])
            .trim_start_matches(['m', 'M'])
            .to_string(),
        musicbrainz_id: mid,
        track_count: n,
        edition,
        dr: {
            let a = tag(t0, &["ALBUM_DR"]);
            if a.is_empty() {
                track_dr_mean(&tags)
            } else {
                a
            }
        },
        lyrics: LyricsCounts {
            synced: syn,
            plain: pla,
            instrumental: ins,
            missing: mis,
        },
        steps_done: steps.iter().filter(|s| s.done).count(),
        tags_ok: req,
        missing,
        issues,
        status,
        tracks: track_rows,
        steps,
        mtime: tracks.iter().map(|t| t.mtime_ns).max().unwrap_or(0).max(0) as u64,
    }
}

fn first4(s: &str) -> String {
    s.chars().take(4).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn track(tags: &[(&str, &str)], name: &str) -> Track {
        let mut map = BTreeMap::new();
        for (k, v) in tags {
            map.insert(k.to_string(), vec![v.to_string()]);
        }
        Track {
            path: Path::new("/tmp/album").join(name),
            rel: name.to_string(),
            name: name.to_string(),
            extension: "flac".to_string(),
            tags: map,
            channels: 2,
            sample_rate: 44100,
            bit_depth: 16,
            duration_secs: 200.0,
            size: 0,
            mtime_ns: 1,
            pictures: vec![],
        }
    }

    fn album_with(tags: &[(&str, &str)]) -> Album {
        Album {
            folder: Path::new("/tmp/album").to_path_buf(),
            name: "album".to_string(),
            current_folder: "album".to_string(),
            cover: Some(CoverInfo {
                w: 1500,
                h: 1500,
                bytes: 100,
                embedded: true,
            }),
            tracks: vec![track(tags, "01_01_Title.flac")],
        }
    }

    #[test]
    fn no_discogs_is_needs_with_one_error() {
        let album = album_with(&[("TITLE", "Title")]);
        let s = summarize(&album, &SummaryConfig::default());
        assert_eq!(s.status, AlbumStatus::Needs);
        assert_eq!(s.issues.len(), 1);
        assert_eq!(s.issues[0].level, IssueLevel::Error);
        assert!(s.missing.is_empty());
    }

    #[test]
    fn fully_tagged_album_is_fixed() {
        let tags = [
            ("DISCOGS_RELEASE_ID", "123"),
            ("ARTIST", "Artist"),
            ("ALBUMARTIST", "Artist"),
            ("TITLE", "Title"),
            ("ALBUM", "Album"),
            ("TRACKNUMBER", "1"),
            ("DISCNUMBER", "1"),
            ("ALBUM_FORMAT", "CD"),
            ("CATALOGNUMBER", "CAT1"),
            ("DATE", "2020"),
            ("VERSION", "[2020]"),
            ("DYNAMIC_RANGE", "12"),
            ("ALBUM_DR", "12"),
            ("REPLAYGAIN_ALBUM_GAIN", "-9.0 dB"),
            ("ACOUSTID_FINGERPRINT", "abc"),
            ("LYRICS", "[00:01.00]Hi"),
        ];
        let album = album_with(&tags);
        let s = summarize(&album, &SummaryConfig::default());
        assert_eq!(s.status, AlbumStatus::Fixed);
        assert!(s.issues.is_empty());
    }

    #[test]
    fn missing_lyrics_is_optional() {
        let tags = [
            ("DISCOGS_RELEASE_ID", "123"),
            ("ARTIST", "Artist"),
            ("ALBUMARTIST", "Artist"),
            ("TITLE", "Title"),
            ("ALBUM", "Album"),
            ("TRACKNUMBER", "1"),
            ("DISCNUMBER", "1"),
            ("ALBUM_FORMAT", "CD"),
            ("CATALOGNUMBER", "CAT1"),
            ("DATE", "2020"),
            ("VERSION", "[2020]"),
            ("DYNAMIC_RANGE", "12"),
            ("REPLAYGAIN_ALBUM_GAIN", "-9.0 dB"),
            ("ACOUSTID_FINGERPRINT", "abc"),
        ];
        let album = album_with(&tags);
        let s = summarize(&album, &SummaryConfig::default());
        assert_eq!(s.status, AlbumStatus::Fixed);
        assert!(
            !s.steps
                .iter()
                .find(|s| s.step == Step::Lyrics)
                .unwrap()
                .done
        );
    }

    #[test]
    fn small_cover_blocks_move_only() {
        let tags = [
            ("DISCOGS_RELEASE_ID", "123"),
            ("ARTIST", "Artist"),
            ("ALBUMARTIST", "Artist"),
            ("TITLE", "Title"),
            ("ALBUM", "Album"),
            ("TRACKNUMBER", "1"),
            ("DISCNUMBER", "1"),
            ("ALBUM_FORMAT", "CD"),
            ("CATALOGNUMBER", "CAT1"),
            ("DATE", "2020"),
            ("VERSION", "[2020]"),
            ("DYNAMIC_RANGE", "12"),
            ("REPLAYGAIN_ALBUM_GAIN", "-9.0 dB"),
            ("ACOUSTID_FINGERPRINT", "abc"),
            ("LYRICS", "[00:01.00]Hi"),
        ];
        let mut album = album_with(&tags);
        album.cover = Some(CoverInfo {
            w: 500,
            h: 500,
            bytes: 100,
            embedded: true,
        });
        let s = summarize(&album, &SummaryConfig::default());
        // status stays fixed (the cover only blocks the move), but Tags and cover is partial.
        assert_eq!(s.status, AlbumStatus::Fixed);
        assert!(s.issues.iter().any(|i| i.level == IssueLevel::Ingest));
    }
}
