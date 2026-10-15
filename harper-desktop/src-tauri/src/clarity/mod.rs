//! Clarity: suggestions from Apple's on-device model for sentences that are correct but unclear,
//! wordy, or awkward. Added in this fork (taehee-pd/harperSwift); macOS only.
//!
//! Harper's lints come back from `lint_text` at once. Model checks are slow and asynchronous, so
//! `lint_text` only merges results that are already cached and queues the rest for later frames
//! ([`engine::ClarityEngine`]). Clarity lints are filed under [`CLARITY_RULE_NAME`] in the map
//! `lint_text` returns, so they reach the screen through the same Accessibility code as Harper's.

mod cache;
mod engine;
mod issue;
mod provider;
mod scheduler;
mod segment;

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use harper_core::Document;
use harper_core::language_detection::is_doc_likely_english;
use harper_core::linting::{Lint, LintKind};
use harper_core::spell::FstDictionary;

use crate::color::Color;
use crate::lint_kind_color::lint_kind_color;
use engine::ClarityEngine;
use provider::{ClarityProvider, FakeProvider};

/// The name people see for this kind of suggestion. Rename it here.
pub const CLARITY_KIND_NAME: &str = "Clarity";

/// The key Clarity lints are filed under in `lint_text`'s map. Harper rule names never contain
/// "::", so this cannot clash with one.
pub const CLARITY_RULE_NAME: &str = "AppleIntelligence::Clarity";

/// Electric violet. Far from every Harper kind color (see the tests) and at least 3:1 against both
/// light and dark backgrounds.
pub const CLARITY_COLOR: Color = Color {
    r: 0xA3,
    g: 0x19,
    b: 0xFF,
};

/// How long typing must pause before model checks start.
pub const TYPING_PAUSE: Duration = Duration::from_millis(1500);

/// Identifies a sentence by its text, so results survive the sentence moving in the document.
pub type SentenceKey = u64;

/// Where a lint came from. Kept apart from its kind so the UI can always tell rule-based and AI
/// suggestions apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LintSource {
    Harper,
    AppleIntelligence,
}

/// A lint's kind as the desktop app shows it: Harper's kinds, plus Clarity, which harper-core
/// does not know about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DesktopLintKind {
    Harper(LintKind),
    Clarity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LintOrigin {
    pub kind: DesktopLintKind,
    pub source: LintSource,
}

impl LintOrigin {
    /// The origin of a lint filed under `rule_name`.
    pub fn of(rule_name: &str, lint: &Lint) -> Self {
        if is_clarity_rule(rule_name) {
            Self {
                kind: DesktopLintKind::Clarity,
                source: LintSource::AppleIntelligence,
            }
        } else {
            Self {
                kind: DesktopLintKind::Harper(lint.lint_kind),
                source: LintSource::Harper,
            }
        }
    }
}

impl DesktopLintKind {
    pub fn name(self) -> String {
        match self {
            Self::Harper(kind) => kind.to_string(),
            Self::Clarity => CLARITY_KIND_NAME.to_owned(),
        }
    }

    pub fn color(self) -> Color {
        match self {
            Self::Harper(kind) => lint_kind_color(kind),
            Self::Clarity => CLARITY_COLOR,
        }
    }
}

pub fn is_clarity_rule(rule_name: &str) -> bool {
    rule_name == CLARITY_RULE_NAME
}

/// Wraps Harper's `lint_text` so Clarity lints are merged into its result.
///
/// The Apple Intelligence provider arrives in a later change. Until then Clarity stays off unless
/// `HARPER_CLARITY_FAKE` is set, which turns on canned suggestions for trying the pipeline.
pub fn wrap_lint_text(
    harper_lint_text: impl FnMut(&str) -> BTreeMap<String, Vec<Lint>>,
) -> impl FnMut(&str) -> BTreeMap<String, Vec<Lint>> {
    let engine = std::env::var_os("HARPER_CLARITY_FAKE").map(|_| {
        let provider: Box<dyn ClarityProvider> =
            Box::new(FakeProvider::new(Duration::from_millis(400)));
        ClarityEngine::new(provider)
    });

    with_engine(engine, harper_lint_text, Instant::now)
}

