//! Tagwright macOS — a native macOS client for Tagwright.
//!
//! The behaviour is specified by the ADRs in `docs/adr/`, shared with the `tagwright`
//! repository. The domain modules here (naming, layout, status, lyrics, channels) are
//! faithful ports of the tagwright logic and are covered by unit tests.

pub mod domain;

pub mod audio;
pub mod pipeline;
pub mod scan;
pub mod settings;
pub mod state;
pub mod store;
pub mod ui;
