//! Added in this fork (taehee-pd/harperSwift).
//!
//! Tells typing apart from moving the caret, from one read of the focused text field to the next.
//!
//! - While the user types, the word under the caret is unfinished, so its lint would flicker on
//!   and off with every keystroke. Lints at the caret stay hidden until the caret moves on.
//! - When the caret moves without the text changing (arrow keys, a click), the user went there on
//!   purpose: a lint under the caret is shown and its popup opens.
//! - Arriving in a field (focusing it, switching back to the app) is neither: lints show as usual
//!   and no popup opens by itself.

use harper_core::Span;

/// How the caret got to where it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaretMotion {
    /// The field was just focused.
    Arrived,
    /// The text changed since the last read.
    Typed,
    /// The caret moved and the text did not change.
    Moved,
}

/// What the caret is doing in the field that was just read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CaretState {
    /// The caret as a character index, or `None` when there is a selection or no caret.
    pub caret: Option<usize>,
    pub motion: CaretMotion,
}

impl CaretState {
    /// How a lint relates to the caret.
    pub fn relation(self, span: Span<char>) -> CaretRelation {
        match self.caret {
            // The caret right after a word still counts as in it: "teh|" is mid-typing.
            Some(caret) if span.start <= caret && caret <= span.end => match self.motion {
                CaretMotion::Typed => CaretRelation::Typing,
                CaretMotion::Moved => CaretRelation::Visiting,
                CaretMotion::Arrived => CaretRelation::Away,
            },
            _ => CaretRelation::Away,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaretRelation {
    /// Show the lint as usual.
    Away,
    /// The user is typing in this lint's text: hide it until the caret moves on.
    Typing,
    /// The caret moved into this lint: show it and open its popup.
    Visiting,
}

struct Observation<E> {
    element: E,
    text: String,
    caret: Option<usize>,
}

/// Generic over the field handle (`AXUIElement` in the app) so tests can use plain values.
pub struct CaretTracker<E> {
    last: Option<Observation<E>>,
    motion: CaretMotion,
}

impl<E> Default for CaretTracker<E> {
    fn default() -> Self {
        Self {
            last: None,
            motion: CaretMotion::Arrived,
        }
    }
}

impl<E: PartialEq + Clone> CaretTracker<E> {
    /// Records one read of the focused field and says how the caret got there.
    pub fn observe(&mut self, element: &E, text: &str, caret: Option<usize>) -> CaretState {
        self.motion = match &self.last {
            None => CaretMotion::Arrived,
            Some(last) if last.element != *element => CaretMotion::Arrived,
            Some(last) if last.text != text => CaretMotion::Typed,
            Some(last) if last.caret != caret => CaretMotion::Moved,
            Some(_) => self.motion,
        };

        self.last = Some(Observation {
            element: element.clone(),
            text: text.to_owned(),
            caret,
        });

        CaretState {
            caret,
            motion: self.motion,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(caret: usize, motion: CaretMotion) -> CaretState {
        CaretState {
            caret: Some(caret),
            motion,
        }
    }

    #[test]
    fn hides_the_word_being_typed() {
        assert_eq!(
            state(3, CaretMotion::Typed).relation(Span::new(0, 3)),
            CaretRelation::Typing
        );
    }

    #[test]
    fn shows_a_word_once_the_caret_moves_on() {
        assert_eq!(
            state(4, CaretMotion::Typed).relation(Span::new(0, 3)),
            CaretRelation::Away
        );
    }

    #[test]
    fn opens_a_word_the_caret_moved_into() {
        assert_eq!(
            state(1, CaretMotion::Moved).relation(Span::new(0, 3)),
            CaretRelation::Visiting
        );
    }

    #[test]
    fn shows_without_opening_on_arrival() {
        assert_eq!(
            state(1, CaretMotion::Arrived).relation(Span::new(0, 3)),
            CaretRelation::Away
        );
    }

    #[test]
    fn ignores_lints_without_a_caret() {
        let state = CaretState {
            caret: None,
            motion: CaretMotion::Typed,
        };
        assert_eq!(state.relation(Span::new(0, 3)), CaretRelation::Away);
    }

    #[test]
    fn typing_then_moving_the_caret() {
        let mut tracker = CaretTracker::default();
        assert_eq!(
            tracker.observe(&1, "teh", Some(3)).motion,
            CaretMotion::Arrived
        );
        assert_eq!(
            tracker.observe(&1, "teh ", Some(4)).motion,
            CaretMotion::Typed
        );
        // A read with nothing new keeps the last answer.
        assert_eq!(
            tracker.observe(&1, "teh ", Some(4)).motion,
            CaretMotion::Typed
        );
        assert_eq!(
            tracker.observe(&1, "teh ", Some(1)).motion,
            CaretMotion::Moved
        );
        assert_eq!(
            tracker.observe(&1, "tseh ", Some(2)).motion,
            CaretMotion::Typed
        );
    }

    #[test]
    fn a_new_field_is_an_arrival() {
        let mut tracker = CaretTracker::default();
        tracker.observe(&1, "one", Some(3));
        tracker.observe(&1, "one two", Some(7));
        assert_eq!(
            tracker.observe(&2, "three", Some(2)).motion,
            CaretMotion::Arrived
        );
    }
}
