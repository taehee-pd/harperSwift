//! Added in this fork (taehee-pd/harperSwift).
//!
//! Native SwiftUI windows on macOS: Settings (which shows the first-run setup until it is done)
//! and the editor. They replace the web view windows there; the web UI stays for other platforms.
//!
//! The windows live in `harper-desktop/macos-popup` and talk to this module through
//! [`dispatch`]: each request is `{"method": ..., "params": ...}` and is answered with
//! `{"ok": value}` or `{"error": message}`. Handlers change the same [`crate::config::Config`] the
//! Tauri commands do, and save it the same way.

mod editor;
mod ffi;
mod settings;

use std::sync::OnceLock;

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use tauri::AppHandle;

static APP: OnceLock<AppHandle> = OnceLock::new();

/// Connects the native windows to the app. Call once from Tauri's `setup`.
pub fn set_up(app: &AppHandle) -> tauri::Result<()> {
    let _ = APP.set(app.clone());
    app.run_on_main_thread(ffi::install_request_handler)
}

/// Opens Settings, or the first-run setup if it is not done yet. Safe from any thread.
pub fn show_settings(app: &AppHandle) -> tauri::Result<()> {
    app.run_on_main_thread(ffi::show_settings)
}

/// Opens the editor. Safe from any thread.
pub fn show_editor(app: &AppHandle) -> tauri::Result<()> {
    app.run_on_main_thread(ffi::show_editor)
}

#[derive(Deserialize)]
struct Request {
    method: String,
    #[serde(default)]
    params: Value,
}

/// Runs a request from Swift off the main thread and answers on the main thread. Every request
/// gets an answer, or the Swift caller would wait forever.
fn dispatch(id: u64, request: String) {
    let Some(app) = APP.get().cloned() else {
        // Called on the main thread, so the answer can go back at once.
        ffi::respond(id, &json!({ "error": "Harper is still starting." }).to_string());
        return;
    };

    tauri::async_runtime::spawn(async move {
        let reply = match serde_json::from_str::<Request>(&request) {
            Ok(request) => handle(&app, &request.method, &request.params).await,
            Err(error) => Err(format!("Invalid request: {error}")),
        };
        let json = match reply {
            Ok(value) => json!({ "ok": value }),
            Err(error) => json!({ "error": error }),
        }
        .to_string();

        if let Err(error) = app.run_on_main_thread(move || ffi::respond(id, &json)) {
            eprintln!("failed to answer a native window request: {error}");
        }
    });
}

async fn handle(app: &AppHandle, method: &str, params: &Value) -> Result<Value, String> {
    if let Some(reply) = settings::handle(app, method, params).await {
        return reply;
    }
    if let Some(reply) = editor::handle(app, method, params).await {
        return reply;
    }
    Err(format!("Unknown request: {method}"))
}

/// Reads one named parameter.
fn param<T: DeserializeOwned>(params: &Value, name: &str) -> Result<T, String> {
    let value = params.get(name).cloned().unwrap_or(Value::Null);
    serde_json::from_value(value).map_err(|error| format!("Invalid parameter `{name}`: {error}"))
}

/// Turns a handler's result into the reply JSON.
fn reply<T: serde::Serialize>(result: Result<T, String>) -> Option<Result<Value, String>> {
    Some(result.and_then(|value| serde_json::to_value(value).map_err(|error| error.to_string())))
}
