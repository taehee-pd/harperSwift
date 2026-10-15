//! Added in this fork (taehee-pd/harperSwift).
//!
//! Clarity provider backed by Apple's on-device model, through the C interface of the Swift package
//! in `harper-desktop/macos-popup` (`Clarity/ClarityBridge.swift`). All calls happen on the main
//! thread, which runs both the winit event loop and the Swift main actor.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char};
use std::time::Instant;

use serde::Deserialize;

use super::SentenceKey;
use super::issue::RawIssue;
use super::provider::{
    Availability, ClarityProvider, ClarityRequest, ClarityResponse, PauseReason, RequestId,
    UnavailableReason,
};

unsafe extern "C" {
    fn harper_clarity_set_result_handler(handler: extern "C" fn(u64, *const c_char));
    fn harper_clarity_availability() -> i32;
    fn harper_clarity_prewarm();
    fn harper_clarity_submit(id: u64, sentence: *const c_char);
    fn harper_clarity_cancel(id: u64);
}

thread_local! {
    /// Results reported by Swift as (request id, JSON), drained by `AppleProvider::poll`.
    static RESULTS: RefCell<Vec<(RequestId, String)>> = const { RefCell::new(Vec::new()) };
}

/// Called by Swift when a request finishes. Only queues the result; the engine collects it on its
/// next frame.
extern "C" fn queue_result(id: u64, json: *const c_char) {
    if json.is_null() {
        return;
    }
    let json = unsafe { CStr::from_ptr(json) }
        .to_string_lossy()
        .into_owned();

    RESULTS.with(|results| {
        if let Ok(mut results) = results.try_borrow_mut() {
            results.push((id, json));
        }
    });
}

/// One issue as Swift encodes it (`ClarityIssueWire`).
#[derive(Debug, Deserialize)]
struct WireIssue {
    original: String,
    replacement: String,
    reason: String,
}

pub struct AppleProvider {
    /// Sentence keys of the requests Swift is working on.
    pending: HashMap<RequestId, SentenceKey>,
    /// Requests answered without asking Swift (text it cannot take).
    answered: Vec<ClarityResponse>,
}

impl AppleProvider {
    pub fn new() -> Self {
        unsafe { harper_clarity_set_result_handler(queue_result) };

        Self {
            pending: HashMap::new(),
            answered: Vec::new(),
        }
    }
}

impl ClarityProvider for AppleProvider {
    fn availability(&mut self) -> Availability {
        availability_from_code(unsafe { harper_clarity_availability() })
    }

    fn prewarm(&mut self) {
        unsafe { harper_clarity_prewarm() }
    }

    fn submit(&mut self, request: ClarityRequest) {
        let Ok(sentence) = CString::new(request.sentence) else {
            // Text with NUL bytes cannot cross the C interface; count it as checked.
            self.answered.push(ClarityResponse {
                id: request.id,
                key: request.key,
                issues: Vec::new(),
            });
            return;
        };

        self.pending.insert(request.id, request.key);
        unsafe { harper_clarity_submit(request.id, sentence.as_ptr()) }
    }

    fn cancel(&mut self, id: RequestId) {
        if self.pending.remove(&id).is_some() {
            unsafe { harper_clarity_cancel(id) }
        }
    }

    fn poll(&mut self, _now: Instant) -> Vec<ClarityResponse> {
        let mut responses = std::mem::take(&mut self.answered);

        for (id, json) in RESULTS.with(RefCell::take) {
            if let Some(key) = self.pending.remove(&id) {
                responses.push(ClarityResponse {
                    id,
                    key,
                    issues: decode_issues(&json),
                });
            }
        }

        responses
    }
}

/// Codes from `ClarityAvailability` in `ClarityChecker.swift`. Unknown codes count as "model not
/// ready" so nothing runs.
fn availability_from_code(code: i32) -> Availability {
    match code {
        0 => Availability::Available,
        1 => Availability::Paused(PauseReason::LowPowerMode),
        2 => Availability::Paused(PauseReason::LowBattery),
        3 => Availability::Unavailable(UnavailableReason::DeviceNotEligible),
        4 => Availability::Unavailable(UnavailableReason::AppleIntelligenceNotEnabled),
        6 => Availability::Unavailable(UnavailableReason::UnsupportedOperatingSystem),
        _ => Availability::Unavailable(UnavailableReason::ModelNotReady),
    }
}

/// Malformed JSON counts as "no issues", like any other failed request.
fn decode_issues(json: &str) -> Vec<RawIssue> {
    serde_json::from_str::<Vec<WireIssue>>(json)
        .unwrap_or_default()
        .into_iter()
        .map(|issue| RawIssue {
            original: issue.original,
            replacement: issue.replacement,
            reason: issue.reason,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_the_issues_swift_sends() {
        let issues =
            decode_issues(r#"[{"original":"in order to","replacement":"to","reason":"Shorter."}]"#);

        assert_eq!(
            issues,
            [RawIssue {
                original: "in order to".to_owned(),
                replacement: "to".to_owned(),
                reason: "Shorter.".to_owned(),
            }]
        );
        assert!(decode_issues("[]").is_empty());
        assert!(decode_issues("not json").is_empty());
    }

    /// Must stay in sync with `ClarityAvailability` in `ClarityChecker.swift`.
    #[test]
    fn maps_every_availability_code() {
        assert_eq!(availability_from_code(0), Availability::Available);
        assert_eq!(
            availability_from_code(1),
            Availability::Paused(PauseReason::LowPowerMode)
        );
        assert_eq!(
            availability_from_code(2),
            Availability::Paused(PauseReason::LowBattery)
        );
        assert_eq!(
            availability_from_code(3),
            Availability::Unavailable(UnavailableReason::DeviceNotEligible)
        );
        assert_eq!(
            availability_from_code(4),
            Availability::Unavailable(UnavailableReason::AppleIntelligenceNotEnabled)
        );
        assert_eq!(
            availability_from_code(5),
            Availability::Unavailable(UnavailableReason::ModelNotReady)
        );
        assert_eq!(
            availability_from_code(6),
            Availability::Unavailable(UnavailableReason::UnsupportedOperatingSystem)
        );
        assert_eq!(
            availability_from_code(42),
            Availability::Unavailable(UnavailableReason::ModelNotReady)
        );
    }
}
