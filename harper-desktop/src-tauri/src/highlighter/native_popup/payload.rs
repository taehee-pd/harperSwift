//! Added in this fork (taehee-pd/harperSwift).
//!
//! JSON sent to Swift. Field names must match `PopupData` in `PopupModel.swift` (snake_case here,
//! camelCase there). `macos-popup/Tests/HarperPopupTests/Fixtures/popup.json` pins the format for
//! both sides.

use harper_core::linting::Suggestion;
use serde::Serialize;

use super::super::render_state::{is_spelling_kind, suggestion_text};
use crate::clarity::{DesktopLintKind, LintOrigin};
use crate::rect::{ActionableLint, Rect};

/// JSON sent with `show` and `update`.
#[derive(Debug, Serialize)]
pub struct PopupPayload<'a> {
    pub id: u64,
    #[serde(flatten)]
    pub content: &'a PopupContent,
    pub anchor: AnchorRect,
}

/// Everything the popup displays for one lint, except its position.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PopupContent {
    kind_name: String,
    /// The underline color; the popup shows it next to the kind name.
    kind_color: RgbColor,
    rule_name: String,
    /// Markdown.
    message: String,
    suggestions: Vec<SuggestionLabel>,
    flagged_text: String,
    can_add_to_dictionary: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
struct RgbColor {
    r: u8,
    g: u8,
    b: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum SuggestionKind {
    Replace,
    /// Insert `label` after the flagged text.
    Insert,
    Remove,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct SuggestionLabel {
    /// Lets the popup show the text as it will read after the change.
    kind: SuggestionKind,
    /// The replacement or inserted text; "Remove" for removals.
    label: String,
    /// Tooltip and VoiceOver label.
    description: String,
}

/// The flagged word in Accessibility coordinates (global, top-left origin, points).
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct AnchorRect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

impl PopupContent {
    pub fn new(lint: &ActionableLint) -> Self {
        let origin = LintOrigin::of(&lint.rule_name, &lint.lint);
        let color = origin.kind.color();
        let source_chars = lint.source_text.chars().collect::<Vec<_>>();
        // Lints may briefly be cached for older, longer text while the user types.
        let flagged_text = lint
            .lint
            .span
            .try_get_content(&source_chars)
            .map(|chars| chars.iter().collect::<String>())
            .unwrap_or_default();

        Self {
            kind_name: origin.kind.name(),
            kind_color: RgbColor {
                r: color.r,
                g: color.g,
                b: color.b,
            },
            rule_name: lint.rule_name.clone(),
            message: lint.lint.message.clone(),
            suggestions: lint
                .lint
                .suggestions
                .iter()
                .map(|suggestion| SuggestionLabel {
                    kind: SuggestionKind::from(suggestion),
                    label: suggestion_text(suggestion),
                    description: suggestion_description(suggestion, &flagged_text),
                })
                .collect(),
            can_add_to_dictionary: matches!(
                origin.kind,
                DesktopLintKind::Harper(kind) if is_spelling_kind(kind)
            ),
            flagged_text,
        }
    }
}

impl From<Rect> for AnchorRect {
    fn from(rect: Rect) -> Self {
        Self {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
        }
    }
}

impl From<&Suggestion> for SuggestionKind {
    fn from(suggestion: &Suggestion) -> Self {
        match suggestion {
            Suggestion::ReplaceWith(_) => Self::Replace,
            Suggestion::InsertAfter(_) => Self::Insert,
            Suggestion::Remove => Self::Remove,
        }
    }
}

fn suggestion_description(suggestion: &Suggestion, flagged_text: &str) -> String {
    match suggestion {
        Suggestion::ReplaceWith(chars) => format!(
            "Replace \u{201c}{flagged_text}\u{201d} with \u{201c}{}\u{201d}",
            chars.iter().collect::<String>()
        ),
        Suggestion::InsertAfter(chars) => format!(
            "Insert \u{201c}{}\u{201d} after \u{201c}{flagged_text}\u{201d}",
            chars.iter().collect::<String>()
        ),
        Suggestion::Remove => format!("Remove \u{201c}{flagged_text}\u{201d}"),
    }
}

#[cfg(test)]
pub mod tests {
    use harper_core::Span;
    use harper_core::linting::{Lint, LintKind};

    use super::*;

    /// "Ths is fine." with "Ths" flagged as a spelling mistake.
    pub fn spelling_lint() -> ActionableLint {
        ActionableLint::new(
            Rect::new(120.0, 340.5, 24.0, 17.0),
            "SpellCheck".to_owned(),
            Lint {
                span: Span::new(0, 3),
                lint_kind: LintKind::Spelling,
                suggestions: vec![
                    Suggestion::ReplaceWith("This".chars().collect()),
                    Suggestion::InsertAfter("e".chars().collect()),
                    Suggestion::Remove,
                ],
                message: "Did you mean `This`?".to_owned(),
                ..Default::default()
            },
            "Ths is fine.".to_owned(),
            |_| {},
        )
    }

    #[test]
    fn describes_the_lint_for_the_popup() {
        let content = PopupContent::new(&spelling_lint());

        assert_eq!(content.kind_name, "Spelling");
        assert_eq!(content.flagged_text, "Ths");
        assert!(content.can_add_to_dictionary);
        assert_eq!(
            content
                .suggestions
                .iter()
                .map(|suggestion| suggestion.label.as_str())
                .collect::<Vec<_>>(),
            ["This", "e", "Remove"]
        );
        assert_eq!(
            content
                .suggestions
                .iter()
                .map(|suggestion| suggestion.kind)
                .collect::<Vec<_>>(),
            [
                SuggestionKind::Replace,
                SuggestionKind::Insert,
                SuggestionKind::Remove
            ]
        );
        assert_eq!(
            content.suggestions[1].description,
            "Insert \u{201c}e\u{201d} after \u{201c}Ths\u{201d}"
        );
    }

    #[test]
    fn tolerates_spans_past_the_end_of_the_text() {
        let mut lint = spelling_lint();
        lint.lint.span = Span::new(10, 40);

        assert_eq!(PopupContent::new(&lint).flagged_text, "");
    }

    #[test]
    fn matches_the_fixture_decoded_by_swift() {
        let lint = spelling_lint();
        let payload = PopupPayload {
            id: 7,
            content: &PopupContent::new(&lint),
            anchor: lint.rect.into(),
        };
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../macos-popup/Tests/HarperPopupTests/Fixtures/popup.json"
        ))
        .unwrap();

        assert_eq!(serde_json::to_value(&payload).unwrap(), fixture);
    }
}
