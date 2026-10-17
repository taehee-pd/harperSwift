//! Added in this fork (taehee-pd/harperSwift).
//!
//! Harper looks for Accessibility access only at launch, so a user who allowed it afterwards saw
//! nothing happen until they reopened Harper. That includes everyone whose access an update reset
//! (macOS ties the permission to the app's signature). This waits for the access in the background
//! and starts checking as soon as it is there.

use std::sync::{Arc, RwLock};
use std::thread;
use std::time::Duration;

use tauri::{AppHandle, Manager};
use tokio::sync::Mutex;

use crate::PlatformBroker;
use crate::config::Config;
use crate::highlighter_service::HighlighterService;
use crate::os_broker::{AccessibilityPermissionStatus, OsBroker};

const POLL_INTERVAL: Duration = Duration::from_secs(2);

/// Starts checking once Accessibility access is granted, unless the user turned checking off by
/// then.
pub fn start_checking_when_granted(app: AppHandle) {
    thread::spawn(move || {
        while !is_granted(&app) {
            thread::sleep(POLL_INTERVAL);
        }

        let enabled = app
            .state::<Arc<Mutex<Config>>>()
            .blocking_lock()
            .highlighter_service_enabled;
        if enabled && let Err(error) = app.state::<HighlighterService>().start() {
            eprintln!("failed to start checking after Accessibility access was granted: {error}");
        }
    });
}

pub fn is_granted(app: &AppHandle) -> bool {
    app.state::<RwLock<PlatformBroker>>()
        .read()
        .is_ok_and(|broker| {
            broker.accessibility_permission_status() == AccessibilityPermissionStatus::Granted
        })
}
