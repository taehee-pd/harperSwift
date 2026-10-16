//! Added in this fork (taehee-pd/harperSwift).
//!
//! Requests from the native editor. Text is checked with the same dictionary, dialect, rules and
//! ignored lints as the highlighter, and each lint comes back in the suggestion popup's JSON
//! (`PopupData` in Swift), with its range in UTF-16 units for `NSTextView`.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use harper_core::linting::{FlatConfig, Lint, LintGroup};
use harper_core::spell::{Dictionary, MergedDictionary, MutableDictionary};
use harper_core::{Dialect, Document, IgnoredLints};
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Manager};
use tokio::sync::Mutex;

use super::{change, param, reply};
use crate::config::Config;
use crate::rect::{ActionableLint, Rect};

type SharedConfig = Arc<Mutex<Config>>;

pub async fn handle(
    app: &AppHandle,
    method: &str,
    params: &Value,
) -> Option<Result<Value, String>> {
    let config = app.state::<SharedConfig>().inner().clone();

    match method {
        "editor.lint" => reply(lint(&config, params).await),
        "editor.ignore" => reply(ignore(&config, params, false).await),
        "editor.ignoreAll" => reply(ignore(&config, params, true).await),
        "editor.disableRule" => {
            let rule = param::<String>(params, "ruleName");
            reply(
                async {
                    let rule = rule?;
                    change(&config, |config| {
                        config.lint_config.set_rule_enabled(rule, false);
                    })
                    .await
                }
                .await,
            )
        }
        _ => None,
    }
}

/// What checking needs from the config, copied so the config lock is not held while checking.
#[derive(Clone)]
struct CheckSettings {
    dictionary: MutableDictionary,
    dialect: Dialect,
    lint_config: FlatConfig,
    ignored_lints: IgnoredLints,
}

impl CheckSettings {
    async fn read(config: &SharedConfig) -> Self {
        let config = config.lock().await;
        let mut lint_config = config.lint_config.clone();
        lint_config.fill_with_curated();

        Self {
            dictionary: config.mutable_dictionary.clone(),
            dialect: config.dialect,
            lint_config,
            ignored_lints: config.ignored_lints.clone(),
        }
    }

    /// Changes whenever anything that affects the results changes.
    fn fingerprint(&self) -> u64 {
        let mut hasher = DefaultHasher::new();
        self.lint_config.hash(&mut hasher);
        self.dialect.hash(&mut hasher);
        serde_json::to_string(&self.ignored_lints)
            .unwrap_or_default()
            .hash(&mut hasher);

        let mut words = self
            .dictionary
            .words_iter()
            .map(|word| word.iter().collect::<String>())
            .collect::<Vec<_>>();
        words.sort();
        words.hash(&mut hasher);

        hasher.finish()
    }
}

/// A linter kept between requests, since building one takes a while.
struct Checker {
    fingerprint: u64,
    linter: LintGroup,
    dictionary: Arc<MergedDictionary>,
    ignored_lints: IgnoredLints,
}

static CHECKER: StdMutex<Option<Checker>> = StdMutex::new(None);

/// Ids are never reused, so the editor and its list cannot mistake a new lint for an old one at the
/// same position.
fn next_lint_id() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

