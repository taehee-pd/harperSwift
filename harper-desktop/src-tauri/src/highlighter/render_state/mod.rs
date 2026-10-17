// Modified in this fork (taehee-pd/harperSwift): exposes popup state and actions to the native
// macOS popup (`native_popup/`), compiles the egui card out on macOS, draws Clarity lints with a
// dashed underline, records Clarity dismissals, and reports the lint the caret moved into.

mod draw_highlight;
mod popup_layout;
mod render_lint_card;

use std::time::Instant;

#[cfg(not(target_os = "macos"))]
use egui_commonmark::CommonMarkCache;
#[cfg(target_os = "macos")]
use harper_core::linting::Lint;
use harper_core::{Document, linting::LintKind};

pub(super) use self::render_lint_card::LintCardAction;
#[cfg(not(target_os = "macos"))]
use self::render_lint_card::render_lint_card;
#[cfg(target_os = "macos")]
pub(super) use self::render_lint_card::{is_spelling_kind, suggestion_text};
use self::{
    draw_highlight::draw_highlight,
    popup_layout::{PopupLayout, approach},
    render_lint_card::{FIRST_ROW_OFFSET, popup_layout_for_lint, row_count, sidebar_target},
};
use super::{AddToDictionary, DisableRule, IgnoreLint, OpenSettings};
use crate::{
    lint_kind_color::lint_kind_color,
    rect::{ActionableLint, Rect},
};

/// A lint marker, popup, or empty overlay region found during cursor hit-testing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HitTarget {
    Lint(usize),
    Popup,
    None,
}

/// Stores highlighter-specific drawing state and renders it into an egui frame.
///
/// `Window` owns the native window and GPU plumbing; `RenderState` owns the content we want to draw
/// into that plumbing. This keeps future highlight rectangles, styling, and animation state out of
/// the platform/rendering infrastructure.
pub struct RenderState {
    /// Last successful accessibility read, retained when a later read fails.
    last_lints: Option<Vec<ActionableLint>>,

    /// Index of the lint whose suggestion popup is currently visible.
    highlighted_lint: Option<usize>,

    /// Index of the suggestion row that the user hovered last in the visible popup.
    shown_suggestion: Option<usize>,

    /// The flyout card's drawn offset from the list card's top, in points.
    current_sidebar_position: f32,

    /// When `render` last ran, used to move the sidebar at a speed that follows real time.
    last_render: Option<Instant>,

    /// Cache for markdown-rendered lint messages so popup redraws do not repeatedly rebuild markdown
    /// resources from scratch.
    #[cfg(not(target_os = "macos"))]
    markdown_cache: CommonMarkCache,

    /// Called when the user dismisses a lint so app-level ignored-lint state can be updated.
    ignore_lint: IgnoreLint,

    /// Called when the user adds a spelling lint's source text to the local dictionary.
    add_to_dictionary: AddToDictionary,

    /// Called when the user disables the rule that produced the selected lint.
    disable_rule: DisableRule,

    open_settings: OpenSettings,
}

impl RenderState {
    /// Creates render state through `set_lints` so initial lint data gets the same stale-popup guard
    /// used by later accessibility refreshes.
    pub fn new(
        rects: Vec<ActionableLint>,
        ignore_lint: IgnoreLint,
        add_to_dictionary: AddToDictionary,
        disable_rule: DisableRule,
        open_settings: OpenSettings,
    ) -> Self {
        let mut state = Self {
            last_lints: None,
            highlighted_lint: None,
            shown_suggestion: None,
            current_sidebar_position: FIRST_ROW_OFFSET,
            last_render: None,
            #[cfg(not(target_os = "macos"))]
            markdown_cache: CommonMarkCache::default(),
            ignore_lint,
            add_to_dictionary,
            disable_rule,
            open_settings,
        };
        state.set_lints(rects);
        state
    }

