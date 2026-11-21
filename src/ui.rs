//! The native AppKit UI (ADR 0094, 0030, 0031, 0086–0088): a top bar, a board and an inspector,
//! built from standard macOS controls through `cacao`.

use std::sync::RwLock;

use cacao::appkit::menu::{Menu, MenuItem};
use cacao::appkit::window::{Window, WindowConfig, WindowDelegate};
use cacao::appkit::{App, AppDelegate};
use cacao::button::Button;
use cacao::color::Color;
use cacao::input::{TextField, TextFieldDelegate};
use cacao::layout::{Layout, LayoutConstraint};
use cacao::listview::{ListView, ListViewDelegate, ListViewRow};
use cacao::notification_center::Dispatcher;
use cacao::text::{Font, Label, LineBreakMode};
use cacao::view::{View, ViewController, ViewDelegate};

use crate::domain::model::{AlbumStatus, AlbumSummary};
use crate::state::{self, Area, Filter, View as BoardView};

/// Messages routed to the UI thread (the app's single source of change).
#[derive(Clone, Debug)]
pub enum Message {
    Rescan,
    Refreshed,
    SelectAlbum(Option<usize>),
    SetArea(Area),
    SetFilter(Filter),
    SetView(BoardView),
    SetSearch(String),
    RunFixes,
    MoveToLibrary,
}

pub fn dispatch(message: Message) {
    App::<AppDelegateImpl, Message>::dispatch_main(message);
}

fn status_color(status: AlbumStatus) -> Color {
    match status {
        AlbumStatus::Needs => Color::SystemRed,
        AlbumStatus::Ready => Color::SystemBlue,
        AlbumStatus::Fixed => Color::SystemGreen,
    }
}

// --- App delegate ---

#[derive(Default)]
pub struct AppDelegateImpl {
    window: RwLock<Option<Window<MainWindow>>>,
}

impl AppDelegateImpl {
    fn open_main(&self) {
        let mut slot = self.window.write().unwrap();
        if slot.is_none() {
            let window = Window::with(WindowConfig::default(), MainWindow::new());
            window.show();
            *slot = Some(window);
        }
    }
}

impl AppDelegate for AppDelegateImpl {
    fn did_finish_launching(&self) {
        App::set_menu(vec![
            Menu::new(
                "",
                vec![
                    MenuItem::About("Tagwright".to_string()),
                    MenuItem::Separator,
                    MenuItem::Services,
                    MenuItem::Separator,
                    MenuItem::Hide,
                    MenuItem::HideOthers,
                    MenuItem::ShowAll,
                    MenuItem::Separator,
                    MenuItem::Quit,
                ],
            ),
            Menu::new("File", vec![MenuItem::CloseWindow]),
            Menu::new(
                "Edit",
                vec![
                    MenuItem::Undo,
                    MenuItem::Redo,
                    MenuItem::Separator,
                    MenuItem::Cut,
                    MenuItem::Copy,
                    MenuItem::Paste,
                    MenuItem::SelectAll,
                ],
            ),
            Menu::new("View", vec![MenuItem::EnterFullScreen]),
            Menu::new(
                "Window",
                vec![
                    MenuItem::Minimize,
                    MenuItem::Zoom,
                    MenuItem::Separator,
                    MenuItem::new("Bring All to Front"),
                ],
            ),
        ]);
        App::activate();
        self.open_main();
    }

    fn should_terminate_after_last_window_closed(&self) -> bool {
        true
    }
}

impl Dispatcher for AppDelegateImpl {
    type Message = Message;

    fn on_ui_message(&self, message: Message) {
        match message {
            Message::Rescan => state::rescan(),
            m => {
                if let Some(window) = self.window.read().unwrap().as_ref()
                    && let Some(delegate) = &window.delegate
                {
                    delegate.on_message(m);
                }
            }
        }
    }
}

// --- Main window ---

pub struct MainWindow {
    content: ViewController<RootView>,
}

