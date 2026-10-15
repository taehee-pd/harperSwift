//! Added in this fork (taehee-pd/harperSwift).
//!
//! The interface to whatever checks sentences for Clarity. The real provider runs Apple's on-device
//! model in Swift; [`FakeProvider`] returns canned issues after a delay, for tests and for trying
//! the pipeline without Apple Intelligence (`HARPER_CLARITY_FAKE=1`).

use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use super::SentenceKey;
use super::issue::RawIssue;

pub type RequestId = u64;

/// One sentence to check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClarityRequest {
    pub id: RequestId,
    pub key: SentenceKey,
    pub sentence: String,
}

/// The result for one request. Failed requests come back with no issues, so the sentence counts as
/// checked and is not retried in a loop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClarityResponse {
    pub id: RequestId,
    pub key: SentenceKey,
    pub issues: Vec<RawIssue>,
}

/// Whether checks can run right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Availability {
    Available,
    /// The model works, but checks wait to save power.
    Paused(PauseReason),
    Unavailable(UnavailableReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PauseReason {
    LowPowerMode,
    LowBattery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum UnavailableReason {
    DeviceNotEligible,
    AppleIntelligenceNotEnabled,
    ModelNotReady,
    UnsupportedOperatingSystem,
}

/// Checks sentences asynchronously. Every method returns immediately; results arrive through
/// [`ClarityProvider::poll`]. The engine keeps at most one request in flight.
pub trait ClarityProvider {
    fn availability(&mut self) -> Availability;

    /// Loads the model ahead of the first request.
    fn prewarm(&mut self);

    fn submit(&mut self, request: ClarityRequest);

    /// Drops a request whose sentence is gone. A response may still arrive; the engine tolerates
    /// that.
    fn cancel(&mut self, id: RequestId);

    /// Requests finished since the last call.
    fn poll(&mut self, now: Instant) -> Vec<ClarityResponse>;
}

impl<P: ClarityProvider + ?Sized> ClarityProvider for Box<P> {
    fn availability(&mut self) -> Availability {
        (**self).availability()
    }

    fn prewarm(&mut self) {
        (**self).prewarm();
    }

    fn submit(&mut self, request: ClarityRequest) {
        (**self).submit(request);
    }

    fn cancel(&mut self, id: RequestId) {
        (**self).cancel(id);
    }

    fn poll(&mut self, now: Instant) -> Vec<ClarityResponse> {
        (**self).poll(now)
    }
}

/// Wordy phrases the fake provider flags: (phrase, replacement, reason).
const CANNED_ISSUES: &[(&str, &str, &str)] = &[
    (
        "in order to",
        "to",
        "\u{201c}To\u{201d} says the same in fewer words.",
    ),
    (
        "due to the fact that",
        "because",
        "\u{201c}Because\u{201d} is shorter and clearer.",
    ),
    (
        "at this point in time",
        "now",
        "\u{201c}Now\u{201d} says the same thing.",
    ),
    (
        "a large number of",
        "many",
        "\u{201c}Many\u{201d} is more direct.",
    ),
    (
        "has the ability to",
        "can",
        "\u{201c}Can\u{201d} is shorter and clearer.",
    ),
];

/// Answers after `latency` with issues for the phrases in [`CANNED_ISSUES`]. Records what it was
/// asked so tests can check the engine's behavior.
pub struct FakeProvider {
    pub latency: Duration,
    pub availability: Availability,
    pending: Vec<(ClarityRequest, Instant)>,
    /// The time of the last poll, so tests can drive the clock.
    now: Option<Instant>,
    pub submitted: Vec<ClarityRequest>,
    pub cancelled: Vec<RequestId>,
    pub prewarms: usize,
}

impl FakeProvider {
    pub fn new(latency: Duration) -> Self {
        Self {
            latency,
            availability: Availability::Available,
            pending: Vec::new(),
            now: None,
            submitted: Vec::new(),
            cancelled: Vec::new(),
            prewarms: 0,
        }
    }

    /// Issues for the canned phrases in `sentence`, quoting the sentence's own casing.
    pub fn canned_issues(sentence: &str) -> Vec<RawIssue> {
        let lowercase = sentence.to_lowercase();

        CANNED_ISSUES
            .iter()
            .filter_map(|(phrase, replacement, reason)| {
                let start = lowercase.find(phrase)?;
                // Lowercasing can change byte lengths outside ASCII; only quote exact slices.
                let original = sentence.get(start..start + phrase.len())?;
                original.eq_ignore_ascii_case(phrase).then(|| RawIssue {
                    original: original.to_owned(),
                    replacement: match_case(original, replacement),
                    reason: (*reason).to_owned(),
                })
            })
            .take(2)
            .collect()
    }
}

fn match_case(original: &str, replacement: &str) -> String {
    let starts_upper = original.chars().next().is_some_and(char::is_uppercase);
    let mut chars = replacement.chars();

    match chars.next() {
        Some(first) if starts_upper => first.to_uppercase().chain(chars).collect(),
        _ => replacement.to_owned(),
    }
}

impl ClarityProvider for FakeProvider {
    fn availability(&mut self) -> Availability {
        self.availability
    }

    fn prewarm(&mut self) {
        self.prewarms += 1;
    }

    fn submit(&mut self, request: ClarityRequest) {
        self.submitted.push(request.clone());
        self.pending
            .push((request, self.now.unwrap_or_else(Instant::now)));
    }

    fn cancel(&mut self, id: RequestId) {
        self.cancelled.push(id);
        self.pending.retain(|(request, _)| request.id != id);
    }

    fn poll(&mut self, now: Instant) -> Vec<ClarityResponse> {
        self.now = Some(now);
        let latency = self.latency;
        let (done, waiting) = std::mem::take(&mut self.pending)
            .into_iter()
            .partition::<Vec<_>, _>(|(_, submitted)| now.duration_since(*submitted) >= latency);
        self.pending = waiting;

        done.into_iter()
            .map(|(request, _)| ClarityResponse {
                id: request.id,
                key: request.key,
                issues: Self::canned_issues(&request.sentence),
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fake_flags_canned_phrases_in_the_sentences_casing() {
        let issues = FakeProvider::canned_issues("In order to win, we trained daily.");

        assert_eq!(issues.len(), 1);
        assert_eq!(issues[0].original, "In order to");
        assert_eq!(issues[0].replacement, "To");
        assert!(FakeProvider::canned_issues("This sentence is fine as it is.").is_empty());
    }

    #[test]
    fn fake_answers_only_after_its_latency() {
        let mut provider = FakeProvider::new(Duration::from_millis(200));
        provider.submit(ClarityRequest {
            id: 1,
            key: 9,
            sentence: "We met in order to plan.".to_owned(),
        });
        let start = Instant::now();

        assert!(provider.poll(start).is_empty());

        let responses = provider.poll(start + Duration::from_millis(250));
        assert_eq!(responses.len(), 1);
        assert_eq!(responses[0].key, 9);
        assert_eq!(responses[0].issues[0].replacement, "to");
    }
}
