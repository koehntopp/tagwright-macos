//! Scan the staging and library folders into albums (ADR 0054, 0076, 0016).

use std::path::{Path, PathBuf};

use crate::audio;
use crate::domain::layout;
use crate::domain::model::{Album, CoverInfo, Track};

const COVER_FILES: [&str; 4] = ["cover.jpg", "folder.jpg", "cover.png", "folder.png"];

/// The cover an album shows: the embedded front cover (type 3) of the first file, else its first
/// picture, else a folder image (ADR 0016).
fn cover_from(first: &Track, album_folder: &Path) -> Option<CoverInfo> {
    let pic = first
        .pictures
        .iter()
        .find(|p| p.pic_type == 3)
        .or_else(|| first.pictures.first());
    if let Some(pic) = pic {
        return Some(CoverInfo {
            w: pic.width,
            h: pic.height,
            bytes: pic.len as u64,
            embedded: true,
        });
    }
    for name in COVER_FILES {
        let img = album_folder.join(name);
        if img.is_file()
            && let Ok(data) = std::fs::read(&img)
        {
            let (w, h) = audio::image_dims(&data);
            if w > 0 && h > 0 {
                return Some(CoverInfo {
                    w,
                    h,
                    bytes: data.len() as u64,
                    embedded: false,
                });
            }
        }
    }
    None
}

/// Read one album folder into an `Album` (empty albums return `None`).
pub fn read_album(folder: &Path, staging: Option<&Path>, base: &Path) -> Option<Album> {
    let files = layout::album_files(folder, staging);
    if files.is_empty() {
        return None;
    }
    let tracks: Vec<Track> = files
        .iter()
        .filter_map(|f| audio::read_track(f, folder).ok())
        .collect();
    if tracks.is_empty() {
        return None;
    }
    let cover = cover_from(&tracks[0], folder);
    let current_folder = folder
        .strip_prefix(base)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| folder.to_string_lossy().into_owned());
    Some(Album {
        folder: folder.to_path_buf(),
        name: folder
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default(),
        current_folder,
        cover,
        tracks,
    })
}

/// Scan every album below `base` (staging rules apply when `base` is the staging folder).
pub fn scan(base: &Path, staging: Option<&Path>) -> Vec<Album> {
    layout::album_dirs(base, staging)
        .iter()
        .filter_map(|d| read_album(d, staging, base))
        .collect()
}

/// The albums below `base` whose audio files have changed since `signatures` (None = fresh). Used
/// by the scan cache; not yet implemented (ADR 0067).
pub fn changed_albums(
    _base: &Path,
    _staging: Option<&Path>,
    _signatures: &std::collections::BTreeMap<String, Vec<(String, i64, u64)>>,
) -> Vec<PathBuf> {
    Vec::new()
}
