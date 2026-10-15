//! Added in this fork (taehee-pd/harperSwift).
//!
//! Runs inside `lint_text` on every frame. It never waits: it collects and validates finished
//! model results, queues the next sentence when typing has paused, and returns lints for sentences
//! that are already checked.

use std::collections::VecDeque;
use std::ops::Range;
use std::rc::Rc;
use std::time::{Duration, Instant};

use harper_core::linting::Lint;

use super::cache::{self, ClarityCache};
use super::issue::to_lint;
use super::provider::{Availability, ClarityProvider, ClarityRequest};
use super::scheduler::Scheduler;
use super::segment::{Sentence, sentences};
use super::validate::{overlaps_harper, validate};
use super::{TYPING_PAUSE, stable_hash};

/// Lints text with the user's Harper settings, for validating suggestions.
pub type HarperCheck = Box<dyn FnMut(&str) -> Vec<Lint>>;

/// How often to ask the provider whether the model can run.
const AVAILABILITY_INTERVAL: Duration = Duration::from_secs(2);

/// Split texts to remember. Several fields can be read every frame; keeping each one's sentences
/// avoids splitting unchanged text again.
const SEGMENTED_TEXTS: usize = 4;

struct Segmented {
    hash: u64,
    sentences: Rc<[Sentence]>,
    /// Worked out only when a sentence of this text is about to be checked.
    is_english: Option<bool>,
}

pub struct ClarityEngine<P: ClarityProvider> {
    provider: P,
    harper: HarperCheck,
    cache: ClarityCache,
    scheduler: Scheduler,
    segmented: VecDeque<Segmented>,
    availability: Option<(Instant, Availability)>,
}

impl<P: ClarityProvider> ClarityEngine<P> {
    pub fn new(provider: P, harper: HarperCheck) -> Self {
        Self::with_pause(provider, harper, TYPING_PAUSE)
    }

    pub fn with_pause(provider: P, harper: HarperCheck, pause: Duration) -> Self {
        Self {
            provider,
            harper,
            cache: ClarityCache::new(cache::CAPACITY),
            scheduler: Scheduler::new(pause),
            segmented: VecDeque::new(),
            availability: None,
        }
    }

    /// Clarity lints for `text` from results already in the cache, leaving out any that overlap
    /// `harper_spans` (Harper's lints for the same text, in chars). Queues a model request when
    /// typing has paused. `is_english` runs at most once per text, and only when there is something
    /// to check.
    pub fn lints(
        &mut self,
        text: &str,
        now: Instant,
        is_english: impl FnOnce(&str) -> bool,
        harper_spans: &[Range<usize>],
    ) -> Vec<Lint> {
        self.collect_results(now);

        let hash = stable_hash(text);
        let observation = self.scheduler.observe(hash, text, now);
        let sentences = self.sentences(hash, text);
        let availability = self.availability(now);

        if observation.started_typing && availability == Availability::Available {
            self.provider.prewarm();
        }
        if let Some(id) = self.scheduler.take_stale(observation, hash, &sentences) {
            self.provider.cancel(id);
        }
        if availability == Availability::Available && self.scheduler.is_paused(now) {
            self.check_next(hash, text, &sentences, is_english);
        }

        if matches!(availability, Availability::Unavailable(_)) {
            return Vec::new();
        }
        self.merge(&sentences, harper_spans)
    }

    /// Validates and stores finished results. Results for requests that were cancelled or
    /// replaced are dropped.
    fn collect_results(&mut self, now: Instant) {
        for response in self.provider.poll(now) {
            let Some(request) = self.scheduler.finish(response.id) else {
                continue;
            };

            let (issues, _rejected) =
                validate(&request.sentence, response.issues, &mut *self.harper);
            self.cache.insert(request.key, issues);
        }
    }

    fn check_next(
        &mut self,
        hash: u64,
        text: &str,
        sentences: &[Sentence],
        is_english: impl FnOnce(&str) -> bool,
    ) {
        let Some(next) = self
            .scheduler
            .next(sentences, |key| self.cache.contains(key))
        else {
            return;
        };
        if !self.is_english(hash, text, is_english) {
            return;
        }

        let id = self.scheduler.start(next, hash);
        self.provider.submit(ClarityRequest {
            id,
            key: next.key,
            sentence: next.text.clone(),
        });
    }

