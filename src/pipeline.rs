//! The pipeline runner (ADR 0036, 0054): the six steps run one after another, the external tools
//! (`drcalc`, `rsgain`, `fpscan`) found on `PATH`.

use std::path::Path;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::domain::model::Step;

pub type Log = dyn FnMut(&str) + Send;

/// Find an external tool on `PATH`.
fn find_tool(name: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}

/// Run a step's child tool, streaming its output lines to `log`. The process is not detached into
/// its own group yet, so Stop kills only the direct child (ADR 0008's process-group rule is noted,
/// not implemented).
fn run_tool(bin: &str, args: &[&str], log: &mut Log, stop: &AtomicBool) -> bool {
    let Some(tool) = find_tool(bin) else {
        log(&format!("{bin} not found on PATH; step skipped"));
        return false;
    };
    let mut child = match Command::new(&tool)
        .args(args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            log(&format!("could not start {bin}: {e}"));
            return false;
        }
    };
    let out = child.stdout.take().map(std::io::BufReader::new);
    if let Some(mut reader) = out {
        use std::io::BufRead;
        let mut line = String::new();
        while !stop.load(Ordering::Relaxed) {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => log(line.trim_end()),
                Err(_) => break,
            }
        }
    }
    if stop.load(Ordering::Relaxed) {
        let _ = child.kill();
        log("-- stopped by user");
        return false;
    }
    matches!(child.wait(), Ok(status) if status.success())
}

/// Run the pipeline for one album, in order (ADR 0036). Returns when all steps have run; a failing
/// step is logged and the rest continue (ADR 0036). The Discogs and lyrics steps are not yet
/// implemented (see ADR 0094).
pub fn run_album(album: &Path, log: &mut Log, stop: &AtomicBool) {
    for step in Step::ALL {
        if stop.load(Ordering::Relaxed) {
            break;
        }
        match step {
            Step::DynamicRange => {
                log("Dynamic range (drcalc)");
                run_tool("drcalc", &["-w", "-q", &album.to_string_lossy()], log, stop);
            }
            Step::ReplayGain => {
                log("ReplayGain (rsgain)");
                run_tool(
                    "rsgain",
                    &["custom", "-s", "-q", &album.to_string_lossy()],
                    log,
                    stop,
                );
            }
            Step::Fingerprints => {
                log("Fingerprints (fpscan)");
                run_tool("fpscan", &[&album.to_string_lossy()], log, stop);
            }
            Step::TagsAndCover => {
                log("Tags and cover: not yet implemented (Discogs assignment needed)");
            }
            Step::Lyrics => {
                log("Lyrics: not yet implemented (lrclib needed)");
            }
            Step::Filenames => {
                log("Filenames");
                rename_album_files(album, log);
            }
        }
    }
}

/// Rename the files of an album to the bliss name, in place (ADR 0010, 0038).
pub fn rename_album_files(album: &Path, log: &mut Log) {
    let renames = crate::domain::layout::album_files(album, None)
        .iter()
        .map(|f| {
            let Ok(track) = crate::audio::read_track(f, album) else {
                return (f.to_string_lossy().into_owned(), None);
            };
            let disc = crate::domain::tag(&track.tags, &["DISCNUMBER"]);
            let track_num = crate::domain::tag(&track.tags, &["TRACKNUMBER"]);
            let title = crate::domain::tag(&track.tags, &["TITLE"]);
            let suffix = format!(".{}", track.extension);
            (
                f.file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned(),
                crate::domain::naming::bliss_name(&disc, &track_num, &title, &suffix),
            )
        })
        .collect::<Vec<_>>();
    for line in crate::domain::naming::rename_files(album, &renames) {
        log(&line);
    }
}