    /// Saves successful accessibility reads while retaining the previous lints after a failed read.
    ///
    /// Closes the popup when its lint disappeared, and forgets the shown suggestion when the
    /// refreshed lint has fewer rows.
    pub fn set_lints(&mut self, lints: Vec<ActionableLint>) {
        self.last_lints = Some(lints);

        if self
            .highlighted_lint
            .is_some_and(|index| index >= self.lints().len())
        {
            self.close_popup();
        }

        let row_count = self
            .highlighted_lint
            .and_then(|index| self.lints().get(index))
            .map(|positioned_lint| row_count(&positioned_lint.lint));
        self.shown_suggestion = self
            .shown_suggestion
            .filter(|index| row_count.is_some_and(|row_count| *index < row_count));
    }

    fn lints(&self) -> &[ActionableLint] {
        self.last_lints.as_deref().unwrap_or_default()
    }

    /// Updates which lint owns the suggestion popup without exposing render-state internals.
    ///
    /// Window/input code decides what the user interacted with, while `RenderState` owns the popup
    /// selection. Filtering invalid indexes here keeps stale cursor state from selecting a lint that
    /// disappeared after the latest accessibility read.
    ///
    /// Like the Chrome extension, each new selection starts again from the first suggestion row.
    pub fn set_highlighted_lint(&mut self, highlighted_lint: Option<usize>) {
        self.highlighted_lint = highlighted_lint.filter(|index| *index < self.lints().len());
        self.shown_suggestion = None;
        self.current_sidebar_position = FIRST_ROW_OFFSET;
    }

