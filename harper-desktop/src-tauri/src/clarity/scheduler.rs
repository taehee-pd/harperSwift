//! Added in this fork (taehee-pd/harperSwift).
//!
//! Decides when Clarity checks run and which sentence goes next. Checks wait for a pause in typing,
//! one request runs at a time, and the sentence being edited goes first.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use super::SentenceKey;
use super::provider::RequestId;
use super::segment::Sentence;

/// How many distinct texts count as "already seen". Several text fields can be read every frame;
/// each stays recognized as long as it keeps being read.
const RECENT_TEXTS: usize = 8;

/// The request being processed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InFlight {
    pub id: RequestId,
    pub key: SentenceKey,
    pub sentence: String,
    /// Hash of the latest text that contains the sentence.
    source: u64,
}

/// What changed when a text was read.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Observation {
    /// The text was not seen recently: the user typed, or focus moved to another field.
    pub changed: bool,
    /// The first change after a pause; a good moment to load the model.
    pub started_typing: bool,
    /// Hash of the text this one is an edit of.
    replaced: Option<u64>,
}

pub struct Scheduler {
    pause: Duration,
    last_change: Option<Instant>,
    /// Hashes of recently read texts, least recently read first.
    recent: VecDeque<u64>,
    /// The last text that changed, to locate the next edit.
    previous: Option<(u64, Vec<char>)>,
    /// Where the last edit happened, in chars. Stands in for the text cursor, which would take
    /// another Accessibility read to get.
    edit_offset: Option<usize>,
    in_flight: Option<InFlight>,
    next_id: RequestId,
}

impl Scheduler {
    pub fn new(pause: Duration) -> Self {
        Self {
            pause,
            last_change: None,
            recent: VecDeque::new(),
            previous: None,
            edit_offset: None,
            in_flight: None,
            next_id: 1,
        }
    }

    /// Records that `text` (hashed as `hash`) was read at `now`.
    pub fn observe(&mut self, hash: u64, text: &str, now: Instant) -> Observation {
        if let Some(position) = self.recent.iter().position(|seen| *seen == hash) {
            self.recent.remove(position);
            self.recent.push_back(hash);
            return Observation::default();
        }

        let started_typing = self.is_paused(now);
        let chars = text.chars().collect::<Vec<_>>();
        // Only an edit of the previous text says where the cursor is; reading another field
        // does not.
        let edit = self
            .previous
            .as_ref()
            .filter(|(_, previous)| is_edit(previous, &chars));
        let replaced = edit.map(|(hash, _)| *hash);
        self.edit_offset = edit.map(|(_, previous)| common_prefix_len(previous, &chars));
        self.previous = Some((hash, chars));
        self.last_change = Some(now);

        self.recent.push_back(hash);
        if self.recent.len() > RECENT_TEXTS {
            self.recent.pop_front();
        }

        Observation {
            changed: true,
            started_typing,
            replaced,
        }
    }

    /// Whether typing has paused long enough to start checks.
    pub fn is_paused(&self, now: Instant) -> bool {
        self.last_change
            .is_none_or(|last_change| now.duration_since(last_change) >= self.pause)
    }

    #[cfg(test)]
    pub fn in_flight(&self) -> Option<&InFlight> {
        self.in_flight.as_ref()
    }

    /// Marks `sentence` as being checked, from the text hashed as `source`.
    pub fn start(&mut self, sentence: &Sentence, source: u64) -> RequestId {
        let id = self.next_id;
        self.next_id += 1;
        self.in_flight = Some(InFlight {
            id,
            key: sentence.key,
            sentence: sentence.text.clone(),
            source,
        });
        id
    }

    /// Ends the request `id`, returning it if it was still current.
    pub fn finish(&mut self, id: RequestId) -> Option<InFlight> {
        self.in_flight.take_if(|in_flight| in_flight.id == id)
    }

