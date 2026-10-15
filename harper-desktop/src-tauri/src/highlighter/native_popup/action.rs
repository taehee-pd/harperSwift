//! Added in this fork (taehee-pd/harperSwift).
//!
//! Maps actions reported by the Swift popup onto the existing [`LintCardAction`] handling.

use harper_core::linting::Lint;

use super::super::render_state::{LintCardAction, is_spelling_kind};

/// One user action from the native popup.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NativeAction {
    Close,
    ApplySuggestion(usize),
    IgnoreLint,
    AddToDictionary,
    DisableRule,
}

impl NativeAction {
    /// Decodes the wire format shared with `PopupAction.raw` in `PopupModel.swift`.
    pub fn from_raw(kind: u32, index: i64) -> Option<Self> {
        match kind {
            0 => Some(Self::Close),
            1 => usize::try_from(index).ok().map(Self::ApplySuggestion),
            2 => Some(Self::IgnoreLint),
            3 => Some(Self::AddToDictionary),
            4 => Some(Self::DisableRule),
            _ => None,
        }
    }

    /// Resolves the action against the lint the popup was showing. Returns `None` when the action
    /// does not apply to that lint, such as a suggestion index that no longer exists.
    pub fn card_action(self, lint: &Lint) -> Option<LintCardAction> {
        match self {
            Self::Close => Some(LintCardAction::Close),
            Self::ApplySuggestion(index) => lint
                .suggestions
                .get(index)
                .cloned()
                .map(LintCardAction::ApplySuggestion),
            Self::IgnoreLint => Some(LintCardAction::IgnoreLint),
            Self::AddToDictionary => {
                is_spelling_kind(lint.lint_kind).then_some(LintCardAction::AddToDictionary)
            }
            Self::DisableRule => Some(LintCardAction::DisableRule),
        }
    }
}

#[cfg(test)]
mod tests {
    use harper_core::linting::{LintKind, Suggestion};

    use super::*;

    fn lint(lint_kind: LintKind) -> Lint {
        Lint {
            lint_kind,
            suggestions: vec![
                Suggestion::ReplaceWith("first".chars().collect()),
                Suggestion::Remove,
            ],
            ..Default::default()
        }
    }

    #[test]
    fn decodes_every_action_kind() {
        assert_eq!(NativeAction::from_raw(0, -1), Some(NativeAction::Close));
        assert_eq!(
            NativeAction::from_raw(1, 2),
            Some(NativeAction::ApplySuggestion(2))
        );
        assert_eq!(
            NativeAction::from_raw(2, -1),
            Some(NativeAction::IgnoreLint)
        );
        assert_eq!(
            NativeAction::from_raw(3, -1),
            Some(NativeAction::AddToDictionary)
        );
        assert_eq!(
            NativeAction::from_raw(4, -1),
            Some(NativeAction::DisableRule)
        );
    }

    #[test]
    fn rejects_unknown_kinds_and_negative_suggestion_indexes() {
        assert_eq!(NativeAction::from_raw(5, -1), None);
        assert_eq!(NativeAction::from_raw(u32::MAX, 0), None);
        assert_eq!(NativeAction::from_raw(1, -1), None);
    }

    #[test]
    fn apply_suggestion_picks_the_suggestion_at_the_index() {
        let lint = lint(LintKind::Spelling);

        assert!(matches!(
            NativeAction::ApplySuggestion(0).card_action(&lint),
            Some(LintCardAction::ApplySuggestion(suggestion)) if suggestion == lint.suggestions[0]
        ));
        assert!(matches!(
            NativeAction::ApplySuggestion(1).card_action(&lint),
            Some(LintCardAction::ApplySuggestion(Suggestion::Remove))
        ));
        assert!(
            NativeAction::ApplySuggestion(2)
                .card_action(&lint)
                .is_none()
        );
    }

    #[test]
    fn maps_simple_actions_one_to_one() {
        let lint = lint(LintKind::Grammar);

        assert!(matches!(
            NativeAction::Close.card_action(&lint),
            Some(LintCardAction::Close)
        ));
        assert!(matches!(
            NativeAction::IgnoreLint.card_action(&lint),
            Some(LintCardAction::IgnoreLint)
        ));
        assert!(matches!(
            NativeAction::DisableRule.card_action(&lint),
            Some(LintCardAction::DisableRule)
        ));
    }

    #[test]
    fn add_to_dictionary_only_applies_to_spelling_kinds() {
        assert!(matches!(
            NativeAction::AddToDictionary.card_action(&lint(LintKind::Spelling)),
            Some(LintCardAction::AddToDictionary)
        ));
        assert!(matches!(
            NativeAction::AddToDictionary.card_action(&lint(LintKind::Typo)),
            Some(LintCardAction::AddToDictionary)
        ));
        assert!(
            NativeAction::AddToDictionary
                .card_action(&lint(LintKind::Grammar))
                .is_none()
        );
    }
}