impl MainWindow {
    pub fn new() -> Self {
        MainWindow {
            content: ViewController::new(RootView::default()),
        }
    }

    fn on_message(&self, message: Message) {
        if let Some(delegate) = &self.content.view.delegate {
            delegate.on_message(message);
        }
    }
}

impl Default for MainWindow {
    fn default() -> Self {
        Self::new()
    }
}

impl WindowDelegate for MainWindow {
    const NAME: &'static str = "TagwrightMainWindow";

    fn did_load(&mut self, window: Window) {
        window.set_autosave_name("Tagwright");
        window.set_title("Tagwright");
        window.set_minimum_content_size(960., 600.);
        window.set_content_view_controller(&self.content);
    }
}

// --- Root view: top bar + board + inspector ---

pub struct RootView {
    view: Option<View>,

    top_bar: View,
    btn_all: Button,
    btn_needs: Button,
    btn_ready: Button,
    btn_fixed: Button,
    btn_rescan: Button,
    btn_staging: Button,
    btn_library: Button,
    btn_list: Button,
    btn_cards: Button,
    btn_settings: Button,
    search: TextField<SearchDelegate>,

    board: ListView<BoardList>,

    inspector: View,
    insp_title: Label,
    insp_artist: Label,
    insp_status: Label,
    insp_meta: Label,
    insp_steps: Label,
    insp_issues: Label,
    insp_folder: Label,
    insp_hint: Label,
}

impl Default for RootView {
    fn default() -> Self {
        let mut btn_all = Button::new("All albums");
        btn_all.set_action(|_| dispatch(Message::SetFilter(Filter::All)));
        let mut btn_needs = Button::new("Needs input");
        btn_needs.set_action(|_| dispatch(Message::SetFilter(Filter::Needs)));
        let mut btn_ready = Button::new("Incomplete");
        btn_ready.set_action(|_| dispatch(Message::SetFilter(Filter::Ready)));
        let mut btn_fixed = Button::new("Fixed");
        btn_fixed.set_action(|_| dispatch(Message::SetFilter(Filter::Fixed)));

        let mut btn_rescan = Button::new("Rescan");
        btn_rescan.set_action(|_| dispatch(Message::Rescan));
        let mut btn_staging = Button::new("Staging");
        btn_staging.set_action(|_| dispatch(Message::SetArea(Area::Staging)));
        let mut btn_library = Button::new("Library");
        btn_library.set_action(|_| dispatch(Message::SetArea(Area::Library)));
        let mut btn_list = Button::new("List");
        btn_list.set_action(|_| dispatch(Message::SetView(BoardView::List)));
        let mut btn_cards = Button::new("Cards");
        btn_cards.set_action(|_| dispatch(Message::SetView(BoardView::Cards)));
        let mut btn_settings = Button::new("Settings");
        btn_settings.set_action(|_| {
            // TODO: open the Settings window (ADR 0009).
            log::info!("Settings window not yet implemented");
        });

        RootView {
            view: None,
            top_bar: View::new(),
            btn_all,
            btn_needs,
            btn_ready,
            btn_fixed,
            btn_rescan,
            btn_staging,
            btn_library,
            btn_list,
            btn_cards,
            btn_settings,
            search: TextField::with(SearchDelegate),
            board: ListView::with(BoardList::default()),
            inspector: View::new(),
            insp_title: Label::new(),
            insp_artist: Label::new(),
            insp_status: Label::new(),
            insp_meta: Label::new(),
            insp_steps: Label::new(),
            insp_issues: Label::new(),
            insp_folder: Label::new(),
            insp_hint: Label::new(),
        }
    }
}

