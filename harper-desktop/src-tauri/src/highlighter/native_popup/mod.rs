//! Native SwiftUI suggestion popup for macOS. Added in this fork (taehee-pd/harperSwift).
//!
//! `RenderState` stays the owner of popup state (`highlighted_lint`). Every frame,
//! [`NativePopup::sync`] feeds actions reported by Swift into `RenderState::apply_card_action`
//! (the same handler the egui card uses), opens or closes the popup on clicks, then mirrors the
//! highlighted lint into the Swift panel in `harper-desktop/macos-popup`.

mod action;
mod ffi;
mod mouse;
mod payload;

use action::NativeAction;
use mouse::{PressCounter, Presses};
use payload::{AnchorRect, PopupContent, PopupPayload};

use harper_core::linting::Lint;

use super::render_state::{HitTarget, RenderState};
use crate::rect::ActionableLint;

/// What the Swift panel currently displays.
///
/// Keeps the inputs of the popup content rather than the content itself: comparing them every
/// frame allocates nothing, while rebuilding the content would.
#[derive(Debug, PartialEq)]
struct ShownPopup {
    /// Changes whenever the content changes, so actions sent for older content are dropped.
    id: u64,
    index: usize,
    source_text: String,
    lint: Lint,
    rule_name: String,
    anchor: AnchorRect,
}

impl ShownPopup {
    fn new(id: u64, index: usize, lint: &ActionableLint) -> Self {
        Self {
            id,
            index,
            source_text: lint.source_text.clone(),
            lint: lint.lint.clone(),
            rule_name: lint.rule_name.clone(),
            anchor: lint.rect.into(),
        }
    }

    fn payload<'a>(&self, content: &'a PopupContent) -> PopupPayload<'a> {
        PopupPayload {
            id: self.id,
            content,
            anchor: self.anchor,
        }
    }

    /// Whether `lint` would produce the content this popup shows, given the same source text.
    fn same_content(&self, lint: &ActionableLint) -> bool {
        lint.lint == self.lint && lint.rule_name == self.rule_name
    }

    /// Whether `lint` at `index` is still the lint this popup describes.
    fn describes(&self, index: usize, lint: &ActionableLint) -> bool {
        index == self.index && lint.source_text == self.source_text && self.same_content(lint)
    }
}

/// What to do with the Swift panel this frame.
#[derive(Debug, PartialEq)]
enum Step {
    Nothing,
    Hide,
    /// The text under the popup changed, so the user kept typing: close the popup for good.
    CloseAndHide,
    Show(ShownPopup, PopupContent),
    Update(ShownPopup, PopupContent),
}

/// Compares what Swift shows with the lint that should be shown.
fn next_step(
    shown: Option<&ShownPopup>,
    highlighted: Option<(usize, &ActionableLint)>,
    next_id: u64,
) -> Step {
    let Some((index, lint)) = highlighted else {
        return match shown {
            Some(_) => Step::Hide,
            None => Step::Nothing,
        };
    };

    let Some(shown) = shown.filter(|shown| shown.index == index) else {
        return Step::Show(
            ShownPopup::new(next_id, index, lint),
            PopupContent::new(lint),
        );
    };

    if lint.source_text != shown.source_text {
        return Step::CloseAndHide;
    }

    if !shown.same_content(lint) {
        Step::Update(
            ShownPopup::new(next_id, index, lint),
            PopupContent::new(lint),
        )
    } else if AnchorRect::from(lint.rect) != shown.anchor {
        Step::Update(
            ShownPopup::new(shown.id, index, lint),
            PopupContent::new(lint),
        )
    } else {
        Step::Nothing
    }
}

/// Whether the lint's span lies inside its source text. The shared action handlers index the text
/// with the span and would panic otherwise, which can happen while lints are briefly cached for
/// older, longer text during typing.
fn span_fits(lint: &ActionableLint) -> bool {
    lint.lint.span.end <= lint.source_text.chars().count()
}

/// What a mouse press means for the popup.
#[derive(Debug, PartialEq, Eq)]
enum ClickOutcome {
    /// The press landed on the popup itself; its buttons handle it.
    Ignore,
    Select(usize),
    Close,
}