    /// After an edit, ends the request whose sentence the edit removed and returns its id so the
    /// provider can cancel it. Requests from other text fields are left alone.
    pub fn take_stale(
        &mut self,
        observation: Observation,
        hash: u64,
        sentences: &[Sentence],
    ) -> Option<RequestId> {
        let in_flight = self.in_flight.as_mut()?;
        if !observation.changed || observation.replaced != Some(in_flight.source) {
            return None;
        }

        if sentences
            .iter()
            .any(|sentence| sentence.key == in_flight.key)
        {
            in_flight.source = hash;
            return None;
        }

        self.in_flight.take().map(|in_flight| in_flight.id)
    }

    /// The next sentence to check: the one being edited, then the rest of its paragraph, then the
    /// nearest other paragraphs. Nothing while a request is running.
    pub fn next<'a>(
        &self,
        sentences: &'a [Sentence],
        is_checked: impl Fn(SentenceKey) -> bool,
    ) -> Option<&'a Sentence> {
        if self.in_flight.is_some() {
            return None;
        }

        let cursor = self
            .edit_offset
            .and_then(|offset| cursor_sentence(sentences, offset));

        sentences
            .iter()
            .enumerate()
            .filter(|(_, sentence)| !is_checked(sentence.key))
            .min_by_key(|(index, sentence)| {
                let Some(cursor) = cursor else {
                    return (0, 0, *index);
                };
                let cursor_paragraph = sentences[cursor].paragraph;
                let rank = if *index == cursor {
                    0
                } else if sentence.paragraph == cursor_paragraph {
                    1
                } else {
                    2
                };
                (rank, sentence.paragraph.abs_diff(cursor_paragraph), *index)
            })
            .map(|(_, sentence)| sentence)
    }
}

/// The sentence at `offset`, or the nearest one.
fn cursor_sentence(sentences: &[Sentence], offset: usize) -> Option<usize> {
    sentences
        .iter()
        .enumerate()
        .min_by_key(|(_, sentence)| {
            if sentence.span.contains(&offset) || sentence.span.end == offset {
                0
            } else if offset < sentence.span.start {
                sentence.span.start - offset
            } else {
                offset - sentence.span.end
            }
        })
        .map(|(index, _)| index)
}

fn common_prefix_len(a: &[char], b: &[char]) -> usize {
    a.iter().zip(b).take_while(|(a, b)| a == b).count()
}