fn with_engine<P: ClarityProvider>(
    mut engine: Option<ClarityEngine<P>>,
    mut harper_lint_text: impl FnMut(&str) -> BTreeMap<String, Vec<Lint>>,
    now: impl Fn() -> Instant,
) -> impl FnMut(&str) -> BTreeMap<String, Vec<Lint>> {
    move |text| {
        let mut lints = harper_lint_text(text);

        if let Some(engine) = engine.as_mut() {
            let clarity = engine.lints(text, now(), is_likely_english);
            if !clarity.is_empty() {
                lints.insert(CLARITY_RULE_NAME.to_owned(), clarity);
            }
        }

        lints
    }
}

/// Harper's own language check, with the curated dictionary.
fn is_likely_english(text: &str) -> bool {
    let document = Document::new_markdown_default_curated(text);
    is_doc_likely_english(&document, &FstDictionary::curated())
}

/// FNV-1a. Stable across runs and Rust versions, unlike `DefaultHasher`, so keys can be saved.
pub fn stable_hash(text: &str) -> u64 {
    text.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use super::*;
    use crate::lint_kind_color::LINT_KINDS;

    #[test]
    fn tells_clarity_lints_apart_from_harper_lints() {
        let lint = Lint {
            lint_kind: LintKind::Readability,
            ..Default::default()
        };

        assert_eq!(
            LintOrigin::of(CLARITY_RULE_NAME, &lint),
            LintOrigin {
                kind: DesktopLintKind::Clarity,
                source: LintSource::AppleIntelligence
            }
        );
        assert_eq!(
            LintOrigin::of("SentenceLength", &lint),
            LintOrigin {
                kind: DesktopLintKind::Harper(LintKind::Readability),
                source: LintSource::Harper
            }
        );
        assert_eq!(DesktopLintKind::Clarity.name(), "Clarity");
    }

    /// Perceptual distance in OKLab, where 0.1 is a clearly visible difference.
    fn oklab_distance(a: Color, b: Color) -> f64 {
        fn oklab(color: Color) -> [f64; 3] {
            let linear = |channel: u8| {
                let c = f64::from(channel) / 255.0;
                if c <= 0.04045 {
                    c / 12.92
                } else {
                    ((c + 0.055) / 1.055).powf(2.4)
                }
            };
            let (r, g, b) = (linear(color.r), linear(color.g), linear(color.b));
            let l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b).cbrt();
            let m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b).cbrt();
            let s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b).cbrt();
            [
                0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
            ]
        }
        let (a, b) = (oklab(a), oklab(b));
        a.iter()
            .zip(b)
            .map(|(a, b)| (a - b).powi(2))
            .sum::<f64>()
            .sqrt()
    }

    #[test]
    fn clarity_color_differs_clearly_from_every_harper_kind() {
        for kind in LINT_KINDS.into_iter().chain([LintKind::WordOrder]) {
            let distance = oklab_distance(CLARITY_COLOR, lint_kind_color(kind));
            assert!(distance >= 0.12, "{kind:?} is too close: {distance:.3}");
        }
    }

    #[test]
    fn files_clarity_lints_under_their_own_rule_name() {
        let clock = Rc::new(Cell::new(Instant::now()));
        let engine = ClarityEngine::with_pause(FakeProvider::new(Duration::ZERO), TYPING_PAUSE);
        let harper = |_: &str| BTreeMap::from([("SpellCheck".to_owned(), Vec::new())]);
        let time = clock.clone();
        let mut lint_text = with_engine(Some(engine), harper, move || time.get());
        let text = "The team met in order to discuss the plan.";

        assert!(!lint_text(text).contains_key(CLARITY_RULE_NAME));
        for _ in 0..2 {
            clock.set(clock.get() + TYPING_PAUSE);
            lint_text(text);
        }

        let lints = lint_text(text);
        assert!(lints.contains_key("SpellCheck"));
        assert_eq!(lints[CLARITY_RULE_NAME].len(), 1);
    }

    #[test]
    fn stable_hash_matches_known_fnv_values() {
        assert_eq!(stable_hash(""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(stable_hash("a"), 0xaf63_dc4c_8601_ec8c);
    }
}
