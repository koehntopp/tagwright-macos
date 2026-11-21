//! File names and library paths (ADR 0010, 0037): the bliss pattern and `clean()`.
//!
//! `clean()` is a port of tagwright's `pipeline/naming.py::clean()`, which is
//! `sanitize_filename(slugify(text, lowercase=False, separator='_'))`. It is kept as close to
//! the original as the available Rust crates allow: `deunicode` stands in for `unidecode`/`text-unidecode`.
//! Byte-for-byte parity with python-slugify for non-Latin scripts is a known gap (see ADR 0094).

use std::path::Path;
use std::sync::OnceLock;

use regex::Regex;
use unicode_normalization::UnicodeNormalization;

/// The byte limit of one file name on common filesystems (ADR 0010).
pub const NAME_MAX: usize = 255;

fn quote_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[']+").unwrap())
}

fn disallowed_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[^-a-zA-Z0-9]+").unwrap())
}

fn dup_dash_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"-{2,}").unwrap())
}

/// Decode the HTML entities the tagwright slug decodes (`&amp;`, numeric references). Real music
/// titles rarely carry them, so the common named set and numeric forms cover the space (ADR 0094).
fn decode_entities(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'&'
            && let Some(end) = s[i..].find(';')
        {
            let body = &s[i + 1..i + end];
            let decoded: Option<char> = match body {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                _ if body.starts_with("#x") || body.starts_with("#X") => {
                    u32::from_str_radix(&body[2..], 16)
                        .ok()
                        .and_then(char::from_u32)
                }
                _ if body.starts_with('#') => {
                    body[1..].parse::<u32>().ok().and_then(char::from_u32)
                }
                _ => None,
            };
            if let Some(c) = decoded {
                out.push(c);
                i += end + 1;
                continue;
            }
        }
        out.push(s[i..].chars().next().unwrap());
        i += s[i..].chars().next().unwrap().len_utf8();
    }
    out
}

/// Remove commas that sit between two digits (`10,000` -> `10000`), the slug's number rule.
fn remove_number_commas(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    for (i, &c) in chars.iter().enumerate() {
        if c == ','
            && i > 0
            && i + 1 < chars.len()
            && chars[i - 1].is_ascii_digit()
            && chars[i + 1].is_ascii_digit()
        {
            continue;
        }
        out.push(c);
    }
    out
}

/// The port of `pipeline/naming.py::clean()`:
/// `sanitize_filename(slugify(text, lowercase=False, separator='_'))`, matching python-slugify's
/// frozen legacy pipeline byte for byte on ASCII and Latin input (ADR 0094 notes the non-Latin gap).
pub fn clean(text: &str) -> String {
    // slugify's internal separator is '-'; it is mapped to '_' only at the end.
    let s = quote_re().replace_all(text, "-");
    let s = deunicode::deunicode(&s.nfkd().collect::<String>());
    let s = decode_entities(&s);
    let s: String = s.nfkd().collect();
    // lowercase=False: case is kept.
    let s = quote_re().replace_all(&s, "");
    let s = remove_number_commas(&s);
    let s = disallowed_re().replace_all(&s, "-");
    let s = dup_dash_re().replace_all(&s, "-");
    let s = s.trim_matches('-').to_string();
    // sanitize_filename caps a name at 255 characters; clean() is also the folder-name cap.
    s.replace('-', "_").chars().take(255).collect()
}

/// Equal ignoring case and Unicode normalisation form (a case-insensitive volume sees these as one file).
pub fn same_name(a: &str, b: &str) -> bool {
    fn n(x: &str) -> String {
        x.nfd().collect::<String>().to_lowercase()
    }
    n(a) == n(b)
}

/// `bliss_name`: `<disc>_<track>_<title>`, or `None` while `TITLE`, `TRACKNUMBER` or `DISCNUMBER`
/// is empty (ADR 0010). `suffix` is the file's own lower-case extension including the dot.
pub fn bliss_name(disc: &str, track: &str, title: &str, suffix: &str) -> Option<String> {
    if title.is_empty() || track.is_empty() || disc.is_empty() {
        return None;
    }
    let head = format!(
        "{}_{}_",
        zero2(disc.split('/').next().unwrap_or("")),
        zero2(track.split('/').next().unwrap_or(""))
    );
    let room = NAME_MAX.saturating_sub(head.len() + suffix.len());
    let body = clean(title);
    let body = truncate_bytes(&body, room)
        .trim_end_matches(['_', ' ', '.'])
        .to_string();
    Some(format!("{head}{body}{suffix}"))
}

fn zero2(s: &str) -> String {
    if s.len() >= 2 {
        s.to_string()
    } else {
        format!("{s:0>2}")
    }
}

fn truncate_bytes(s: &str, max: usize) -> &str {
    let mut end = s.len();
    while end > 0 && s[..end].len() > max {
        end -= 1;
    }
    &s[..end]
}

