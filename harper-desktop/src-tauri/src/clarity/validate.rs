//! Added in this fork (taehee-pd/harperSwift).
//!
//! Checks each model suggestion before it can be shown. A suggestion that fails any check is
//! dropped. Sentence-level checks run once, when the model answers; the overlap check against
//! Harper's lints runs on every frame, because Harper's lints change as the user edits elsewhere.

use std::collections::HashMap;
use std::ops::Range;

use harper_core::linting::Lint;

use super::issue::{RawIssue, SentenceIssue, locate};

/// Why a suggestion was dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rejection {
    /// `original` is missing from the sentence or appears more than once.
    NotExactlyOnce,
    /// `replacement` is the same as `original`.
    Unchanged,
    /// Applying it makes Harper report something new in the sentence.
    AddsHarperLints,
    /// It overlaps an earlier suggestion for the same sentence; the two could not both apply.
    OverlapsOtherSuggestion,
}

/// Validates the model's answer for `sentence`. `harper` lints a piece of text with the user's
/// Harper settings; it runs only when there is something to compare.
pub fn validate(
    sentence: &str,
    issues: Vec<RawIssue>,
    harper: &mut dyn FnMut(&str) -> Vec<Lint>,
) -> (Vec<SentenceIssue>, Vec<Rejection>) {
    let mut accepted: Vec<SentenceIssue> = Vec::new();
    let mut rejected = Vec::new();
    let mut baseline = None;

    for issue in issues {
        if issue.replacement.trim() == issue.original.trim() {
            rejected.push(Rejection::Unchanged);
            continue;
        }
        let Some(located) = locate(sentence, issue) else {
            rejected.push(Rejection::NotExactlyOnce);
            continue;
        };
        if accepted
            .iter()
            .any(|other| ranges_overlap(&other.span, &located.span))
        {
            rejected.push(Rejection::OverlapsOtherSuggestion);
            continue;
        }

        let before = baseline.get_or_insert_with(|| lint_hashes(harper(sentence)));
        let after = lint_hashes(harper(&apply(sentence, &located)));
        if adds_lints(before, &after) {
            rejected.push(Rejection::AddsHarperLints);
            continue;
        }

        accepted.push(located);
    }

    (accepted, rejected)
}

/// Whether a Clarity lint at `span` (document chars) overlaps any of Harper's lints. Harper wins.
pub fn overlaps_harper(span: &Range<usize>, harper_spans: &[Range<usize>]) -> bool {
    harper_spans
        .iter()
        .any(|harper| ranges_overlap(span, harper))
}

/// Touching ranges do not overlap. An empty range overlaps a range it falls strictly inside.
fn ranges_overlap(a: &Range<usize>, b: &Range<usize>) -> bool {
    a.start < b.end && b.start < a.end
}

/// `sentence` with the suggestion applied.
fn apply(sentence: &str, issue: &SentenceIssue) -> String {
    let chars = sentence.chars().collect::<Vec<_>>();

    chars[..issue.span.start]
        .iter()
        .copied()
        .chain(issue.replacement.chars())
        .chain(chars[issue.span.end..].iter().copied())
        .collect()
}

/// Lints identified without their position, which shifts when the sentence changes, counted so
/// a lint that appears twice is compared twice.
fn lint_hashes(lints: Vec<Lint>) -> HashMap<u64, usize> {
    let mut counts = HashMap::new();
    for lint in lints {
        *counts.entry(lint.spanless_hash()).or_default() += 1;
    }
    counts
}

/// Whether `after` holds any lint `before` did not.
fn adds_lints(before: &HashMap<u64, usize>, after: &HashMap<u64, usize>) -> bool {
    after
        .iter()
        .any(|(hash, count)| before.get(hash).copied().unwrap_or(0) < *count)
}

#[cfg(test)]
mod tests {
    use harper_core::linting::{LintGroup, Linter};
    use harper_core::spell::FstDictionary;
    use harper_core::{Dialect, Document};

    use super::*;

    fn raw(original: &str, replacement: &str) -> RawIssue {
        RawIssue {
            original: original.to_owned(),
            replacement: replacement.to_owned(),
            reason: "Clearer.".to_owned(),
        }
    }