impl RootView {
    fn on_message(&self, message: Message) {
        match message {
            Message::Refreshed
            | Message::SetArea(_)
            | Message::SetFilter(_)
            | Message::SetView(_)
            | Message::SetSearch(_) => {
                {
                    let mut s = state::global().write().unwrap();
                    match &message {
                        Message::SetArea(a) => {
                            s.area = *a;
                            s.selected = None;
                        }
                        Message::SetFilter(f) => {
                            s.filter = *f;
                            s.selected = None;
                        }
                        Message::SetView(v) => s.view = *v,
                        Message::SetSearch(q) => s.search = q.clone(),
                        _ => {}
                    }
                }
                if let Some(delegate) = &self.board.delegate {
                    delegate.reload();
                }
                self.render_inspector();
            }
            Message::SelectAlbum(row) => {
                {
                    let mut s = state::global().write().unwrap();
                    s.selected = row;
                }
                self.render_inspector();
            }
            Message::RunFixes => {
                log::info!("Run fixes not yet implemented");
            }
            Message::MoveToLibrary => {
                log::info!("Move to library not yet implemented");
            }
            Message::Rescan => {}
        }
        self.refresh_top_bar();
    }

    fn refresh_top_bar(&self) {
        let s = state::global().read().unwrap();
        let current = s.current();
        let count = |f: Filter| current.iter().filter(|a| f.matches(a.status)).count();
        self.btn_all
            .set_text(&format!("All albums ({count})", count = s.current().len()));
        self.btn_needs
            .set_text(&format!("Needs input ({})", count(Filter::Needs)));
        self.btn_ready
            .set_text(&format!("Incomplete ({})", count(Filter::Ready)));
        self.btn_fixed
            .set_text(&format!("Fixed ({})", count(Filter::Fixed)));
        self.btn_staging.set_text_color(if s.area == Area::Staging {
            Color::SystemBlue
        } else {
            Color::SystemGray
        });
        self.btn_library.set_text_color(if s.area == Area::Library {
            Color::SystemBlue
        } else {
            Color::SystemGray
        });
    }

    fn render_inspector(&self) {
        let s = state::global().read().unwrap();
        match s.selected_album() {
            None => {
                self.insp_title.set_text("No album selected");
                self.insp_artist.set_text("");
                self.insp_status.set_text("");
                self.insp_meta.set_text("");
                self.insp_steps.set_text("");
                self.insp_issues.set_text("");
                self.insp_folder.set_text("");
                self.insp_hint
                    .set_text("Select an album in the list to see its details.");
            }
            Some(a) => self.render_album(a),
        }
    }

    fn render_album(&self, a: &AlbumSummary) {
        let title = if a.album.is_empty() {
            a.name.clone()
        } else {
            a.album.clone()
        };
        self.insp_title.set_text(&title);
        self.insp_title.set_font(Font::bold_system(17.));
        self.insp_artist.set_text(&a.artist);
        self.insp_status.set_text(a.status.label());
        self.insp_status.set_text_color(status_color(a.status));

        let mut meta = Vec::new();
        if !a.media.is_empty() {
            meta.push(a.media.clone());
        }
        if !a.edition_name.is_empty() {
            meta.push(a.edition_name.clone());
        }
        if !a.catalog.is_empty() {
            meta.push(a.catalog.clone());
        }
        if !a.year.is_empty() {
            meta.push(a.year.clone());
        }
        if !a.country.is_empty() {
            meta.push(a.country.clone());
        }
        if !a.dr.is_empty() {
            meta.push(format!("DR {dr}", dr = a.dr));
        }
        self.insp_meta.set_text(meta.join(" · "));

        let steps: Vec<String> = a
            .steps
            .iter()
            .map(|s| {
                let mark = if !s.done {
                    "○"
                } else if s.partial {
                    "◐"
                } else {
                    "●"
                };
                format!("{mark} {}", s.step.label())
            })
            .collect();
        self.insp_steps.set_text(steps.join("   "));

        let issues: Vec<String> = a
            .issues
            .iter()
            .map(|i| {
                let mark = match i.level {
                    crate::domain::model::IssueLevel::Error => "✖",
                    crate::domain::model::IssueLevel::Warn => "⚠",
                    crate::domain::model::IssueLevel::Ingest => "◐",
                    crate::domain::model::IssueLevel::Info => "·",
                };
                format!("{mark} {}", i.text)
            })
            .collect();
        self.insp_issues.set_text(issues.join("\n"));
        if !a.issues.is_empty() {
            self.insp_issues.set_text_color(Color::SystemRed);
        }

        let lyrics = a.lyrics;
        self.insp_folder.set_text(format!(
            "{} tracks · {} synced, {} plain lyrics · {} tracks\nCurrent folder: {}\nLibrary: {}",
            a.track_count,
            lyrics.synced,
            lyrics.plain,
            lyrics.missing,
            a.current_folder,
            if a.new_title.is_empty() {
                "Not ready".to_string()
            } else {
                a.new_title.clone()
            },
        ));
        self.insp_hint.set_text("");
    }
}

