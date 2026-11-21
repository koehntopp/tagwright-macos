//! Channel-layout badges (ADR 0040).

/// The short channel badge: `Mono`, `Stereo`, `5.1`, `7.1`, `3.0`, `4.0`, `5.0`, `6.1`, else `N ch`.
pub fn channel_label(channels: u8) -> String {
    match channels {
        1 => "Mono".to_string(),
        2 => "Stereo".to_string(),
        6 => "5.1".to_string(),
        8 => "7.1".to_string(),
        3 => "3.0".to_string(),
        4 => "4.0".to_string(),
        5 => "5.0".to_string(),
        7 => "6.1".to_string(),
        n => format!("{n} ch"),
    }
}

/// True for more than stereo (the violet badge colour, ADR 0040).
pub fn is_multichannel(channels: u8) -> bool {
    channels > 2
}

/// The channel count a release-track title names (`(5.1 Mix)`, `Mono`), `0` when it names none.
/// The hint only matches the word, so `Monologue` and `15.1` do not (ADR 0040).
pub fn channels_from_title(title: &str) -> u8 {
    use regex::Regex;
    use std::sync::OnceLock;

    fn re() -> &'static [(Regex, u8)] {
        static HINTS: OnceLock<Vec<(Regex, u8)>> = OnceLock::new();
        HINTS.get_or_init(|| {
            vec![
                (Regex::new(r"(?i)\bmono\b").unwrap(), 1),
                (Regex::new(r"(?i)\bstereo\b").unwrap(), 2),
            ]
        })
    }

    for (pattern, channels) in re() {
        if pattern.is_match(title) {
            return *channels;
        }
    }
    if match_float_hint(title, "5.1") {
        return 6;
    }
    if match_float_hint(title, "7.1") {
        return 8;
    }
    0
}

/// Matches `5.1` / `7.1` not surrounded by a digit or a dot (so `15.1` and `5.10` do not match).
fn match_float_hint(title: &str, target: &str) -> bool {
    let bytes = title.as_bytes();
    let t = target.as_bytes();
    for i in 0..=bytes.len().saturating_sub(t.len()) {
        if &bytes[i..i + t.len()] == t {
            let before = i > 0 && (bytes[i - 1].is_ascii_digit() || bytes[i - 1] == b'.');
            let after = i + t.len() < bytes.len()
                && (bytes[i + t.len()].is_ascii_digit() || bytes[i + t.len()] == b'.');
            if !before && !after {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels() {
        assert_eq!(channel_label(1), "Mono");
        assert_eq!(channel_label(2), "Stereo");
        assert_eq!(channel_label(6), "5.1");
        assert_eq!(channel_label(8), "7.1");
        assert_eq!(channel_label(9), "9 ch");
    }

    #[test]
    fn title_hints() {
        assert_eq!(channels_from_title("Song (5.1 Mix)"), 6);
        assert_eq!(channels_from_title("Song (Mono)"), 1);
        assert_eq!(channels_from_title("Monologue"), 0);
        assert_eq!(channels_from_title("15.1 kHz"), 0);
    }
}
