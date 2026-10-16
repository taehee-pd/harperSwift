// Added in this fork (taehee-pd/harperSwift).

import AppKit
import SwiftUI

/// Opens the native windows, one of each, and keeps Harper in the Dock only while one is open,
/// the way the web view windows did. Harper otherwise lives in the menu bar.
@MainActor
enum AppWindows {
    enum Kind {
        case settings
        case setup
        case editor
    }

    enum Chrome {
        /// Content under a unified toolbar that shows the SwiftUI title, like System Settings.
        case sidebar
        /// No visible title bar, like a setup assistant.
        case assistant
        /// A standard title bar, like TextEdit.
        case plain
    }

    private static var windows: [Kind: NSWindow] = [:]
    private static let delegate = Delegate()

    /// Settings, or the first-run setup while it is not done.
    static func showSettingsOrSetup() {
        if let window = windows[.settings] ?? windows[.setup] {
            bringForward(window)
            return
        }
        Task {
            let snapshot = try? await NativeBridge.request("settings.load", as: SettingsSnapshot.self)
            if snapshot?.onboardingCompleted == false {
                showSetup()
            } else {
                showSettings()
            }
        }
    }

    static func showSettings() {
        present(.settings, title: "Harper Settings", size: NSSize(width: 780, height: 600), resizable: true, chrome: .sidebar) {
            SettingsView(model: SettingsModel())
        }
    }

    static func showSetup() {
        present(.setup, title: "Welcome to Harper", size: NSSize(width: 620, height: 470), resizable: false, chrome: .assistant) {
            SetupView(model: SetupModel())
        }
    }

    static func showEditor() {
        present(.editor, title: "Harper Editor", size: NSSize(width: 960, height: 680), resizable: true, chrome: .plain) {
            EditorView(model: EditorModel())
        }
    }

    static func close(_ kind: Kind) {
        windows[kind]?.close()
    }

    private static func present(
        _ kind: Kind,
        title: String,
        size: NSSize,
        resizable: Bool,
        chrome: Chrome,
        content: () -> some View
    ) {
        if let window = windows[kind] {
            bringForward(window)
            return
        }

        let window = makeWindow(title: title, size: size, resizable: resizable, chrome: chrome, content: content)
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.setFrameAutosaveName("Harper.\(kind)")
        if !window.setFrameUsingName("Harper.\(kind)") {
            window.center()
        }

        windows[kind] = window
        bringForward(window)
    }

    /// A window hosting `content` with the given chrome.
    static func makeWindow(
        title: String,
        size: NSSize,
        resizable: Bool,
        chrome: Chrome,
        content: () -> some View
    ) -> NSWindow {
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = [.minSize]
        if chrome == .sidebar, #available(macOS 14, *) {
            controller.sceneBridgingOptions = [.toolbars]
        }

        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        if resizable {
            window.styleMask.insert(.resizable)
        }

        switch chrome {
        case .sidebar:
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unified
            if #unavailable(macOS 14) {
                // Without bridging, an empty toolbar still gives the tall unified title bar.
                window.toolbar = NSToolbar(identifier: "Harper.\(title)")
                window.titleVisibility = .hidden
            }
        case .assistant:
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        case .plain:
            break
        }

        window.setContentSize(size)
        return window
    }

    private static func bringForward(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    fileprivate static func didClose(_ window: NSWindow) {
        windows = windows.filter { $0.value !== window }
        if windows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { AppWindows.didClose(window) }
        }
    }
}