/// Left-clicking an underline opens its popup; any other press outside the popup closes it.
/// Right-clicks never open the popup, so they do not compete with the app's context menu.
fn click_outcome(presses: Presses, on_popup: bool, target: HitTarget) -> ClickOutcome {
    match (on_popup, presses.left, target) {
        (true, _, _) => ClickOutcome::Ignore,
        (false, true, HitTarget::Lint(index)) => ClickOutcome::Select(index),
        (false, _, _) => ClickOutcome::Close,
    }
}

pub struct NativePopup {
    shown: Option<ShownPopup>,
    last_id: u64,
    presses: PressCounter,
}

impl NativePopup {
    pub fn new() -> Self {
        ffi::install_action_handler();

        Self {
            shown: None,
            last_id: 0,
            presses: PressCounter::new(),
        }
    }

    /// `cursor_position` returns the pointer in Accessibility coordinates; it is only called when
    /// a mouse button was pressed since the last frame.
    pub fn sync(
        &mut self,
        render_state: &mut RenderState,
        cursor_position: impl FnOnce() -> Option<egui::Pos2>,
    ) {
        self.apply_actions(render_state);
        self.handle_clicks(render_state, cursor_position);

        match next_step(
            self.shown.as_ref(),
            render_state.highlighted(),
            self.last_id + 1,
        ) {
            Step::Nothing => {}
            Step::Hide => self.hide(),
            Step::CloseAndHide => {
                render_state.close_popup();
                self.hide();
            }
            Step::Show(shown, content) => {
                ffi::show(&shown.payload(&content));
                self.remember(shown);
            }
            Step::Update(shown, content) => {
                ffi::update(&shown.payload(&content));
                self.remember(shown);
            }
        }
    }

    /// Runs actions reported by Swift, dropping any that were meant for content no longer shown.
    fn apply_actions(&self, render_state: &mut RenderState) {
        for raw in ffi::take_actions() {
            let Some(shown) = self.shown.as_ref().filter(|shown| shown.id == raw.popup_id) else {
                continue;
            };
            let Some(action) = NativeAction::from_raw(raw.kind, raw.index) else {
                continue;
            };
            let card_action = render_state
                .highlighted()
                .filter(|(index, lint)| shown.describes(*index, lint))
                .filter(|(_, lint)| action == NativeAction::Close || span_fits(lint))
                .and_then(|(_, lint)| action.card_action(&lint.lint));

            if let Some(card_action) = card_action {
                render_state.apply_card_action(shown.index, card_action);
            }
        }
    }

    fn handle_clicks(
        &mut self,
        render_state: &mut RenderState,
        cursor_position: impl FnOnce() -> Option<egui::Pos2>,
    ) {
        let presses = self.presses.take();

        if !presses.any() {
            return;
        }

        let Some(cursor) = cursor_position() else {
            return;
        };

        match click_outcome(
            presses,
            ffi::contains_point(cursor),
            render_state.hit_target_at_pos(cursor),
        ) {
            ClickOutcome::Ignore => {}
            ClickOutcome::Select(index) => render_state.set_highlighted_lint(Some(index)),
            ClickOutcome::Close => render_state.close_popup(),
        }
    }

    fn remember(&mut self, shown: ShownPopup) {
        self.last_id = self.last_id.max(shown.id);
        self.shown = Some(shown);
    }

    fn hide(&mut self) {
        ffi::hide();
        self.shown = None;
    }
}

#[cfg(test)]
mod tests {
    use super::payload::tests::spelling_lint;
    use super::*;
    use crate::rect::Rect;

    fn shown(id: u64, index: usize, lint: &ActionableLint) -> ShownPopup {
        ShownPopup::new(id, index, lint)
    }

    fn show(id: u64, index: usize, lint: &ActionableLint) -> Step {
        Step::Show(shown(id, index, lint), PopupContent::new(lint))
    }

    fn update(id: u64, index: usize, lint: &ActionableLint) -> Step {
        Step::Update(shown(id, index, lint), PopupContent::new(lint))
    }