impl ViewDelegate for RootView {
    const NAME: &'static str = "TagwrightRootView";

    fn did_load(&mut self, view: View) {
        view.add_subview(&self.top_bar);
        view.add_subview(&self.board);
        view.add_subview(&self.inspector);

        self.top_bar.add_subview(&self.btn_all);
        self.top_bar.add_subview(&self.btn_needs);
        self.top_bar.add_subview(&self.btn_ready);
        self.top_bar.add_subview(&self.btn_fixed);
        self.top_bar.add_subview(&self.btn_rescan);
        self.top_bar.add_subview(&self.btn_list);
        self.top_bar.add_subview(&self.btn_cards);
        self.top_bar.add_subview(&self.btn_staging);
        self.top_bar.add_subview(&self.btn_library);
        self.top_bar.add_subview(&self.search);
        self.top_bar.add_subview(&self.btn_settings);

        self.inspector.add_subview(&self.insp_title);
        self.inspector.add_subview(&self.insp_artist);
        self.inspector.add_subview(&self.insp_status);
        self.inspector.add_subview(&self.insp_meta);
        self.inspector.add_subview(&self.insp_steps);
        self.inspector.add_subview(&self.insp_issues);
        self.inspector.add_subview(&self.insp_folder);
        self.inspector.add_subview(&self.insp_hint);

        self.insp_steps.set_max_number_of_lines(0);
        self.insp_issues.set_max_number_of_lines(0);
        self.insp_folder.set_max_number_of_lines(0);
        self.insp_hint.set_max_number_of_lines(0);
        self.insp_hint.set_text_color(Color::SystemGray);

        LayoutConstraint::activate(&[
            // Top bar.
            self.top_bar.top.constraint_equal_to(&view.top),
            self.top_bar.leading.constraint_equal_to(&view.leading),
            self.top_bar.trailing.constraint_equal_to(&view.trailing),
            self.top_bar.height.constraint_equal_to_constant(52.),
            // Board.
            self.board.top.constraint_equal_to(&self.top_bar.bottom),
            self.board.leading.constraint_equal_to(&view.leading),
            self.board.bottom.constraint_equal_to(&view.bottom),
            // Inspector (fixed width, right side).
            self.inspector.top.constraint_equal_to(&self.top_bar.bottom),
            self.inspector.bottom.constraint_equal_to(&view.bottom),
            self.inspector.trailing.constraint_equal_to(&view.trailing),
            self.inspector.width.constraint_equal_to_constant(460.),
            self.board
                .trailing
                .constraint_equal_to(&self.inspector.leading),
            // Top-bar controls (left to right).
            self.btn_all
                .leading
                .constraint_equal_to(&self.top_bar.leading)
                .offset(12.),
            self.btn_all
                .center_y
                .constraint_equal_to(&self.top_bar.center_y),
            self.btn_needs
                .leading
                .constraint_equal_to(&self.btn_all.trailing)
                .offset(8.),
            self.btn_needs
                .center_y
                .constraint_equal_to(&self.top_bar.center_y),
            self.btn_ready
                .leading
                .constraint_equal_to(&self.btn_needs.trailing)
                .offset(8.),
            self.btn_ready
                .center_y
                .constraint_equal_to(&self.top_bar.center_y),
            self.btn_fixed
                .leading
                .constraint_equal_to(&self.btn_ready.trailing)
                .offset(8.),
            self.btn_fixed
                .center_y
                .constraint_equal_to(&self.top_bar.center_y),
            self.btn_rescan
                .leading
                .constraint_equal_to(&self.btn_fixed.trailing)
                .offset(20.),
            self.btn_rescan
                .center_y
                .constraint_equal_to(&self.top_bar.center_y),
            self.btn_list
                .leading
                .constraint_equal_to(&self.btn_rescan.trailing)
                .offset(20.),
            self.btn_list
                .center_y
                .constraint_equal_to(&self.top_bar.center_y),
            self.btn_cards
                .leading
                .constraint_equal_to(&self.btn_list.trailing)
                .offset(4.),
            self.btn_cards
                .center_y
                .constraint_equal_to(&self.top_bar.center_y),
            self.btn_staging
                .leading
                .constraint_equal_to(&self.btn_cards.trailing)
                .offset(20.),
            self.btn_staging
                .center_y
                .constraint_equal_to(&self.top_bar.center_y),
            self.btn_library
                .leading
                .constraint_equal_to(&self.btn_staging.trailing)
                .offset(4.),
            self.btn_library
                .center_y
                .constraint_equal_to(&self.top_bar.center_y),
            self.search
                .leading
                .constraint_equal_to(&self.btn_library.trailing)
                .offset(12.),
            self.search
                .center_y
                .constraint_equal_to(&self.top_bar.center_y),
            self.search.width.constraint_equal_to_constant(160.),
            self.btn_settings
                .leading
                .constraint_equal_to(&self.search.trailing)
                .offset(12.),
            self.btn_settings
                .trailing
                .constraint_equal_to(&self.top_bar.trailing)
                .offset(-12.),
            self.btn_settings
                .center_y
                .constraint_equal_to(&self.top_bar.center_y),
            // Inspector labels.
            self.insp_title
                .top
                .constraint_equal_to(&self.inspector.top)
                .offset(20.),
            self.insp_title
                .leading
                .constraint_equal_to(&self.inspector.leading)
                .offset(20.),
            self.insp_title
                .trailing
                .constraint_equal_to(&self.inspector.trailing)
                .offset(-20.),
            self.insp_artist
                .top
                .constraint_equal_to(&self.insp_title.bottom)
                .offset(6.),
            self.insp_artist
                .leading
                .constraint_equal_to(&self.insp_title.leading),
            self.insp_artist
                .trailing
                .constraint_equal_to(&self.insp_title.trailing),
            self.insp_status
                .top
                .constraint_equal_to(&self.insp_artist.bottom)
                .offset(10.),
            self.insp_status
                .leading
                .constraint_equal_to(&self.insp_title.leading),
            self.insp_meta
                .top
                .constraint_equal_to(&self.insp_status.bottom)
                .offset(8.),
            self.insp_meta
                .leading
                .constraint_equal_to(&self.insp_title.leading),
            self.insp_meta
                .trailing
                .constraint_equal_to(&self.insp_title.trailing),
            self.insp_steps
                .top
                .constraint_equal_to(&self.insp_meta.bottom)
                .offset(14.),
            self.insp_steps
                .leading
                .constraint_equal_to(&self.insp_title.leading),
            self.insp_steps
                .trailing
                .constraint_equal_to(&self.insp_title.trailing),
            self.insp_issues
                .top
                .constraint_equal_to(&self.insp_steps.bottom)
                .offset(14.),
            self.insp_issues
                .leading
                .constraint_equal_to(&self.insp_title.leading),
            self.insp_issues
                .trailing
                .constraint_equal_to(&self.insp_title.trailing),
            self.insp_folder
                .top
                .constraint_equal_to(&self.insp_issues.bottom)
                .offset(14.),
            self.insp_folder
                .leading
                .constraint_equal_to(&self.insp_title.leading),
            self.insp_folder
                .trailing
                .constraint_equal_to(&self.insp_title.trailing),
            self.insp_hint
                .top
                .constraint_equal_to(&self.insp_folder.bottom)
                .offset(14.),
            self.insp_hint
                .leading
                .constraint_equal_to(&self.insp_title.leading),
            self.insp_hint
                .trailing
                .constraint_equal_to(&self.insp_title.trailing),
        ]);

        self.view = Some(view);
        self.render_inspector();
        self.refresh_top_bar();
    }
}

