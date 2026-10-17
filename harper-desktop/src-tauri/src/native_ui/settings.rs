//! Added in this fork (taehee-pd/harperSwift).
//!
//! Requests from the native Settings window and the first-run setup. Each change mirrors the
//! matching Tauri command in `commands.rs`: change [`Config`], then save it.

use std::collections::HashMap;
use std::sync::{Arc, Mutex as StdMutex, OnceLock, RwLock};

use harper_core::linting::{
    FlatConfig, HumanReadableSetting, HumanReadableStructuredConfig, StructuredConfig,
};
use harper_core::spell::{Dictionary, MutableDictionary};
use harper_core::{Dialect, DictWordMetadata};
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Manager};
use tauri_plugin_autostart::ManagerExt;
use tokio::sync::Mutex;

use super::{change, param, reply};
use crate::PlatformBroker;
use crate::clarity::settings::ClaritySettingsView;
use crate::config::Config;
use crate::desktop_updater::DesktopUpdater;
use crate::highlighter_service::HighlighterService;
use crate::os_broker::OsBroker;

type SharedConfig = Arc<Mutex<Config>>;

pub async fn handle(
    app: &AppHandle,
    method: &str,
    params: &Value,
) -> Option<Result<Value, String>> {
    let config = app.state::<SharedConfig>().inner().clone();
    let config = &config;

    match method {
        "settings.load" => reply(load(app, config).await),
        "settings.setDialect" => reply(
            async {
                let dialect = param::<Dialect>(params, "dialect")?;
                change(config, |config| config.dialect = dialect).await
            }
            .await,
        ),
        "settings.setDebounceMs" => reply(
            async {
                let value = param::<u64>(params, "value")?;
                change(config, |config| config.debounce_ms = value).await
            }
            .await,
        ),
        "settings.setAutoUpdate" => reply(
            async {
                let enabled = param::<bool>(params, "enabled")?;
                change(config, |config| config.auto_update = enabled).await
            }
            .await,
        ),
        "settings.setLaunchAtLogin" => reply(set_launch_at_login(app, params)),
        "clarity.setEnabled" => reply(
            async {
                let enabled = param::<bool>(params, "enabled")?;
                change(config, |config| config.clarity.enabled = Some(enabled)).await
            }
            .await,
        ),
        "updates.latestVersion" => reply(DesktopUpdater::latest_version().await),
        "updates.check" => reply(
            app.state::<DesktopUpdater>()
                .update_to_latest(app, false)
                .await
                .ok_or_else(|| "The update check was skipped.".to_owned()),
        ),
        "dictionary.set" => reply(
            async {
                let words = param::<Vec<String>>(params, "words")?;
                let mut dictionary = MutableDictionary::new();
                dictionary.extend_words(words.into_iter().map(|word| {
                    (
                        word.chars().collect::<Vec<_>>(),
                        DictWordMetadata::default(),
                    )
                }));
                change(config, |config| config.mutable_dictionary = dictionary).await
            }
            .await,
        ),
        "dictionary.add" => reply(
            async {
                let word = param::<String>(params, "word")?;
                change(config, |config| {
                    config
                        .mutable_dictionary
                        .append_word_str(&word, DictWordMetadata::default());
                })
                .await
            }
            .await,
        ),
        "apps.add" => reply(
            async {
                let bundle_id = param::<String>(params, "bundleId")?;
                change(config, |config| config.add_integration(bundle_id)).await
            }
            .await,
        ),
        "apps.remove" => reply(
            async {
                let bundle_id = param::<String>(params, "bundleId")?;
                change(config, |config| config.remove_integration(&bundle_id)).await
            }
            .await,
        ),
        "apps.setEnabled" => reply(
            async {
                let bundle_id = param::<String>(params, "bundleId")?;
                let enabled = param::<bool>(params, "enabled")?;
                change(config, |config| {
                    config.set_integration_enabled(&bundle_id, enabled);
                })
                .await
            }
            .await,
        ),
        "apps.setAutoEnable" => reply(
            async {
                let enabled = param::<bool>(params, "enabled")?;
                change(config, |config| config.auto_enable_new_apps = enabled).await
            }
            .await,
        ),
        "apps.search" => reply(search_apps(app, params).await),
        "rules.load" => reply(Ok(rule_groups(&config.lock().await.lint_config))),
        "rules.setEnabled" => reply(
            async {
                let ids = param::<Vec<String>>(params, "ids")?;
                let enabled = param::<bool>(params, "enabled")?;
                change(config, |config| {
                    for id in ids {
                        config.lint_config.set_rule_enabled(id, enabled);
                    }
                })
                .await
            }
            .await,
        ),
        "rules.restoreDefaults" => reply(
            async {
                let ids = param::<Option<Vec<String>>>(params, "ids")?;
                let defaults = FlatConfig::new_curated();
                change(config, |config| match ids {
                    Some(ids) => {
                        for id in ids {
                            let enabled = defaults.is_rule_enabled(&id);
                            config.lint_config.set_rule_enabled(id, enabled);
                        }
                    }
                    None => config.lint_config = defaults,
                })
                .await
            }
            .await,
        ),
        "rules.turnAllOff" => reply(
            change(config, |config| {
                for id in rule_ids(&FlatConfig::new_curated()) {
                    config.lint_config.set_rule_enabled(id, false);
                }
            })
            .await,
        ),
        "onboarding.complete" => {
            reply(change(config, |config| config.onboarding_completed = true).await)
        }
        "service.start" => reply(
            crate::commands::start_highlighter_service(
                app.state::<SharedConfig>(),
                app.state::<HighlighterService>(),
            )
            .await,
        ),
        _ => None,
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SettingsSnapshot {
    dialect: Dialect,
    debounce_ms: u64,
    launch_at_login: bool,
    auto_update: bool,
    version: String,
    clarity: ClaritySettingsView,
    dictionary: Vec<String>,
    apps: Vec<AppView>,
    auto_enable_new_apps: bool,
    onboarding_completed: bool,
    /// Whether the highlighter is running, so Harper is checking text in other apps.
    checking: bool,
    /// Whether checking is turned on, even if it cannot run (without Accessibility access).
    checking_enabled: bool,
    accessibility_granted: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AppView {
    bundle_id: String,
    name: String,
    enabled: bool,
}

async fn load(app: &AppHandle, config: &SharedConfig) -> Result<SettingsSnapshot, String> {
    // Copy what is needed and let go of the config: the highlighter reads it too, and app names
    // below can take a Spotlight query each.
    let (mut snapshot, integrations) = {
        let config = config.lock().await;
        let dictionary = config
            .mutable_dictionary
            .words_iter()
            .map(|word| word.iter().collect::<String>())
            .collect::<Vec<_>>();
        let snapshot = SettingsSnapshot {
            dialect: config.dialect,
            debounce_ms: config.debounce_ms,
            launch_at_login: false,
            auto_update: config.auto_update,
            version: DesktopUpdater::current_version(app),
            clarity: ClaritySettingsView::new(&config.clarity),
            dictionary,
            apps: Vec::new(),
            auto_enable_new_apps: config.auto_enable_new_apps,
            onboarding_completed: config.onboarding_completed,
            checking: false,
            checking_enabled: config.highlighter_service_enabled,
            accessibility_granted: false,
        };
        (snapshot, config.integrations.clone())
    };

    snapshot.dictionary.sort_by_key(|word| word.to_lowercase());
    snapshot.launch_at_login = app.autolaunch().is_enabled().unwrap_or(false);
    snapshot.checking = app.state::<HighlighterService>().is_running();
    snapshot.accessibility_granted = crate::accessibility_watch::is_granted(app);
    if !snapshot.checking {
        // Clarity reports its status while checking text, so there is nothing to report yet.
        snapshot.clarity.status = "Waiting: starts once Harper is checking your writing".to_owned();
    }

    let broker = app.state::<RwLock<PlatformBroker>>();
    let broker = broker
        .read()
        .map_err(|error| format!("Failed to read platform broker: {error}"))?;
    snapshot.apps = integrations
        .into_iter()
        .map(|integration| AppView {
            name: app_name(&broker, &integration.bundle_id),
            bundle_id: integration.bundle_id,
            enabled: integration.enabled,
        })
        .collect();

    Ok(snapshot)
}

/// An app's name, remembered: Settings reloads every few seconds, and each lookup is a Spotlight
/// query.
fn app_name(broker: &PlatformBroker, bundle_id: &str) -> String {
    static NAMES: OnceLock<StdMutex<HashMap<String, String>>> = OnceLock::new();
    let names = NAMES.get_or_init(Default::default);

    if let Some(name) = names
        .lock()
        .ok()
        .and_then(|names| names.get(bundle_id).cloned())
    {
        return name;
    }
    let name = broker.integration_display_name(bundle_id);
    if let Ok(mut names) = names.lock() {
        names.insert(bundle_id.to_owned(), name.clone());
    }
    name
}

fn set_launch_at_login(app: &AppHandle, params: &Value) -> Result<(), String> {
    let launcher = app.autolaunch();
    let result = if param::<bool>(params, "enabled")? {
        launcher.enable()
    } else {
        launcher.disable()
    };
    result.map_err(|error| error.to_string())
}

async fn search_apps(
    app: &AppHandle,
    params: &Value,
) -> Result<Vec<crate::os_broker::AppSearchResult>, String> {
    let query = param::<String>(params, "query")?;
    let app = app.clone();

    tauri::async_runtime::spawn_blocking(move || {
        app.state::<RwLock<PlatformBroker>>()
            .read()
            .map_err(|error| format!("Failed to read platform broker: {error}"))?
            .search_apps(&query)
    })
    .await
    .map_err(|error| error.to_string())?
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct RuleGroupView {
    title: String,
    description: String,
    rules: Vec<RuleView>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct RuleView {
    id: String,
    name: String,
    description: String,
    enabled: bool,
    enabled_by_default: bool,
}

/// Every rule, grouped the way Harper's curated config groups them, with its description and
/// whether it is on now and by default.
fn rule_groups(lint_config: &FlatConfig) -> Vec<RuleGroupView> {
    let mut current = lint_config.clone();
    current.fill_with_curated();
    let defaults = FlatConfig::new_curated();
    let catalog =
        HumanReadableStructuredConfig::from_structured_config(&StructuredConfig::curated());
    let make_rule = |id: &str, label: Option<&str>| RuleView {
        id: id.to_owned(),
        name: label.map_or_else(|| label_from_id(id), str::to_owned),
        description: descriptions().get(id).cloned().unwrap_or_default(),
        enabled: current.is_rule_enabled(id),
        enabled_by_default: defaults.is_rule_enabled(id),
    };

    let mut groups = Vec::new();
    let mut ungrouped = Vec::new();
    for setting in &catalog.settings {
        collect_rules(setting, &make_rule, &mut groups, &mut ungrouped);
    }

    if !ungrouped.is_empty() {
        groups.push(RuleGroupView {
            title: "Other Rules".to_owned(),
            description: "Rules that are not part of a category.".to_owned(),
            rules: ungrouped,
        });
    }

    groups
}

/// Adds the rules in `setting` to `rules`, and each group it contains to `groups`, parents before
/// their nested groups.
fn collect_rules(
    setting: &HumanReadableSetting,
    make_rule: &impl Fn(&str, Option<&str>) -> RuleView,
    groups: &mut Vec<RuleGroupView>,
    rules: &mut Vec<RuleView>,
) {
    match setting {
        HumanReadableSetting::Bool { name, label, .. } => {
            rules.push(make_rule(name, label.as_deref()));
        }
        HumanReadableSetting::OneOfMany { names, labels, .. } => {
            for (index, name) in names.iter().enumerate() {
                let label = labels.as_ref().and_then(|labels| labels.get(index));
                rules.push(make_rule(name, label.map(String::as_str)));
            }
        }
        HumanReadableSetting::Group {
            label,
            description,
            child,
        } => {
            let position = groups.len();
            let mut group_rules = Vec::new();
            for setting in &child.settings {
                collect_rules(setting, make_rule, groups, &mut group_rules);
            }
            if !group_rules.is_empty() {
                groups.insert(
                    position,
                    RuleGroupView {
                        title: label.clone().unwrap_or_default(),
                        description: description.clone(),
                        rules: group_rules,
                    },
                );
            }
        }
    }
}

/// Rule descriptions as plain text, keyed by rule name. They never change while the app runs.
fn descriptions() -> &'static HashMap<String, String> {
    static DESCRIPTIONS: OnceLock<HashMap<String, String>> = OnceLock::new();

    DESCRIPTIONS.get_or_init(|| {
        let dictionary = Config::dictionary_from_user_dictionary(MutableDictionary::new());
        harper_core::linting::LintGroup::new_curated(dictionary, Dialect::American)
            .all_descriptions()
            .into_iter()
            .map(|(id, description)| (id.to_owned(), plain_text(description)))
            .collect()
    })
}

/// Drops the Markdown marks Harper uses in descriptions (code spans and bold).
fn plain_text(markdown: &str) -> String {
    markdown
        .replace("**", "")
        .replace('`', "")
        .trim()
        .to_owned()
}

/// "AmazonNames" becomes "Amazon Names", for rules the catalog does not label.
fn label_from_id(id: &str) -> String {
    let chars = id.chars().collect::<Vec<_>>();
    let mut label = String::new();

    for (index, &character) in chars.iter().enumerate() {
        let previous = index.checked_sub(1).map(|index| chars[index]);
        let next = chars.get(index + 1).copied();
        let starts_word = character.is_uppercase()
            && previous.is_some_and(|previous| {
                previous.is_lowercase()
                    || previous.is_ascii_digit()
                    || (previous.is_uppercase() && next.is_some_and(char::is_lowercase))
            });

        if starts_word {
            label.push(' ');
        }
        label.push(character);
    }

    label
}

/// The names of the rules in `config`.
fn rule_ids(config: &FlatConfig) -> Vec<String> {
    match serde_json::to_value(config) {
        Ok(Value::Object(map)) => map.keys().cloned().collect(),
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_rule_ids() {
        assert_eq!(label_from_id("AmazonNames"), "Amazon Names");
        assert_eq!(label_from_id("ANA"), "ANA");
        assert_eq!(label_from_id("HTMLEntities"), "HTML Entities");
        assert_eq!(label_from_id("Spaces2Tabs"), "Spaces2 Tabs");
    }

    #[test]
    fn strips_markdown_from_descriptions() {
        assert_eq!(plain_text("Use `in` **here**. "), "Use in here.");
    }

    #[test]
    fn lists_every_rule_once() {
        let groups = rule_groups(&FlatConfig::new_curated());
        let listed = groups
            .iter()
            .flat_map(|group| group.rules.iter().map(|rule| rule.id.clone()))
            .collect::<Vec<_>>();
        let unique = listed.iter().collect::<std::collections::HashSet<_>>();

        assert!(listed.len() > 100, "only {} rules listed", listed.len());
        assert_eq!(listed.len(), unique.len(), "a rule is listed twice");
        assert!(groups.iter().all(|group| !group.title.is_empty()));
        assert!(
            groups
                .iter()
                .flat_map(|group| &group.rules)
                .all(|rule| rule.enabled == rule.enabled_by_default)
        );
    }

    /// `macos-popup/Tests/HarperPopupTests/Fixtures/settings.json` pins the format for both sides.
    #[test]
    fn snapshot_matches_the_swift_fixture() {
        let snapshot = SettingsSnapshot {
            dialect: Dialect::British,
            debounce_ms: 250,
            launch_at_login: true,
            auto_update: false,
            version: "1.2.0".to_owned(),
            clarity: ClaritySettingsView {
                enabled: true,
                available: false,
                status: "Unavailable: Apple Intelligence is turned off in System Settings"
                    .to_owned(),
            },
            dictionary: vec!["Harper".to_owned(), "macOS".to_owned()],
            apps: vec![AppView {
                bundle_id: "com.apple.TextEdit".to_owned(),
                name: "TextEdit".to_owned(),
                enabled: true,
            }],
            auto_enable_new_apps: true,
            onboarding_completed: false,
            checking: false,
            checking_enabled: true,
            accessibility_granted: true,
        };
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../macos-popup/Tests/HarperPopupTests/Fixtures/settings.json"
        ))
        .unwrap();

        assert_eq!(serde_json::to_value(&snapshot).unwrap(), fixture);
    }

    #[test]
    fn finds_the_rule_ids() {
        assert!(rule_ids(&FlatConfig::new_curated()).len() > 100);
    }
}