    fn merge(&mut self, sentences: &[Sentence], harper_spans: &[Range<usize>]) -> Vec<Lint> {
        sentences
            .iter()
            .flat_map(|sentence| {
                self.cache
                    .get(sentence.key)
                    .unwrap_or_default()
                    .iter()
                    .map(|issue| to_lint(sentence, issue))
                    .filter(|lint| {
                        !overlaps_harper(&(lint.span.start..lint.span.end), harper_spans)
                    })
                    .collect::<Vec<_>>()
            })
            .collect()
    }

    fn sentences(&mut self, hash: u64, text: &str) -> Rc<[Sentence]> {
        if let Some(position) = self.segmented.iter().position(|entry| entry.hash == hash) {
            let entry = self
                .segmented
                .remove(position)
                .expect("position is in range");
            let sentences = entry.sentences.clone();
            self.segmented.push_back(entry);
            return sentences;
        }

        let sentences: Rc<[Sentence]> = sentences(text).into();
        self.segmented.push_back(Segmented {
            hash,
            sentences: sentences.clone(),
            is_english: None,
        });
        if self.segmented.len() > SEGMENTED_TEXTS {
            self.segmented.pop_front();
        }
        sentences
    }

    fn is_english(&mut self, hash: u64, text: &str, is_english: impl FnOnce(&str) -> bool) -> bool {
        let Some(entry) = self.segmented.iter_mut().find(|entry| entry.hash == hash) else {
            return is_english(text);
        };
        *entry.is_english.get_or_insert_with(|| is_english(text))
    }

    fn availability(&mut self, now: Instant) -> Availability {
        match self.availability {
            Some((checked, availability))
                if now.duration_since(checked) < AVAILABILITY_INTERVAL =>
            {
                availability
            }
            _ => {
                let availability = self.provider.availability();
                self.availability = Some((now, availability));
                availability
            }
        }
    }

