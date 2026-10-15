//! Added in this fork (taehee-pd/harperSwift).
//!
//! Clarity issues: what the model returns, where it sits in its sentence, and the Harper `Lint` it
//! becomes in the document.

use std::ops::Range;

use harper_core::Span;
use harper_core::linting::{Lint, LintKind, Suggestion};

use super::segment::Sentence;

/// One problem the model reported in a sentence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawIssue {
    /// The exact text to replace.
    pub original: String,
    pub replacement: String,
    /// Why the change helps; shown in the popup.
    pub reason: String,
}

/// An issue located in its sentence. Cached per sentence, so it stays valid wherever the sentence
/// moves in the document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SentenceIssue {
    /// Char range in the sentence.
    pub span: Range<usize>,
    pub replacement: String,
    pub reason: String,
}

/// Finds `issue.original` in `sentence`. It must occur exactly once; otherwise there is no telling
/// which occurrence the model meant, and the issue is dropped.
pub fn locate(sentence: &str, issue: RawIssue) -> Option<SentenceIssue> {
    if issue.original.is_empty() {
        return None;
    }

    let mut matches = sentence.match_indices(&issue.original);
    let (byte_start, _) = matches.next()?;
    if matches.next().is_some() {
        return None;
    }

    let start = sentence[..byte_start].chars().count();
    let end = start + issue.original.chars().count();

    Some(SentenceIssue {
        span: start..end,
        replacement: issue.replacement,
        reason: issue.reason,
    })
}

/// The document-level lint for `issue`, shifted from sentence to document positions.
///
/// `lint_kind` is only a placeholder Harper requires; Clarity lints are recognized by the rule
/// name they are filed under ([`super::CLARITY_RULE_NAME`]).
pub fn to_lint(sentence: &Sentence, issue: &SentenceIssue) -> Lint {
    let offset = sentence.span.start;

    Lint {
        span: Span::new(offset + issue.span.start, offset + issue.span.end),
        lint_kind: LintKind::Readability,
        suggestions: vec![Suggestion::ReplaceWith(issue.replacement.chars().collect())],
        message: issue.reason.clone(),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clarity::segment::sentences;

    fn raw(original: &str, replacement: &str) -> RawIssue {
        RawIssue {
            original: original.to_owned(),
            replacement: replacement.to_owned(),
            reason: "Shorter.".to_owned(),
        }
    }

    #[test]
    fn locates_the_original_by_chars_not_bytes() {
        let located = locate(
            "Café owners met in order to vote.",
            raw("in order to", "to"),
        )
        .unwrap();

        assert_eq!(located.span, 16..27);
    }

    #[test]
    fn drops_originals_that_are_missing_ambiguous_or_empty() {
        let sentence = "We need to plan and we need to act soon.";

        assert_eq!(locate(sentence, raw("we must", "we")), None);
        assert_eq!(locate(sentence, raw("need to", "must")), None);
        assert_eq!(locate(sentence, raw("", "x")), None);
        assert!(locate(sentence, raw("We need", "We must")).is_some());
    }

    #[test]
    fn maps_sentence_spans_to_document_positions() {
        let text = "Ünïcode comes first here.\n\nThe team met in order to discuss the plan.";
        let sentence = sentences(text).pop().unwrap();
        let issue = locate(&sentence.text, raw("in order to", "to")).unwrap();
        let lint = to_lint(&sentence, &issue);
        let chars = text.chars().collect::<Vec<_>>();

        assert_eq!(
            chars[lint.span.start..lint.span.end]
                .iter()
                .collect::<String>(),
            "in order to"
        );
        assert_eq!(
            lint.suggestions,
            [Suggestion::ReplaceWith("to".chars().collect())]
        );
    }
}