// --- Board list ---

#[derive(Default, Debug)]
pub struct BoardList {
    view: Option<ListView>,
}

impl BoardList {
    fn reload(&self) {
        if let Some(view) = &self.view {
            view.reload();
        }
    }
}

const ALBUM_ROW: &str = "AlbumRowCell";

impl ListViewDelegate for BoardList {
    const NAME: &'static str = "TagwrightBoardList";

    fn did_load(&mut self, view: ListView) {
        view.register(ALBUM_ROW, AlbumRow::default);
        view.set_uses_alternating_backgrounds(true);
        view.set_row_height(36.);
        self.view = Some(view);
    }

    fn number_of_items(&self) -> usize {
        state::global().read().unwrap().current().len()
    }

    fn item_for(&self, row: usize) -> ListViewRow {
        let mut cell = self.view.as_ref().unwrap().dequeue::<AlbumRow>(ALBUM_ROW);
        let (status, artist, album) = {
            let s = state::global().read().unwrap();
            let current = s.current();
            match current.get(row) {
                Some(a) => (a.status, a.artist.clone(), a.album.clone()),
                None => (AlbumStatus::Needs, String::new(), String::new()),
            }
        };
        if let Some(delegate) = &mut cell.delegate {
            delegate.configure(status, &artist, &album);
        }
        cell.into_row()
    }