    #[cfg(test)]
    pub fn provider_mut(&mut self) -> &mut P {
        &mut self.provider
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clarity::provider::{FakeProvider, UnavailableReason};

    const PAUSE: Duration = Duration::from_millis(1500);
    const LATENCY: Duration = Duration::from_millis(400);

    struct Harness {
        engine: ClarityEngine<FakeProvider>,
        start: Instant,
    }

    impl Harness {
        fn new() -> Self {
            Self {
                engine: engine(),
                start: Instant::now(),
            }
        }

        /// Lints for `text` read `ms` milliseconds after the start.
        fn read(&mut self, text: &str, ms: u64) -> Vec<String> {
            self.read_with_harper(text, ms, &[])
        }

        /// Like `read`, with Harper lints at `harper` (chars).
        fn read_with_harper(
            &mut self,
            text: &str,
            ms: u64,
            harper: &[Range<usize>],
        ) -> Vec<String> {
            let chars = text.chars().collect::<Vec<_>>();
            self.engine
                .lints(
                    text,
                    self.start + Duration::from_millis(ms),
                    |_| true,
                    harper,
                )
                .into_iter()
                .map(|lint| chars[lint.span.start..lint.span.end].iter().collect())
                .collect()
        }

        fn provider(&mut self) -> &mut FakeProvider {
            self.engine.provider_mut()
        }
    }

    /// An engine whose Harper check finds nothing, so only the text rules of validation apply.
    fn engine() -> ClarityEngine<FakeProvider> {
        ClarityEngine::with_pause(FakeProvider::new(LATENCY), Box::new(|_| Vec::new()), PAUSE)
    }

    const TEXT: &str =
        "We met in order to plan the whole trip. The weather looked fine all week long.";

    #[test]
    fn shows_lints_only_after_a_pause_and_the_models_answer() {
        let mut harness = Harness::new();

        assert!(harness.read(TEXT, 0).is_empty());
        assert!(harness.read(TEXT, 1000).is_empty());
        assert!(harness.provider().submitted.is_empty());

        assert!(harness.read(TEXT, 1600).is_empty());
        assert_eq!(harness.provider().submitted.len(), 1);

        assert_eq!(harness.read(TEXT, 2100), ["in order to"]);
    }

    #[test]
    fn checks_one_sentence_at_a_time_until_all_are_done() {
        let mut harness = Harness::new();
        harness.read(TEXT, 0);
        harness.read(TEXT, 1600);
        harness.read(TEXT, 1700);
        assert_eq!(harness.provider().submitted.len(), 1);

        harness.read(TEXT, 2100);
        assert_eq!(harness.provider().submitted.len(), 2);
        harness.read(TEXT, 2600);
        harness.read(TEXT, 9000);
        assert_eq!(harness.provider().submitted.len(), 2);
    }

    #[test]
    fn editing_a_sentence_drops_its_lint_at_once_and_keeps_the_others() {
        let text = "We met in order to plan the trip. They came in order to help us out.";
        let mut harness = Harness::new();
        harness.read(text, 0);
        harness.read(text, 1600);
        harness.read(text, 2100);
        assert_eq!(harness.read(text, 2600).len(), 2);

        let edited = text.replace("plan the trip", "plan our trip");
        let remaining = harness.engine.lints(
            &edited,
            harness.start + Duration::from_millis(2700),
            |_| true,
            &[],
        );

        assert_eq!(remaining.len(), 1);
        assert!(remaining[0].span.start > edited.find("They").unwrap());
    }

    #[test]
    fn reuses_cached_results_when_text_returns() {
        let mut harness = Harness::new();
        harness.read(TEXT, 0);
        harness.read(TEXT, 1600);
        harness.read(TEXT, 2100);

        harness.read("Something else entirely is typed here now.", 2200);
        assert_eq!(harness.read(TEXT, 2300), ["in order to"]);
    }

    #[test]
    fn cancels_the_request_for_a_sentence_that_was_edited_away() {
        let mut harness = Harness::new();
        harness.read(TEXT, 0);
        harness.read(TEXT, 1600);
        let id = harness.provider().submitted[0].id;

        harness.read(&TEXT.replace("in order to", "to"), 1700);

        assert_eq!(harness.provider().cancelled, [id]);
    }

    #[test]
    fn unavailable_model_means_no_requests_and_no_lints() {
        let mut harness = Harness::new();
        harness.read(TEXT, 0);
        harness.read(TEXT, 1600);
        harness.read(TEXT, 2100);
        assert_eq!(harness.read(TEXT, 2200), ["in order to"]);

        harness.provider().availability =
            Availability::Unavailable(UnavailableReason::AppleIntelligenceNotEnabled);
        let edited = format!("{TEXT} A large number of people came along too.");

        assert!(harness.read(&edited, 5000).is_empty());
        assert!(harness.read(&edited, 9000).is_empty());
        assert_eq!(harness.provider().submitted.len(), 2);
    }

    #[test]
    fn prewarms_when_typing_starts() {
        let mut harness = Harness::new();
        harness.read("We are typing", 0);
        harness.read("We are typing more", 200);
        assert_eq!(harness.provider().prewarms, 1);

        harness.read("We are typing more after a break", 5000);
        assert_eq!(harness.provider().prewarms, 2);
    }

    #[test]
    fn harper_wins_where_lints_overlap_and_clarity_returns_when_harper_is_done() {
        let mut harness = Harness::new();
        harness.read(TEXT, 0);
        harness.read(TEXT, 1600);
        harness.read(TEXT, 2100);
        let order = TEXT.find("order").unwrap();
        let on_order = order..order + 5;
        let elsewhere = 0..2;

        assert!(
            harness
                .read_with_harper(TEXT, 2200, std::slice::from_ref(&on_order))
                .is_empty()
        );
        assert_eq!(
            harness.read_with_harper(TEXT, 2300, std::slice::from_ref(&elsewhere)),
            ["in order to"]
        );
    }

    #[test]
    fn drops_suggestions_that_fail_validation() {
        // The fake flags "in order to" in both sentences, but in the first it appears twice.
        let text =
            "We trained in order to win and in order to grow. We met in order to plan the trip.";
        let mut harness = Harness::new();
        for ms in [0, 1600, 2100, 2600] {
            harness.read(text, ms);
        }

        let lints = harness.engine.lints(
            text,
            harness.start + Duration::from_millis(2700),
            |_| true,
            &[],
        );
        assert_eq!(lints.len(), 1);
        assert!(lints[0].span.start > text.find("We met").unwrap());
    }

    #[test]
    fn skips_text_that_is_not_english() {
        let mut engine = engine();
        let start = Instant::now();
        let mut checks = 0;

        for ms in [0, 1600, 1700] {
            engine.lints(
                TEXT,
                start + Duration::from_millis(ms),
                |_| {
                    checks += 1;
                    false
                },
                &[],
            );
        }

        assert!(engine.provider_mut().submitted.is_empty());
        assert_eq!(checks, 1);
    }
}
