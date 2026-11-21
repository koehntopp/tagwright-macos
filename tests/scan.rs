//! End-to-end smoke test of the scan + status pipeline against real FLAC files.
//!
//! Uses `flac` and `metaflac` from `PATH` to build a synthetic album (ADR 0018's scratch
//! discipline), then checks `scan` + `summarize`. Skipped when the tools are missing.

use std::path::Path;
use std::process::Command;

use tagwright_macos::domain::SummaryConfig;
use tagwright_macos::domain::model::AlbumStatus;
use tagwright_macos::domain::status::summarize;

fn have(tool: &str) -> bool {
    Command::new(tool).arg("--version").output().is_ok()
}

/// Write a tiny silent 16-bit mono WAV.
fn write_wav(path: &Path, seconds: f32) {
    let sample_rate = 44100u32;
    let samples = (sample_rate as f32 * seconds) as u32;
    let data_size = samples * 2;
    let mut buf = Vec::with_capacity(44 + data_size as usize);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_size).to_le_bytes());
    buf.extend_from_slice(b"WAVEfmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes()); // PCM
    buf.extend_from_slice(&1u16.to_le_bytes()); // mono
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&(sample_rate * 2).to_le_bytes()); // byte rate
    buf.extend_from_slice(&2u16.to_le_bytes()); // block align
    buf.extend_from_slice(&16u16.to_le_bytes()); // bits
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_size.to_le_bytes());
    buf.extend(std::iter::repeat_n(0u8, data_size as usize));
    std::fs::write(path, buf).unwrap();
}

fn make_flac(dir: &Path, name: &str, tags: &[(&str, &str)]) {
    let wav = dir.join(format!("{name}.wav"));
    write_wav(&wav, 0.5);
    let flac = dir.join(format!("{name}.flac"));
    let status = Command::new("flac")
        .arg("--silent")
        .arg("-f")
        .arg("-o")
        .arg(&flac)
        .arg(&wav)
        .status()
        .unwrap();
    assert!(status.success(), "flac failed");
    for (k, v) in tags {
        let status = Command::new("metaflac")
            .arg(format!("--set-tag={k}={v}"))
            .arg(&flac)
            .status()
            .unwrap();
        assert!(status.success(), "metaflac failed for {k}");
    }
    std::fs::remove_file(wav).unwrap();
}

#[test]
fn scans_a_tagged_flac_album() {
    if !have("flac") || !have("metaflac") {
        eprintln!("skipping: flac/metaflac not on PATH");
        return;
    }
    let root = std::env::temp_dir().join("tagwright-smoke");
    let _ = std::fs::remove_dir_all(&root);
    let album_dir = root.join("Pink Floyd - The Wall");
    std::fs::create_dir_all(&album_dir).unwrap();

    make_flac(
        &album_dir,
        "01_In the Flesh",
        &[
            ("TITLE", "In the Flesh?"),
            ("ARTIST", "Pink Floyd"),
            ("ALBUMARTIST", "Pink Floyd"),
            ("ALBUM", "The Wall"),
            ("TRACKNUMBER", "1"),
            ("DISCNUMBER", "1"),
            ("DATE", "1979"),
        ],
    );

    let albums = tagwright_macos::scan::scan(&root, Some(&root));
    assert_eq!(albums.len(), 1, "one album expected");
    let summary = summarize(&albums[0], &SummaryConfig::default());

    assert_eq!(summary.artist, "Pink Floyd");
    assert_eq!(summary.album, "The Wall");
    assert_eq!(summary.status, AlbumStatus::Needs);
    // Without a Discogs release ID the only issue is the red Discogs line (ADR 0054).
    assert_eq!(summary.issues.len(), 1);
    assert_eq!(summary.track_count, 1);
    assert!(summary.issues[0].text.contains("Discogs release ID"));

    let _ = std::fs::remove_dir_all(&root);
}