    /// Returns the lint whose popup is open, for the native macOS popup.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub(super) fn highlighted(&self) -> Option<(usize, &ActionableLint)> {
        self.highlighted_lint
            .and_then(|index| self.lints().get(index).map(|lint| (index, lint)))
    }

    /// The lint the caret moved into (index and span), for the native macOS popup.
    #[cfg(target_os = "macos")]
    pub(super) fn caret_lint(&self) -> Option<(usize, harper_core::Span<char>)> {
        self.lints()
            .iter()
            .position(|lint| lint.caret_moved_in)
            .map(|index| (index, self.lints()[index].lint.span))
    }

    /// Centralizes the close behavior so the popup close button only has to clear the selected lint.
    pub fn close_popup(&mut self) {
        self.highlighted_lint = None;
        self.shown_suggestion = None;
        self.current_sidebar_position = FIRST_ROW_OFFSET;
    }

    /// Checks if a given position touches a hit target.
    pub fn hit_target_at_pos(&self, pos: egui::Pos2) -> HitTarget {
        // On macOS the popup is a native panel that receives its own clicks.
        if !cfg!(target_os = "macos")
            && self
                .popup_layout()
                .is_some_and(|layout| layout.contains(pos))
        {
            return HitTarget::Popup;
        }

        self.lints()
            .iter()
            .position(|positioned_lint| {
                rect_bounds(&positioned_lint.rect.with_friendly_padding()).contains(pos)
            })
            .map_or(HitTarget::None, HitTarget::Lint)
    }

    /// Computes popup hit-test bounds from our layout contract instead of waiting for egui to report
    /// rendered bounds, which keeps hit-testing available before the next render pass completes.
    pub fn popup_layout(&self) -> Option<PopupLayout> {
        self.highlighted_lint
            .and_then(|index| self.lints().get(index))
            .map(|positioned_lint| {
                popup_layout_for_lint(
                    &positioned_lint.rect,
                    &positioned_lint.lint,
                    self.current_sidebar_position,
                )
            })
    }

    /// Draws highlights and the active popup from the same state used by hit-testing so visible
    /// regions and clickable regions do not drift apart.
    ///
    /// Each call also moves the sidebar toward its target by the time since the previous call.
    pub fn render(&mut self, ui: &mut egui::Ui) {
        let now = Instant::now();
        let time_since_last_render = self
            .last_render
            .map_or(0.0, |last_render| (now - last_render).as_secs_f32());
        self.last_render = Some(now);

        if let Some(positioned_lint) = self
            .highlighted_lint
            .and_then(|index| self.lints().get(index))
        {
            let target = sidebar_target(&positioned_lint.lint, self.shown_suggestion);
            self.current_sidebar_position = approach(
                self.current_sidebar_position,
                target,
                time_since_last_render,
            );
        }

        for positioned_lint in self.lints() {
            #[cfg(target_os = "macos")]
            if crate::clarity::is_clarity_rule(&positioned_lint.rule_name) {
                super::clarity_underline::draw(ui, rect_bounds(&positioned_lint.rect));
                continue;
            }

            draw_highlight(ui, &positioned_lint.rect, &positioned_lint.lint);
        }

        // On macOS the popup is drawn by the native SwiftUI panel (`native_popup/`).
        #[cfg(not(target_os = "macos"))]
        if let Some(index) = self.highlighted_lint
            && let Some(positioned_lint) = self.lints().get(index)
        {
            let rect = positioned_lint.rect;
            let lint = positioned_lint.lint.clone();
            let source_text = positioned_lint.source_text.clone();

            if let Some(action) = render_lint_card(
                ui,
                &rect,
                &lint,
                &source_text,
                self.shown_suggestion,
                self.current_sidebar_position,
                &mut self.markdown_cache,
            ) {
                self.apply_card_action(index, action);
            }
        }
    }

    /// Records `lint` in `document` as ignored, through the same callback as the Ignore button.
    /// Clarity dismissals pass the lint's sentence as the document.
    #[cfg(target_os = "macos")]
    pub(super) fn ignore_lint_with(&mut self, lint: &Lint, document: &Document) {
        (self.ignore_lint)(lint, document);
    }

    /// Runs a popup action against the lint at `index`. Shared by the egui card and the native
    /// macOS popup so both behave the same.
    pub(super) fn apply_card_action(&mut self, index: usize, action: LintCardAction) {
        match action {
            LintCardAction::Close => self.close_popup(),
            LintCardAction::OpenSettings => {
                (self.open_settings)();
                self.close_popup();
            }
            LintCardAction::HoverSuggestion(suggestion) => {
                self.shown_suggestion = Some(suggestion);
            }
            LintCardAction::ApplySuggestion(suggestion) => {
                if let Some(actionable_lint) = self
                    .last_lints
                    .as_mut()
                    .and_then(|lints| lints.get_mut(index))
                {
                    actionable_lint.apply_suggestion(suggestion);
                }

                self.close_popup();
            }
            LintCardAction::IgnoreLint => {
                if let Some((lint, source_text)) = self.lints().get(index).map(|actionable_lint| {
                    (
                        actionable_lint.lint.clone(),
                        actionable_lint.source_text.clone(),
                    )
                }) {
                    let document = Document::new_markdown_default_curated(&source_text);
                    (self.ignore_lint)(&lint, &document);
                }

                self.close_popup();
            }
            LintCardAction::AddToDictionary => {
                if let Some((lint, source_text)) = self.lints().get(index).map(|actionable_lint| {
                    (
                        actionable_lint.lint.clone(),
                        actionable_lint.source_text.clone(),
                    )
                }) {
                    let document = Document::new_markdown_default_curated(&source_text);
                    let word = lint.get_str(document.get_source());
                    (self.add_to_dictionary)(&word);
                }

                self.close_popup();
            }
            LintCardAction::DisableRule => {
                if let Some(rule_name) = self
                    .lints()
                    .get(index)
                    .map(|actionable_lint| actionable_lint.rule_name.clone())
                {
                    (self.disable_rule)(&rule_name);
                }

                self.close_popup();
            }
        }
    }
}

/// Converts accessibility rectangles into egui rectangles so rendering and hit-testing use the same
/// screen-space geometry.
fn rect_bounds(rect: &Rect) -> egui::Rect {
    egui::Rect::from_min_size(
        egui::pos2(rect.x as f32, rect.y as f32),
        egui::vec2(rect.width as f32, rect.height as f32),
    )
}

fn lint_kind_color32(lint_kind: LintKind) -> egui::Color32 {
    let color = lint_kind_color(lint_kind);

    egui::Color32::from_rgb(color.r, color.g, color.b)
}
