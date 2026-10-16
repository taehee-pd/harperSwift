//! Added in this fork (taehee-pd/harperSwift).
//!
//! The Clarity on/off setting and the model's status, kept in sync across the two processes:
//!
//! - The Tauri app saves the setting in [`Config`] and shows both in the settings window.
//! - The highlighter runs the model. On every config refresh it reports the model's status,
//!   sends a "turn off" from the popup, and reads the setting back
//!   ([`sync_with_app`], over `communication/message.rs`).

use std::cell::RefCell;
use std::ops::Range;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tauri::ipc::Invoke;
use tauri::{Runtime, State};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::runtime::Runtime as TokioRuntime;
use tokio::sync::Mutex;

use super::SentenceKey;
use super::provider::{Availability, PauseReason, UnavailableReason};
use crate::communication::Client;
use crate::config::Config;

/// What the app saves about Clarity.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClaritySettings {
    /// `None` until the user flips the switch: Clarity is on wherever the model can run.
    pub enabled: Option<bool>,
    /// The latest status reported by the highlighter. Not saved.
    #[serde(skip)]
    pub status: Option<Availability>,
}

impl ClaritySettings {
    pub fn is_enabled(&self) -> bool {
        self.enabled.unwrap_or(true)
    }
}

/// Highlighter-to-app messages, carried by `Request::Clarity`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ClarityMessage {
    GetEnabled,
    SetEnabled { enabled: bool },
    SetStatus { status: Availability },
}

/// Replies, carried by `Response::Clarity`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ClarityReply {
    Enabled { enabled: bool },
    Ack,
}

/// Answers a message from the highlighter, saving the config when the setting changes.
pub async fn handle_message(message: &ClarityMessage, config: &mut Config) -> ClarityReply {
    match message {
        ClarityMessage::GetEnabled => ClarityReply::Enabled {
            enabled: config.clarity.is_enabled(),
        },
        ClarityMessage::SetEnabled { enabled } => {
            config.clarity.enabled = Some(*enabled);
            if let Err(error) = config.save_to_system().await {
                eprintln!("failed to save config: {error}");
            }
            ClarityReply::Ack
        }
        ClarityMessage::SetStatus { status } => {
            config.clarity.status = Some(*status);
            ClarityReply::Ack
        }
    }
}

/// The highlighter's copy of the setting, what it still has to tell the app, and dismissals the
/// engine has not applied yet.
struct HighlighterState {
    enabled: bool,
    status: Option<Availability>,
    reported_status: Option<Availability>,
    turn_off_requested: bool,
    /// Sentence and span (in the sentence) of suggestions dismissed in the popup.
    dismissed: Vec<(SentenceKey, Range<usize>)>,
}

thread_local! {
    /// The highlighter runs Clarity and the popup on its main thread.
    static HIGHLIGHTER: RefCell<HighlighterState> = const {
        RefCell::new(HighlighterState {
            enabled: true,
            status: None,
            reported_status: None,
            turn_off_requested: false,
            dismissed: Vec::new(),
        })
    };
}

/// Whether Clarity is turned on, as last read from the app.
pub fn is_enabled() -> bool {
    HIGHLIGHTER.with(|state| state.borrow().enabled)
}

/// Remembers the model's status so the next sync can report it.
pub fn record_status(status: Availability) {
    HIGHLIGHTER.with(|state| state.borrow_mut().status = Some(status));
}

/// "Turn Off Clarity" in the popup: takes effect at once and is saved on the next
/// sync.
pub fn turn_off() {
    HIGHLIGHTER.with(|state| {
        let mut state = state.borrow_mut();
        state.enabled = false;
        state.turn_off_requested = true;
    });
}

/// Queues a dismissal from the popup for the engine to apply on its next frame.
pub fn record_dismissal(key: SentenceKey, span: Range<usize>) {
    HIGHLIGHTER.with(|state| state.borrow_mut().dismissed.push((key, span)));
}

pub fn take_dismissals() -> Vec<(SentenceKey, Range<usize>)> {
    HIGHLIGHTER.with(|state| std::mem::take(&mut state.borrow_mut().dismissed))
}

