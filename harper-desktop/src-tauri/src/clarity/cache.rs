//! Added in this fork (taehee-pd/harperSwift).
//!
//! Least-recently-used cache of Clarity results, keyed by sentence text.

use std::collections::HashMap;

use super::SentenceKey;
use super::issue::SentenceIssue;

/// How many sentences to remember. Each entry is small; this covers several long documents.
pub const CAPACITY: usize = 2_000;

pub struct ClarityCache {
    entries: HashMap<SentenceKey, Entry>,
    capacity: usize,
    clock: u64,
}

struct Entry {
    /// Empty means "checked, no issues".
    issues: Vec<SentenceIssue>,
    last_used: u64,
}

impl ClarityCache {
    pub fn new(capacity: usize) -> Self {
        Self {
            entries: HashMap::new(),
            capacity: capacity.max(1),
            clock: 0,
        }
    }

    pub fn contains(&self, key: SentenceKey) -> bool {
        self.entries.contains_key(&key)
    }

    /// The issues for a checked sentence, marking it as recently used.
    pub fn get(&mut self, key: SentenceKey) -> Option<&[SentenceIssue]> {
        self.clock += 1;
        let clock = self.clock;

        self.entries.get_mut(&key).map(|entry| {
            entry.last_used = clock;
            entry.issues.as_slice()
        })
    }

    pub fn insert(&mut self, key: SentenceKey, issues: Vec<SentenceIssue>) {
        self.clock += 1;

        if !self.entries.contains_key(&key) && self.entries.len() >= self.capacity {
            self.evict_least_recently_used();
        }

        self.entries.insert(
            key,
            Entry {
                issues,
                last_used: self.clock,
            },
        );
    }

    /// Drops one issue from a checked sentence, keeping the sentence checked.
    pub fn remove_issue(&mut self, key: SentenceKey, span: &std::ops::Range<usize>) {
        if let Some(entry) = self.entries.get_mut(&key) {
            entry.issues.retain(|issue| issue.span != *span);
        }
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// A linear scan, which is fine at this size and only runs once the cache is full.
    fn evict_least_recently_used(&mut self) {
        if let Some(oldest) = self
            .entries
            .iter()
            .min_by_key(|(_, entry)| entry.last_used)
            .map(|(key, _)| *key)
        {
            self.entries.remove(&oldest);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn issue(replacement: &str) -> Vec<SentenceIssue> {
        vec![SentenceIssue {
            span: 0..1,
            replacement: replacement.to_owned(),
            reason: String::new(),
        }]
    }

    #[test]
    fn remembers_checked_sentences_with_and_without_issues() {
        let mut cache = ClarityCache::new(4);
        cache.insert(1, issue("a"));
        cache.insert(2, Vec::new());

        assert_eq!(cache.get(1).map(<[_]>::len), Some(1));
        assert_eq!(cache.get(2).map(<[_]>::len), Some(0));
        assert_eq!(cache.get(3), None);
    }

    #[test]
    fn evicts_the_least_recently_used_sentence() {
        let mut cache = ClarityCache::new(2);
        cache.insert(1, issue("a"));
        cache.insert(2, issue("b"));
        cache.get(1);
        cache.insert(3, issue("c"));

        assert!(cache.contains(1));
        assert!(!cache.contains(2));
        assert!(cache.contains(3));
        assert_eq!(cache.len(), 2);
    }

    #[test]
    fn removing_an_issue_keeps_the_sentence_checked() {
        let mut cache = ClarityCache::new(2);
        cache.insert(1, issue("a"));
        cache.remove_issue(1, &(0..1));

        assert_eq!(cache.get(1).map(<[_]>::len), Some(0));
    }

    #[test]
    fn replacing_an_entry_does_not_evict() {
        let mut cache = ClarityCache::new(2);
        cache.insert(1, issue("a"));
        cache.insert(2, issue("b"));
        cache.insert(2, issue("c"));

        assert!(cache.contains(1));
        assert_eq!(cache.get(2).unwrap()[0].replacement, "c");
    }
}