/// Runs `use_lints` on the lints in `text` (ignored ones removed), on a blocking thread.
async fn with_lints<T: Send + 'static>(
    config: &SharedConfig,
    text: String,
    use_lints: impl FnOnce(&str, &Document, Vec<(String, Lint)>) -> T + Send + 'static,
) -> Result<T, String> {
    let settings = CheckSettings::read(config).await;

    tauri::async_runtime::spawn_blocking(move || {
        let mut checker = CHECKER.lock().map_err(|error| error.to_string())?;
        let fingerprint = settings.fingerprint();

        if checker
            .as_ref()
            .is_none_or(|checker| checker.fingerprint != fingerprint)
        {
            let dictionary = Config::dictionary_from_user_dictionary(settings.dictionary);
            *checker = Some(Checker {
                fingerprint,
                linter: LintGroup::new_curated(dictionary.clone(), settings.dialect)
                    .with_lint_config(settings.lint_config),
                dictionary,
                ignored_lints: settings.ignored_lints,
            });
        }

        let checker = checker.as_mut().expect("the checker was just built");
        let document = Document::new_markdown_default(&text, &checker.dictionary);
        let mut lints = Vec::new();
        for (rule, mut rule_lints) in checker.linter.organized_lints(&document) {
            checker
                .ignored_lints
                .remove_ignored(&mut rule_lints, &document);
            lints.extend(rule_lints.into_iter().map(|lint| (rule.clone(), lint)));
        }
        lints.sort_by_key(|(_, lint)| (lint.span.start, lint.span.end));

        Ok(use_lints(&text, &document, lints))
    })
    .await
    .map_err(|error| error.to_string())?
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EditorLint {
    /// UTF-16 range, for `NSTextView`. `editor.ignore` sends it back.
    location: usize,
    length: usize,
    /// The suggestion popup's JSON (`PopupData` in Swift).
    popup: Value,
}

async fn lint(config: &SharedConfig, params: &Value) -> Result<Vec<EditorLint>, String> {
    let text = param::<String>(params, "text")?;

    with_lints(config, text, |text, _, lints| {
        let utf16_offsets = utf16_offsets(text);

        lints
            .into_iter()
            .filter(|(_, lint)| lint.span.end < utf16_offsets.len())
            .map(|(rule, lint)| {
                let (start, end) = (lint.span.start, lint.span.end);
                let actionable = ActionableLint::new(
                    Rect::new(0.0, 0.0, 0.0, 0.0),
                    rule,
                    lint,
                    text.to_owned(),
                    |_| {},
                );

                EditorLint {
                    location: utf16_offsets[start],
                    length: utf16_offsets[end] - utf16_offsets[start],
                    popup: crate::highlighter::popup_json(next_lint_id(), &actionable),
                }
            })
            .collect()
    })
    .await
}

/// Ignores the lint at UTF-16 `location..location + length` from `ruleName`, or every lint
/// when `all` is set.
async fn ignore(config: &SharedConfig, params: &Value, all: bool) -> Result<(), String> {
    let text = param::<String>(params, "text")?;
    let target = if all {
        None
    } else {
        let location = param::<usize>(params, "location")?;
        Some((
            location,
            location + param::<usize>(params, "length")?,
            param::<String>(params, "ruleName")?,
        ))
    };

    let ignored = with_lints(config, text, move |text, document, lints| {
        let utf16_offsets = utf16_offsets(text);
        let mut ignored = IgnoredLints::new();
        for (rule, lint) in lints {
            let matches = target.as_ref().is_none_or(|(start, end, target_rule)| {
                utf16_offsets.get(lint.span.start) == Some(start)
                    && utf16_offsets.get(lint.span.end) == Some(end)
                    && rule == *target_rule
            });
            if matches {
                ignored.ignore_lint(&lint, document);
            }
        }
        ignored
    })
    .await?;

    change(config, |config| config.ignored_lints.append(ignored)).await
}

/// UTF-16 offset of every character index in `text`, plus one past the end.
fn utf16_offsets(text: &str) -> Vec<usize> {
    let mut offsets = Vec::with_capacity(text.len() + 1);
    let mut offset = 0;
    offsets.push(0);
    for character in text.chars() {
        offset += character.len_utf16();
        offsets.push(offset);
    }
    offsets
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Swift decodes each lint as `EditorLint` around the popup's `PopupData`.
    #[test]
    fn sends_lints_in_the_shape_swift_decodes() {
        let config = Arc::new(Mutex::new(Config::new()));
        let params = serde_json::json!({ "text": "😀 This is an test." });
        let lints = tauri::async_runtime::block_on(lint(&config, &params)).unwrap();
        let json = serde_json::to_value(&lints).unwrap();

        let lint = json
            .as_array()
            .and_then(|lints| {
                lints
                    .iter()
                    .find(|lint| lint["popup"]["flagged_text"] == "an")
            })
            .expect("the article is flagged");
        // The emoji is two UTF-16 units, so "an" starts at 2 + 9.
        assert_eq!(lint["location"], 11);
        assert_eq!(lint["length"], 2);
        for key in [
            "id",
            "kind_name",
            "kind_color",
            "message",
            "suggestions",
            "anchor",
        ] {
            assert!(lint["popup"].get(key).is_some(), "popup has no `{key}`");
        }
    }

    #[test]
    fn never_reuses_lint_ids() {
        let config = Arc::new(Mutex::new(Config::new()));
        let params = serde_json::json!({ "text": "Ths is an test." });
        let ids = || {
            tauri::async_runtime::block_on(lint(&config, &params))
                .unwrap()
                .iter()
                .map(|lint| lint.popup["id"].as_u64().unwrap())
                .collect::<Vec<_>>()
        };

        let first = ids();
        let second = ids();
        assert!(first.len() >= 2);
        assert!(first.iter().all(|id| !second.contains(id)));
    }

    #[test]
    fn maps_character_indexes_to_utf16() {
        assert_eq!(utf16_offsets("a😀b"), vec![0, 1, 3, 4]);
        assert_eq!(utf16_offsets(""), vec![0]);
    }
}