/// Exchanges Clarity state with the app. Called with the highlighter's regular config refresh.
pub fn sync_with_app<R, W>(client: &mut Client<R, W>, runtime: &TokioRuntime)
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let (turn_off, unreported_status) = HIGHLIGHTER.with(|state| {
        let state = state.borrow();
        let unreported = state
            .status
            .filter(|status| state.reported_status != Some(*status));
        (state.turn_off_requested, unreported)
    });

    runtime.block_on(async {
        // The request stays pending until the app confirms it, so a failed save is retried on the
        // next sync instead of being lost.
        if turn_off {
            match client
                .clarity(ClarityMessage::SetEnabled { enabled: false })
                .await
            {
                Ok(_) => HIGHLIGHTER.with(|state| state.borrow_mut().turn_off_requested = false),
                Err(error) => eprintln!("failed to turn off Clarity: {error}"),
            }
        }

        if let Some(status) = unreported_status {
            match client.clarity(ClarityMessage::SetStatus { status }).await {
                Ok(_) => {
                    HIGHLIGHTER.with(|state| state.borrow_mut().reported_status = Some(status))
                }
                Err(error) => eprintln!("failed to report Clarity status: {error}"),
            }
        }

        match client.clarity(ClarityMessage::GetEnabled).await {
            Ok(ClarityReply::Enabled { enabled }) => HIGHLIGHTER.with(|state| {
                let mut state = state.borrow_mut();
                // Until a turn-off is saved, the app still reports the old setting.
                if !state.turn_off_requested {
                    state.enabled = enabled;
                }
            }),
            Ok(_) => eprintln!("unexpected reply to a Clarity setting request"),
            Err(error) => eprintln!("failed to read the Clarity setting: {error}"),
        }
    });
}

/// What the settings window shows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaritySettingsView {
    pub enabled: bool,
    /// Whether the model can run now (it may still be paused to save power).
    pub available: bool,
    /// The status in plain words, such as "Unavailable: Apple Intelligence is turned off in
    /// System Settings".
    pub status: String,
}

impl ClaritySettingsView {
    pub fn new(settings: &ClaritySettings) -> Self {
        Self {
            enabled: settings.is_enabled(),
            available: !matches!(settings.status, Some(Availability::Unavailable(_))),
            status: describe(settings.status),
        }
    }
}

/// The status in plain words for the settings window.
pub fn describe(status: Option<Availability>) -> String {
    match status {
        None => "Checking: Harper hasn't heard from Apple Intelligence yet".to_owned(),
        Some(Availability::Available) => "Ready: suggestions run on this Mac".to_owned(),
        Some(Availability::Paused(PauseReason::LowPowerMode)) => {
            "Paused: Low Power Mode is on".to_owned()
        }
        Some(Availability::Paused(PauseReason::LowBattery)) => {
            "Paused: the battery is below 20%".to_owned()
        }
        Some(Availability::Unavailable(UnavailableReason::DeviceNotEligible)) => {
            "Unavailable: this Mac doesn't support Apple Intelligence".to_owned()
        }
        Some(Availability::Unavailable(UnavailableReason::AppleIntelligenceNotEnabled)) => {
            "Unavailable: Apple Intelligence is turned off in System Settings".to_owned()
        }
        Some(Availability::Unavailable(UnavailableReason::ModelNotReady)) => {
            "Unavailable: the Apple Intelligence model is still downloading".to_owned()
        }
        Some(Availability::Unavailable(UnavailableReason::UnsupportedOperatingSystem)) => {
            "Unavailable: Clarity needs macOS 27 or later".to_owned()
        }
    }
}

/// Adds the Clarity settings commands to the app's command handler.
pub fn with_commands<R: Runtime>(
    handler: impl Fn(Invoke<R>) -> bool,
) -> impl Fn(Invoke<R>) -> bool {
    let clarity_handler = clarity_command_handler::<R>();

    move |invoke| match invoke.message.command() {
        "get_clarity_settings" | "set_clarity_enabled" => clarity_handler(invoke),
        _ => handler(invoke),
    }
}

fn clarity_command_handler<R: Runtime>() -> impl Fn(Invoke<R>) -> bool {
    tauri::generate_handler![get_clarity_settings, set_clarity_enabled]
}