/// `bliss_album`: `<album artist>/<album [version]>`, or `""` while `ALBUMARTIST` or `ALBUM` is
/// empty (ADR 0010 — no `ARTIST` fallback).
pub fn bliss_album(album: &str, artist: &str, version: &str) -> String {
    if album.is_empty() || artist.is_empty() {
        return String::new();
    }
    let mut album = album.to_string();
    if !version.is_empty() && !album.contains(version) {
        album = format!("{album} {version}");
    }
    format!("{}/{}", clean(artist), clean(&album))
}

/// Rename `from` to `to`, skipping when the target exists under a different spelling; returns a log
/// line (ADR 0010). `None` target means a missing required tag (not renamed).
pub fn rename_files(album: &Path, renames: &[(String, Option<String>)]) -> Vec<String> {
    let mut out = Vec::new();
    for (name, target) in renames {
        let Some(target) = target else {
            out.push(format!("skip {name}: title, disc or track number is empty"));
            continue;
        };
        let from = album.join(name);
        let dest = album.join(target);
        if name == target.as_str() {
            continue;
        }
        if dest.exists() && !same_name(&dest.to_string_lossy(), &from.to_string_lossy()) {
            out.push(format!("skip {name}: {target} already exists"));
            continue;
        }
        if std::fs::rename(&from, &dest).is_ok() {
            out.push(format!("renamed {name} -> {target}"));
        }
    }
    if out.is_empty() {
        vec!["filenames already match".to_string()]
    } else {
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_keeps_case_and_underscores() {
        assert_eq!(clean("Led Zeppelin"), "Led_Zeppelin");
        assert_eq!(clean("AC/DC"), "AC_DC");
        assert_eq!(clean("R&B"), "R_B");
        assert_eq!(
            clean("U2: The Best of 1990-2000"),
            "U2_The_Best_of_1990_2000"
        );
    }

    #[test]
    fn clean_strips_umlauts() {
        assert_eq!(clean("Björk"), "Bjork");
        assert_eq!(clean("Mötley Crüe"), "Motley_Crue");
    }

    #[test]
    fn clean_trims_edges() {
        assert_eq!(clean("  Hello  "), "Hello");
        assert_eq!(clean("O.K."), "O_K");
    }

    // Golden cases produced by the real tagwright `clean()` (python-slugify 9 legacy + pathvalidate).
    #[test]
    fn clean_golden() {
        let cases: &[(&str, &str)] = &[
            ("Pink Floyd", "Pink_Floyd"),
            ("The Wall [2000]", "The_Wall_2000"),
            ("AC/DC", "AC_DC"),
            ("R&B", "R_B"),
            ("Don't Stop Believin'", "Don_t_Stop_Believin"),
            ("U2: The Best of 1990-2000", "U2_The_Best_of_1990_2000"),
            ("Björk", "Bjork"),
            ("Mötley Crüe", "Motley_Crue"),
            ("O.K.", "O_K"),
            ("Étude №1", "Etude_No1"),
            ("Ænima", "AEnima"),
            ("…And Justice for All", "And_Justice_for_All"),
            ("10,000 Maniacs", "10000_Maniacs"),
            ("Come & Get It", "Come_Get_It"),
            ("5.1 Surround Mix", "5_1_Surround_Mix"),
            ("Live at Wembley (1990)", "Live_at_Wembley_1990"),
            ("Café del Mar, Vol. 1", "Cafe_del_Mar_Vol_1"),
            ("St. Vincent", "St_Vincent"),
            ("Tchaikovsky: Swan Lake", "Tchaikovsky_Swan_Lake"),
            ("Ørnen", "Ornen"),
            ("Dvořák — Symphony No. 9", "Dvorak_Symphony_No_9"),
            ("æ ø å", "ae_o_a"),
            ("It's Gonna Be Alright", "It_s_Gonna_Be_Alright"),
            ("Rødhåd", "Rodhad"),
            ("中文标题", "Zhong_Wen_Biao_Ti"),
            ("日本語タイトル", "Ri_Ben_Yu_taitoru"),
            ("한국어", "hangugeo"),
            ("Привет Мир", "Privet_Mir"),
            ("Ελληνικά", "Ellenika"),
            ("עברית", "bryt"),
            ("It’s Gonna Be Alright", "Its_Gonna_Be_Alright"),
            ("James Brown & \"The F.B.I.\"", "James_Brown_The_F_B_I"),
            ("Sgt. Pepper's Lonely Hearts", "Sgt_Pepper_s_Lonely_Hearts"),
        ];
        for (input, expected) in cases {
            assert_eq!(clean(input), *expected, "clean({input:?})");
        }
    }

    #[test]
    fn bliss_name_zero_pads_and_drops_totals() {
        assert_eq!(
            bliss_name("1/2", "3", "Song", ".flac").unwrap(),
            "01_03_Song.flac"
        );
        assert_eq!(
            bliss_name("2", "12", "Track", ".mp3").unwrap(),
            "02_12_Track.mp3"
        );
        assert_eq!(bliss_name("", "1", "T", ".flac"), None);
    }

    #[test]
    fn bliss_album_adds_version_once() {
        assert_eq!(
            bliss_album("The Wall", "Pink Floyd", "[2000]"),
            "Pink_Floyd/The_Wall_2000"
        );
        assert_eq!(bliss_album("", "Artist", "[2000]"), "");
    }
}
