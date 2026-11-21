//! Lyrics kinds (ADR 0054): the same rule as tagwright's `lyric_kind`.

use std::sync::OnceLock;

use regex::Regex;

/// How a track's lyrics read. `Instrumental`, `Lrc` (synced), `Txt` (plain) or `None`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LyricsKind {
    None,
    Instrumental,
    Lrc,
    Txt,
}

impl LyricsKind {
    /// The short badge label (ADR 0015): `LRC`, `TXT`, `INS`, `---`.
    pub fn badge(self) -> &'static str {
        match self {
            LyricsKind::None => "---",
            LyricsKind::Instrumental => "INS",
            LyricsKind::Lrc => "LRC",
            LyricsKind::Txt => "TXT",
        }
    }
}

fn synced_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\[\d{2}:\d{2}\.\d{2}\]").unwrap())
}

fn instrumental_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)\[instrumental:true\]|\[\d{2}:\d{2}\.\d{2}\]\s*(?:\[instrumental\]|\(instrumental\))")
            .unwrap()
    })
}

/// The lyrics kind of a track, from its `LYRICS` (first value) and `LYRICS_LANGUAGE` (ADR 0054).
pub fn lyrics_kind(lyrics: &str, language: &str) -> LyricsKind {
    if lyrics.trim().is_empty() {
        return if language == "zxx" {
            LyricsKind::Instrumental
        } else {
            LyricsKind::None
        };
    }
    if instrumental_re().is_match(lyrics) {
        return LyricsKind::Instrumental;
    }
    if synced_re().is_match(lyrics) {
        LyricsKind::Lrc
    } else {
        LyricsKind::Txt
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds() {
        assert_eq!(lyrics_kind("", ""), LyricsKind::None);
        assert_eq!(lyrics_kind("", "zxx"), LyricsKind::Instrumental);
        assert_eq!(
            lyrics_kind("[instrumental:true]", ""),
            LyricsKind::Instrumental
        );
        assert_eq!(
            lyrics_kind("[00:00.00][Instrumental]", ""),
            LyricsKind::Instrumental
        );
        assert_eq!(lyrics_kind("[00:12.34]La la la", ""), LyricsKind::Lrc);
        assert_eq!(lyrics_kind("just plain text", ""), LyricsKind::Txt);
    }
}