    #[test]
    fn does_nothing_without_a_highlighted_lint() {
        assert_eq!(next_step(None, None, 1), Step::Nothing);
    }

    #[test]
    fn shows_a_newly_highlighted_lint_with_a_new_id() {
        let lint = spelling_lint();

        assert_eq!(next_step(None, Some((0, &lint)), 1), show(1, 0, &lint));
    }

    #[test]
    fn shows_again_when_a_different_lint_is_highlighted() {
        let lint = spelling_lint();
        let current = shown(1, 0, &lint);

        assert_eq!(
            next_step(Some(&current), Some((2, &lint)), 2),
            show(2, 2, &lint)
        );
    }

    #[test]
    fn hides_when_the_lint_is_no_longer_highlighted() {
        let lint = spelling_lint();

        assert_eq!(next_step(Some(&shown(1, 0, &lint)), None, 2), Step::Hide);
    }

    #[test]
    fn keeps_still_popups_untouched() {
        let lint = spelling_lint();

        assert_eq!(
            next_step(Some(&shown(1, 0, &lint)), Some((0, &lint)), 2),
            Step::Nothing
        );
    }

    #[test]
    fn moves_with_the_word_and_keeps_the_id() {
        let lint = spelling_lint();
        let current = shown(1, 0, &lint);
        let mut moved = spelling_lint();
        moved.rect = Rect::new(300.0, 500.0, 24.0, 17.0);

        assert_eq!(
            next_step(Some(&current), Some((0, &moved)), 2),
            update(1, 0, &moved)
        );
    }

    #[test]
    fn new_content_gets_a_new_id_so_stale_actions_are_dropped() {
        let lint = spelling_lint();
        let current = shown(1, 0, &lint);
        let mut changed = spelling_lint();
        changed.lint.message = "Another message".to_owned();

        assert_eq!(
            next_step(Some(&current), Some((0, &changed)), 2),
            update(2, 0, &changed)
        );
    }

    #[test]
    fn closes_when_the_user_keeps_typing() {
        let lint = spelling_lint();
        let current = shown(1, 0, &lint);
        let mut typed = spelling_lint();
        typed.source_text = "Ths is fine. More".to_owned();

        assert_eq!(
            next_step(Some(&current), Some((0, &typed)), 2),
            Step::CloseAndHide
        );
    }

    const LEFT: Presses = Presses {
        left: true,
        right: false,
    };
    const RIGHT: Presses = Presses {
        left: false,
        right: true,
    };

    #[test]
    fn left_click_on_an_underline_selects_it() {
        assert_eq!(
            click_outcome(LEFT, false, HitTarget::Lint(3)),
            ClickOutcome::Select(3)
        );
    }

    #[test]
    fn clicks_elsewhere_close_the_popup() {
        assert_eq!(
            click_outcome(LEFT, false, HitTarget::None),
            ClickOutcome::Close
        );
        assert_eq!(
            click_outcome(RIGHT, false, HitTarget::None),
            ClickOutcome::Close
        );
    }

    #[test]
    fn right_click_on_an_underline_closes_instead_of_opening() {
        assert_eq!(
            click_outcome(RIGHT, false, HitTarget::Lint(3)),
            ClickOutcome::Close
        );
    }

    #[test]
    fn clicks_on_the_popup_are_left_to_its_buttons() {
        assert_eq!(
            click_outcome(LEFT, true, HitTarget::Lint(3)),
            ClickOutcome::Ignore
        );
        assert_eq!(
            click_outcome(RIGHT, true, HitTarget::None),
            ClickOutcome::Ignore
        );
    }

    #[test]
    fn only_acts_on_lints_whose_span_fits_the_text() {
        let mut lint = spelling_lint();
        assert!(span_fits(&lint));

        lint.source_text = "Th".to_owned();
        assert!(!span_fits(&lint));
    }

    #[test]
    fn recognizes_the_lint_it_describes() {
        let lint = spelling_lint();
        let current = shown(1, 0, &lint);
        let mut changed = spelling_lint();
        changed.lint.message = "Another message".to_owned();

        assert!(current.describes(0, &lint));
        assert!(!current.describes(1, &lint));
        assert!(!current.describes(0, &changed));
    }
}