/// Whether `new` looks like an edit of `old` rather than different text: the unchanged start and
/// end cover at least half of the shorter one.
fn is_edit(old: &[char], new: &[char]) -> bool {
    let prefix = common_prefix_len(old, new);
    let suffix = old[prefix..]
        .iter()
        .rev()
        .zip(new[prefix..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();

    (prefix + suffix) * 2 >= old.len().min(new.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clarity::segment::sentences;
    use crate::clarity::stable_hash;

    const PAUSE: Duration = Duration::from_millis(1500);

    fn observe(scheduler: &mut Scheduler, text: &str, now: Instant) -> Observation {
        scheduler.observe(stable_hash(text), text, now)
    }

    #[test]
    fn waits_for_a_pause_after_the_last_change() {
        let mut scheduler = Scheduler::new(PAUSE);
        let start = Instant::now();

        assert!(observe(&mut scheduler, "One", start).started_typing);
        assert!(!scheduler.is_paused(start + Duration::from_millis(1000)));
        assert!(
            !observe(
                &mut scheduler,
                "One two",
                start + Duration::from_millis(1000)
            )
            .started_typing
        );
        assert!(!scheduler.is_paused(start + Duration::from_millis(2000)));
        assert!(scheduler.is_paused(start + Duration::from_millis(2600)));
    }

    #[test]
    fn rereading_the_same_text_is_not_a_change() {
        let mut scheduler = Scheduler::new(PAUSE);
        let start = Instant::now();
        observe(&mut scheduler, "Field A", start);
        observe(&mut scheduler, "Field B", start);

        assert!(!observe(&mut scheduler, "Field A", start + PAUSE).changed);
        assert!(!observe(&mut scheduler, "Field B", start + PAUSE).changed);
        assert!(scheduler.is_paused(start + PAUSE));
    }

    #[test]
    fn checks_the_edited_sentence_then_its_paragraph_then_nearby_paragraphs() {
        let before = "First paragraph has one sentence here.\n\nSecond paragraph opens with this line. It keeps going with more words.\n\nThird paragraph is the nearest one after.\n\nFourth paragraph sits far away from the edit.";
        let after = before.replace("keeps going", "keeps on going");
        let mut scheduler = Scheduler::new(PAUSE);
        let start = Instant::now();
        observe(&mut scheduler, before, start);
        observe(&mut scheduler, &after, start);

        let found = sentences(&after);
        let mut checked = Vec::new();
        while let Some(next) = scheduler.next(&found, |key| checked.contains(&key)) {
            checked.push(next.key);
        }
        let order = checked
            .iter()
            .map(|key| found.iter().find(|s| s.key == *key).unwrap().text.as_str())
            .collect::<Vec<_>>();

        assert_eq!(
            order,
            [
                "It keeps on going with more words.",
                "Second paragraph opens with this line.",
                "First paragraph has one sentence here.",
                "Third paragraph is the nearest one after.",
                "Fourth paragraph sits far away from the edit.",
            ]
        );
    }

    #[test]
    fn runs_one_request_at_a_time() {
        let text = "This sentence is long enough to check. So is this second sentence here.";
        let found = sentences(text);
        let mut scheduler = Scheduler::new(PAUSE);
        let id = scheduler.start(&found[0], stable_hash(text));

        assert_eq!(scheduler.next(&found, |_| false), None);
        assert!(scheduler.finish(id + 1).is_none());
        assert_eq!(
            scheduler.finish(id).map(|in_flight| in_flight.key),
            Some(found[0].key)
        );
        assert!(scheduler.next(&found, |_| false).is_some());
    }

    #[test]
    fn cancels_the_request_when_an_edit_removes_its_sentence() {
        let text = "We met in order to plan the trip. The weather looked fine all week.";
        let mut scheduler = Scheduler::new(PAUSE);
        let start = Instant::now();
        observe(&mut scheduler, text, start);
        let id = scheduler.start(&sentences(text)[0], stable_hash(text));

        // Editing the other sentence keeps the request.
        let edited = text.replace("fine", "great");
        let observation = observe(&mut scheduler, &edited, start);
        assert_eq!(
            scheduler.take_stale(observation, stable_hash(&edited), &sentences(&edited)),
            None
        );

        // Editing its own sentence cancels it.
        let rewritten = edited.replace("in order to", "to");
        let observation = observe(&mut scheduler, &rewritten, start);
        assert_eq!(
            scheduler.take_stale(observation, stable_hash(&rewritten), &sentences(&rewritten)),
            Some(id)
        );
        assert!(scheduler.in_flight().is_none());
    }

    #[test]
    fn leaves_requests_from_other_fields_alone() {
        let field_a = "We met in order to plan the trip together.";
        let field_b = "Another field has completely different text.";
        let mut scheduler = Scheduler::new(PAUSE);
        let start = Instant::now();
        observe(&mut scheduler, field_a, start);
        scheduler.start(&sentences(field_a)[0], stable_hash(field_a));

        // Reading another field for the first time is not an edit of the first one.
        let observation = observe(&mut scheduler, field_b, start);
        assert_eq!(
            scheduler.take_stale(observation, stable_hash(field_b), &sentences(field_b)),
            None
        );

        let edited_b = field_b.replace("completely", "entirely");
        let observation = observe(&mut scheduler, &edited_b, start);

        assert_eq!(
            scheduler.take_stale(observation, stable_hash(&edited_b), &sentences(&edited_b)),
            None
        );
        assert!(scheduler.in_flight().is_some());
    }
}