    /// Harper with its curated rules, like a fresh install.
    fn harper() -> impl FnMut(&str) -> Vec<Lint> {
        let mut linter = LintGroup::new_curated(FstDictionary::curated(), Dialect::American);
        move |text| linter.lint(&Document::new_markdown_default_curated(text))
    }

    #[test]
    fn accepts_a_clean_minimal_rewrite() {
        let sentence = "We met in order to discuss the budget for next year.";
        let (accepted, rejected) =
            validate(sentence, vec![raw("in order to", "to")], &mut harper());

        assert_eq!(accepted.len(), 1);
        assert_eq!(accepted[0].span, 7..18);
        assert!(rejected.is_empty());
    }

    #[test]
    fn rejects_originals_not_found_exactly_once() {
        let sentence = "We need to plan and we need to act soon.";
        let (accepted, rejected) = validate(
            sentence,
            vec![raw("need to", "must"), raw("we have to", "we must")],
            &mut harper(),
        );

        assert!(accepted.is_empty());
        assert_eq!(
            rejected,
            [Rejection::NotExactlyOnce, Rejection::NotExactlyOnce]
        );
    }

    #[test]
    fn rejects_unchanged_replacements() {
        let (accepted, rejected) = validate(
            "We met in order to discuss the budget.",
            vec![raw("in order to", "in order to"), raw("budget", " budget ")],
            &mut harper(),
        );

        assert!(accepted.is_empty());
        assert_eq!(rejected, [Rejection::Unchanged, Rejection::Unchanged]);
    }

    #[test]
    fn rejects_rewrites_that_add_harper_lints() {
        // Seen from the model: "when you open" -> "when you open a" repeats "a".
        let sentence = "The app crashes when you open a large file.";
        let (accepted, rejected) = validate(
            sentence,
            vec![raw("when you open", "when you open a")],
            &mut harper(),
        );

        assert!(accepted.is_empty());
        assert_eq!(rejected, [Rejection::AddsHarperLints]);
    }

    #[test]
    fn existing_harper_lints_do_not_block_a_rewrite() {
        // "Ths" is misspelled before and after; only new lints count.
        let sentence = "Ths team met in order to discuss the budget.";
        let (accepted, _) = validate(sentence, vec![raw("in order to", "to")], &mut harper());

        assert_eq!(accepted.len(), 1);
    }

    #[test]
    fn runs_harper_only_when_needed() {
        let calls = std::cell::Cell::new(0);
        let mut counting = |_: &str| {
            calls.set(calls.get() + 1);
            Vec::new()
        };

        validate(
            "Short sentence here for the test.",
            vec![raw("missing", "x")],
            &mut counting,
        );
        assert_eq!(calls.get(), 0);

        validate(
            "We met in order to plan it and in order to act.",
            vec![raw("We met", "We gathered"), raw("plan it", "plan")],
            &mut counting,
        );
        // One baseline run for the sentence, then one per suggestion.
        assert_eq!(calls.get(), 3);
    }

    #[test]
    fn keeps_only_the_first_of_two_overlapping_suggestions() {
        let sentence = "There are many people who believe that remote work helps.";
        let (accepted, rejected) = validate(
            sentence,
            vec![
                raw("There are many people who believe", "Many people believe"),
                raw("people who believe that", "people believe"),
            ],
            &mut harper(),
        );

        assert_eq!(accepted.len(), 1);
        assert_eq!(rejected, [Rejection::OverlapsOtherSuggestion]);
    }

    #[test]
    fn harper_wins_on_overlap_but_touching_is_fine() {
        let harper_span = 10..15;
        let harper_spans = std::slice::from_ref(&harper_span);

        assert!(overlaps_harper(&(12..20), harper_spans));
        assert!(overlaps_harper(&(5..11), harper_spans));
        assert!(overlaps_harper(&(0..30), harper_spans));
        assert!(!overlaps_harper(&(15..20), harper_spans));
        assert!(!overlaps_harper(&(0..10), harper_spans));
    }

    #[test]
    fn applies_replacements_by_chars() {
        let issue = SentenceIssue {
            span: 5..16,
            replacement: "to".to_owned(),
            reason: String::new(),
        };

        assert_eq!(apply("Café in order to vote.", &issue), "Café to vote.");
    }
}
