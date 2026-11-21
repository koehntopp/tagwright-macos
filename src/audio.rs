//! The audio seam (ADR 0058): every audio file is read through this module.
//!
//! FLAC tags are Vorbis comments (read raw, so custom keys such as `DYNAMIC_RANGE` survive).
//! MP3 tags are ID3v2 frames mapped to the Vorbis-style model (ADR 0059). Everything else works
//! on the upper-case key model in `crate::domain`.

use std::collections::BTreeMap;
use std::path::Path;

use lofty::config::ParseOptions;
use lofty::flac::FlacFile;
use lofty::id3::v2::{Frame, Id3v2Tag};
use lofty::mpeg::MpegFile;
use lofty::ogg::{OggPictureStorage, tag::VorbisComments};
use lofty::picture::PictureType;
use lofty::prelude::*;

use crate::domain::TagMap;
use crate::domain::model::{Picture, Track};

fn insert(map: &mut TagMap, key: String, value: String) {
    map.entry(key.to_uppercase()).or_default().push(value);
}

/// Read one audio file into the domain `Track`. `album_root` is the album folder, used for the
/// file's relative path (ADR 0054's signature). Custom tags survive because the format-specific
/// tag (Vorbis comments, ID3v2 frames) is read directly, not the lossy unified `Tag` (ADR 0058).
pub fn read_track(path: &Path, album_root: &Path) -> anyhow::Result<Track> {
    let extension = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();

    let mut tags: TagMap = BTreeMap::new();
    let mut pictures: Vec<Picture> = Vec::new();

    let (channels, sample_rate, bit_depth, duration_secs) = match extension.as_str() {
        "flac" => {
            let mut file = std::fs::File::open(path)?;
            let flac = FlacFile::read_from(&mut file, ParseOptions::new())?;
            if let Some(vc) = flac.vorbis_comments() {
                read_vorbis(vc, &mut tags, &mut pictures);
            } else {
                for (pic, info) in flac.pictures() {
                    push_picture(&mut pictures, pic, info.width, info.height);
                }
            }
            let p = flac.properties();
            (
                p.channels(),
                p.sample_rate(),
                p.bit_depth(),
                p.duration().as_secs_f64(),
            )
        }
        "mp3" => {
            let mut file = std::fs::File::open(path)?;
            let mpeg = MpegFile::read_from(&mut file, ParseOptions::new())?;
            if let Some(id3) = mpeg.id3v2() {
                read_id3(id3, &mut tags, &mut pictures);
            }
            let p = mpeg.properties();
            (
                p.channels(),
                p.sample_rate(),
                0u8,
                p.duration().as_secs_f64(),
            )
        }
        _ => anyhow::bail!("unsupported audio extension: {extension}"),
    };

    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let rel = path
        .strip_prefix(album_root)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| name.clone());

    let metadata = std::fs::metadata(path)?;
    let mtime_ns = metadata
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as i64)
        .unwrap_or(0);

    Ok(Track {
        path: path.to_path_buf(),
        rel,
        name,
        extension,
        tags,
        channels,
        sample_rate,
        bit_depth,
        duration_secs,
        size: metadata.len(),
        mtime_ns,
        pictures,
    })
}

fn push_picture(
    pictures: &mut Vec<Picture>,
    pic: &lofty::picture::Picture,
    width: u32,
    height: u32,
) {
    let (w, h) = if width != 0 && height != 0 {
        (width, height)
    } else {
        image_dims(pic.data())
    };
    pictures.push(Picture {
        pic_type: pic.pic_type().as_u8() as u32,
        mime: pic
            .mime_type()
            .map(|m| m.as_str().to_string())
            .unwrap_or_default(),
        width: w,
        height: h,
        len: pic.data().len(),
    });
}

fn read_vorbis(vc: &VorbisComments, tags: &mut TagMap, pictures: &mut Vec<Picture>) {
    for (key, value) in vc.items() {
        insert(tags, key.to_string(), value.to_string());
    }
    for (pic, info) in vc.pictures() {
        push_picture(pictures, pic, info.width, info.height);
    }
}

fn read_id3(id3: &Id3v2Tag, tags: &mut TagMap, pictures: &mut Vec<Picture>) {
    for frame in id3 {
        match frame {
            Frame::Text(tif) => {
                let value = tif.value.as_ref().to_string();
                let key = match frame.id_str() {
                    "TIT2" => "TITLE",
                    "TPE1" => "ARTIST",
                    "TPE2" => "ALBUMARTIST",
                    "TALB" => "ALBUM",
                    "TDRC" => "DATE",
                    "TDOR" => "ORIGINALDATE",
                    "TCON" => "GENRE",
                    "TCOM" => "COMPOSER",
                    "TPUB" => "LABEL",
                    "TMED" => "MEDIA",
                    "TPE3" => "CONDUCTOR",
                    "TSSE" => "ENCODER_SETTINGS",
                    _ => "",
                };
                if !key.is_empty() {
                    insert(tags, key.to_string(), value);
                }
            }
            Frame::UserText(etf) => {
                insert(tags, etf.description.to_string(), etf.content.to_string());
            }
            Frame::UnsynchronizedText(utf) => {
                insert(tags, "LYRICS".to_string(), utf.content.to_string());
            }
            Frame::Comment(cf) => {
                insert(tags, "COMMENT".to_string(), cf.content.to_string());
            }
            Frame::Picture(apf) => {
                push_picture(pictures, apf.picture.as_ref(), 0, 0);
            }
            _ => {}
        }
    }
    // TRCK "3/12" -> TRACKNUMBER, TRACKTOTAL and TOTALTRACKS; TPOS "1/2" -> DISCNUMBER, ...
    split_number_frames(
        id3,
        "TRCK",
        tags,
        &["TRACKNUMBER"],
        &["TRACKTOTAL", "TOTALTRACKS"],
    );
    split_number_frames(
        id3,
        "TPOS",
        tags,
        &["DISCNUMBER"],
        &["DISCTOTAL", "TOTALDISCS"],
    );
}

fn split_number_frames(
    id3: &Id3v2Tag,
    frame_id: &str,
    tags: &mut TagMap,
    first_keys: &[&str],
    rest_keys: &[&str],
) {
    for frame in id3 {
        if let Frame::Text(tif) = frame
            && frame.id_str() == frame_id
        {
            let value = tif.value.as_ref();
            let mut parts = value.splitn(2, '/');
            let first = parts.next().unwrap_or("").to_string();
            let rest = parts.next().unwrap_or("");
            if !first.is_empty() {
                for key in first_keys {
                    insert(tags, (*key).to_string(), first.clone());
                }
            }
            if !rest.is_empty() {
                for key in rest_keys {
                    insert(tags, (*key).to_string(), rest.to_string());
                }
            }
        }
    }
}

/// The pixel dimensions of an image (ADR 0016 decodes the cover when the stored size is unset).
pub fn image_dims(data: &[u8]) -> (u32, u32) {
    image::load_from_memory(data)
        .map(|img| (img.width(), img.height()))
        .unwrap_or((0, 0))
}

/// The picture type number for a standard cover type (ADR 0090).
pub fn picture_type_num(t: PictureType) -> u32 {
    t.as_u8() as u32
}