    fn item_selected(&self, row: Option<usize>) {
        dispatch(Message::SelectAlbum(row));
    }
}

#[derive(Default, Debug)]
pub struct AlbumRow {
    label: Label,
}

impl AlbumRow {
    fn configure(&mut self, status: AlbumStatus, artist: &str, album: &str) {
        let text = if album.is_empty() {
            artist.to_string()
        } else if artist.is_empty() {
            album.to_string()
        } else {
            format!("{artist} — {album}")
        };
        self.label.set_text(&text);
        self.label.set_text_color(status_color(status));
    }
}

impl ViewDelegate for AlbumRow {
    const NAME: &'static str = "TagwrightAlbumRow";

    fn did_load(&mut self, view: View) {
        view.add_subview(&self.label);
        self.label
            .set_line_break_mode(LineBreakMode::TruncateMiddle);
        self.label.set_font(Font::system(13.));
        LayoutConstraint::activate(&[
            self.label
                .leading
                .constraint_equal_to(&view.leading)
                .offset(14.),
            self.label
                .trailing
                .constraint_equal_to(&view.trailing)
                .offset(-14.),
            self.label.center_y.constraint_equal_to(&view.center_y),
        ]);
    }
}

// --- Search field delegate ---

#[derive(Default, Debug)]
pub struct SearchDelegate;

impl TextFieldDelegate for SearchDelegate {
    const NAME: &'static str = "TagwrightSearchField";

    fn did_load(&mut self, view: TextField) {
        view.set_placeholder_text("Search albums, artists, IDs");
    }

    fn text_did_change(&self, value: &str) {
        dispatch(Message::SetSearch(value.to_string()));
    }
}

/// Entry point used by `main.rs`.
pub fn run() {
    let settings = match crate::settings::load() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("tagwright: {e}");
            std::process::exit(2);
        }
    };
    state::init(settings);
    App::<AppDelegateImpl>::new("com.koehntopp.tagwright", AppDelegateImpl::default()).run();
}
