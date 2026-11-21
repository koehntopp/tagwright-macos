//! Settings: folders from the environment, the rest from `DATA_DIR/settings.json` (ADR 0045, 0009).

use std::path::{Path, PathBuf};

use crate::domain::layout::Template;
use crate::domain::model::SummaryConfig;

#[derive(Debug, Clone)]
pub struct Settings {
    pub staging: PathBuf,
    pub library: PathBuf,
    pub data_dir: PathBuf,
    pub min_cover: u32,
    pub max_cover: u32,
    pub discogs_api_key: String,
    pub delete_staging_after_move: bool,
    pub template: Template,
    pub apply: bool,
    pub cooldown: u32,
    pub interval: u32,
    pub sweep_hours: u32,
}

impl Settings {
    pub fn summary_config(&self) -> SummaryConfig {
        SummaryConfig {
            min_cover: self.min_cover,
            max_cover: self.max_cover,
        }
    }
}

fn env_path(name: &str) -> anyhow::Result<PathBuf> {
    let value = std::env::var(name).map_err(|_| {
        anyhow::anyhow!(
            "{name} is not set; staging, library and data folders have no default (ADR 0055)"
        )
    })?;
    let path = PathBuf::from(shellexpand(&value));
    if !path.is_absolute() {
        anyhow::bail!("{name} must be an absolute path (ADR 0055): {value}");
    }
    Ok(path)
}

fn shellexpand(value: &str) -> String {
    if let Some(rest) = value.strip_prefix("~/")
        && let Some(home) = std::env::var_os("HOME")
    {
        return Path::new(&home).join(rest).to_string_lossy().into_owned();
    }
    value.to_string()
}

#[derive(serde::Deserialize, Default)]
struct RawSettings {
    #[serde(default)]
    min_cover: Option<u32>,
    #[serde(default)]
    max_cover: Option<u32>,
    #[serde(default)]
    discogs_api_key: Option<String>,
    #[serde(default)]
    delete_staging_after_move: Option<bool>,
    #[serde(default)]
    library: Option<RawLibrary>,
}

#[derive(serde::Deserialize, Default)]
struct RawLibrary {
    #[serde(default)]
    apply: Option<bool>,
    #[serde(default)]
    cooldown: Option<u32>,
    #[serde(default)]
    interval: Option<u32>,
    #[serde(default)]
    sweep_hours: Option<u32>,
    #[serde(default)]
    template: Option<Template>,
}

pub fn load() -> anyhow::Result<Settings> {
    let staging = env_path("STAGING_FOLDER")?;
    let library = env_path("LIBRARY_FOLDER")?;
    let data_dir = env_path("DATA_DIR")?;

    let settings_file = data_dir.join("settings.json");
    let raw: RawSettings = if settings_file.is_file() {
        serde_json::from_str(&std::fs::read_to_string(&settings_file)?).unwrap_or_default()
    } else {
        RawSettings::default()
    };

    let lib = raw.library.unwrap_or_default();
    Ok(Settings {
        staging,
        library,
        data_dir,
        min_cover: raw.min_cover.unwrap_or(1400),
        max_cover: raw.max_cover.unwrap_or(1500),
        discogs_api_key: raw.discogs_api_key.unwrap_or_default(),
        delete_staging_after_move: raw.delete_staging_after_move.unwrap_or(false),
        template: lib.template.unwrap_or_default(),
        apply: lib.apply.unwrap_or(true),
        cooldown: lib.cooldown.unwrap_or(60),
        interval: lib.interval.unwrap_or(120),
        sweep_hours: lib.sweep_hours.unwrap_or(24),
    })
}

/// Write settings back to `settings.json` (used by the Settings dialog). API keys are written here
/// only (ADR 0007).
pub fn save(settings: &Settings) -> anyhow::Result<()> {
    std::fs::create_dir_all(&settings.data_dir)?;
    #[derive(serde::Serialize)]
    struct Out {
        min_cover: u32,
        max_cover: u32,
        discogs_api_key: String,
        delete_staging_after_move: bool,
        library: OutLibrary,
    }
    #[derive(serde::Serialize)]
    struct OutLibrary {
        apply: bool,
        cooldown: u32,
        interval: u32,
        sweep_hours: u32,
        template: Template,
    }
    let out = Out {
        min_cover: settings.min_cover,
        max_cover: settings.max_cover,
        discogs_api_key: settings.discogs_api_key.clone(),
        delete_staging_after_move: settings.delete_staging_after_move,
        library: OutLibrary {
            apply: settings.apply,
            cooldown: settings.cooldown,
            interval: settings.interval,
            sweep_hours: settings.sweep_hours,
            template: settings.template.clone(),
        },
    };
    let json = serde_json::to_string_pretty(&out)?;
    std::fs::write(settings.data_dir.join("settings.json"), json)?;
    Ok(())
}
