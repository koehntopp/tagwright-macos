//! Shared application state, accessible from the UI thread and background scan threads.

use std::sync::{Arc, OnceLock, RwLock};

use crate::domain::model::{AlbumStatus, AlbumSummary};
use crate::settings::Settings;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Area {
    Staging,
    Library,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Filter {
    All,
    Needs,
    Ready,
    Fixed,
}

impl Filter {
    pub const ALL: [Filter; 4] = [Filter::All, Filter::Needs, Filter::Ready, Filter::Fixed];

    pub fn label(self) -> &'static str {
        match self {
            Filter::All => "All albums",
            Filter::Needs => "Needs input",
            Filter::Ready => "Incomplete",
            Filter::Fixed => "Fixed",
        }
    }

    pub fn matches(self, status: AlbumStatus) -> bool {
        match self {
            Filter::All => true,
            Filter::Needs => status == AlbumStatus::Needs,
            Filter::Ready => status == AlbumStatus::Ready,
            Filter::Fixed => status == AlbumStatus::Fixed,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Sort {
    Newest,
    Title,
    Artist,
    Status,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum View {
    Cards,
    List,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobStatus {
    Idle,
    Running,
    Done,
    Failed,
    Stopped,
}

#[derive(Debug)]
pub struct AppState {
    pub settings: Option<Settings>,
    pub staging: Vec<AlbumSummary>,
    pub library: Vec<AlbumSummary>,
    pub area: Area,
    pub filter: Filter,
    pub sort: Sort,
    pub view: View,
    pub search: String,
    pub selected: Option<usize>,
    pub scanning: bool,
    pub job_status: JobStatus,
    pub job_lines: Vec<String>,
}

impl Default for AppState {
    fn default() -> Self {
        AppState {
            settings: None,
            staging: Vec::new(),
            library: Vec::new(),
            area: Area::Staging,
            filter: Filter::All,
            sort: Sort::Newest,
            view: View::List,
            search: String::new(),
            selected: None,
            scanning: false,
            job_status: JobStatus::Idle,
            job_lines: Vec::new(),
        }
    }
}

impl AppState {
    /// The albums of the current area, filtered and sorted (ADR 0031, 0086).
    pub fn current(&self) -> Vec<&AlbumSummary> {
        let all: &Vec<AlbumSummary> = match self.area {
            Area::Staging => &self.staging,
            Area::Library => &self.library,
        };
        let needle = self.search.trim().to_lowercase();
        let mut out: Vec<&AlbumSummary> = all
            .iter()
            .filter(|a| self.filter.matches(a.status))
            .filter(|a| {
                needle.is_empty()
                    || a.artist.to_lowercase().contains(&needle)
                    || a.album.to_lowercase().contains(&needle)
                    || a.name.to_lowercase().contains(&needle)
                    || a.discogs_id.contains(&needle)
            })
            .collect();
        match self.sort {
            Sort::Newest => out.sort_by_key(|a| std::cmp::Reverse(a.mtime)),
            Sort::Title => out.sort_by_key(|a| a.album.to_lowercase()),
            Sort::Artist => out.sort_by_key(|a| a.artist.to_lowercase()),
            Sort::Status => out.sort_by_key(|a| a.status.label()),
        }
        out
    }

    pub fn selected_album(&self) -> Option<&AlbumSummary> {
        let current = self.current();
        self.selected.and_then(|i| current.get(i).copied())
    }
}

static STATE: OnceLock<Arc<RwLock<AppState>>> = OnceLock::new();

pub fn init(settings: Settings) -> &'static Arc<RwLock<AppState>> {
    STATE.get_or_init(|| {
        let state = AppState {
            settings: Some(settings),
            ..AppState::default()
        };
        Arc::new(RwLock::new(state))
    })
}

pub fn global() -> &'static Arc<RwLock<AppState>> {
    STATE.get().expect("state not initialised")
}

/// Scan both folders in the background, then post a refresh message.
pub fn rescan() {
    let state = global().clone();
    {
        let mut s = state.write().unwrap();
        s.scanning = true;
    }
    std::thread::spawn(move || {
        let (staging, library) = {
            let s = state.read().unwrap();
            let Some(settings) = s.settings.clone() else {
                return;
            };
            let cfg = settings.summary_config();
            let staging = crate::scan::scan(&settings.staging, Some(&settings.staging))
                .iter()
                .map(|a| crate::domain::status::summarize(a, &cfg))
                .collect();
            let library = crate::scan::scan(&settings.library, None)
                .iter()
                .map(|a| crate::domain::status::summarize(a, &cfg))
                .collect();
            (staging, library)
        };
        {
            let mut s = state.write().unwrap();
            s.staging = staging;
            s.library = library;
            s.scanning = false;
        }
        crate::ui::dispatch(crate::ui::Message::Refreshed);
    });
}