#[tauri::command]
async fn get_clarity_settings(
    config: State<'_, Arc<Mutex<Config>>>,
) -> Result<ClaritySettingsView, String> {
    Ok(ClaritySettingsView::new(&config.lock().await.clarity))
}

#[tauri::command]
async fn set_clarity_enabled(
    enabled: bool,
    config: State<'_, Arc<Mutex<Config>>>,
) -> Result<(), String> {
    let mut config = config.lock().await;
    config.clarity.enabled = Some(enabled);
    config
        .save_to_system()
        .await
        .map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clarity_is_on_until_the_user_turns_it_off() {
        assert!(ClaritySettings::default().is_enabled());
        assert!(
            !ClaritySettings {
                enabled: Some(false),
                status: None,
            }
            .is_enabled()
        );
    }

    #[test]
    fn saves_the_setting_but_not_the_status() {
        let settings = ClaritySettings {
            enabled: Some(false),
            status: Some(Availability::Available),
        };
        let json = serde_json::to_string(&settings).unwrap();

        assert_eq!(json, r#"{"enabled":false}"#);
        assert_eq!(
            serde_json::from_str::<ClaritySettings>(&json).unwrap(),
            ClaritySettings {
                enabled: Some(false),
                status: None,
            }
        );
    }

    #[test]
    fn describes_every_status_in_plain_words() {
        let unavailable = ClaritySettingsView::new(&ClaritySettings {
            enabled: None,
            status: Some(Availability::Unavailable(
                UnavailableReason::AppleIntelligenceNotEnabled,
            )),
        });

        assert_eq!(
            unavailable,
            ClaritySettingsView {
                enabled: true,
                available: false,
                status: "Unavailable: Apple Intelligence is turned off in System Settings"
                    .to_owned(),
            }
        );
        assert!(
            ClaritySettingsView::new(&ClaritySettings {
                enabled: None,
                status: Some(Availability::Paused(PauseReason::LowPowerMode)),
            })
            .available
        );
        assert!(describe(None).starts_with("Checking"));
    }

    #[test]
    fn messages_round_trip_as_json() {
        let message = ClarityMessage::SetStatus {
            status: Availability::Paused(PauseReason::LowBattery),
        };
        let json = serde_json::to_string(&message).unwrap();

        assert_eq!(
            serde_json::from_str::<ClarityMessage>(&json).unwrap(),
            message
        );
    }

    /// Status and setting travel between the highlighter (client) and the app (server).
    /// `SetEnabled` is left out because it saves the config to the user's real settings folder.
    #[tokio::test]
    async fn status_and_setting_travel_between_the_processes() {
        use crate::communication::{Request, Server};
        use tokio::io::duplex;

        let (client_request_writer, server_request_reader) = duplex(16_384);
        let (server_response_writer, client_response_reader) = duplex(16_384);
        let config = Arc::new(Mutex::new(Config::new()));
        let mut client = Client::new(client_response_reader, client_request_writer);
        let mut server = Server::new(
            server_request_reader,
            server_response_writer,
            config.clone(),
        );

        let status = Availability::Paused(PauseReason::LowPowerMode);
        let (reply, request) = tokio::join!(
            client.clarity(ClarityMessage::SetStatus { status }),
            server.receive_request()
        );
        assert_eq!(reply.unwrap(), ClarityReply::Ack);
        assert!(matches!(request.unwrap(), Some(Request::Clarity(_))));
        assert_eq!(config.lock().await.clarity.status, Some(status));

        let (reply, _) = tokio::join!(
            client.clarity(ClarityMessage::GetEnabled),
            server.receive_request()
        );
        assert_eq!(reply.unwrap(), ClarityReply::Enabled { enabled: true });
    }

    /// A turn-off that could not be saved stays pending, and Clarity stays off meanwhile.
    #[test]
    fn keeps_a_turn_off_that_failed_to_save() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        // The app never answers: every request fails.
        let mut client = Client::new(tokio::io::empty(), tokio::io::sink());

        turn_off();
        sync_with_app(&mut client, &runtime);

        assert!(HIGHLIGHTER.with(|state| state.borrow().turn_off_requested));
        assert!(!is_enabled());
    }

    #[test]
    fn turning_off_takes_effect_at_once() {
        assert!(is_enabled());
        turn_off();
        assert!(!is_enabled());
    }
}
