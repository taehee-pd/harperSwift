// Added in this fork (taehee-pd/harperSwift).

import AppKit

/// Adds what every Apple app has in its menu bar and Tauri's default menu lacks: Settings… (⌘,)
/// in the app menu, and Find (⌘F, ⌘G, ⌘E) in the Edit menu for the editor. Safe to call again.
@MainActor
enum AppMenu {
    private static let marker = NSUserInterfaceItemIdentifier("Harper.AppMenu")
    private static let target = Target()

    static func install() {
        guard let menu = NSApp.mainMenu else { return }

        if let appMenu = menu.items.first?.submenu, !contains(appMenu) {
            let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(Target.showSettings), keyEquivalent: ",")
            settings.target = target
            settings.identifier = marker
            // Below About Harper and its separator, above Services.
            let index = min(2, appMenu.items.count)
            appMenu.insertItem(settings, at: index)
            appMenu.insertItem(.separator(), at: index + 1)
        }

        if let edit = menu.items.first(where: { $0.title == "Edit" })?.submenu, !contains(edit) {
            let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
            find.identifier = marker
            find.submenu = findMenu()
            edit.addItem(.separator())
            edit.addItem(find)
        }
    }

    private static func contains(_ menu: NSMenu) -> Bool {
        menu.items.contains { $0.identifier == marker }
    }

    /// The text view runs these itself through its find bar, and disables them elsewhere.
    private static func findMenu() -> NSMenu {
        func item(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags, _ action: NSTextFinder.Action) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = action.rawValue
            return item
        }

        let menu = NSMenu(title: "Find")
        menu.addItem(item("Find\u{2026}", "f", .command, .showFindInterface))
        menu.addItem(item("Find and Replace\u{2026}", "f", [.command, .option], .showReplaceInterface))
        menu.addItem(item("Find Next", "g", .command, .nextMatch))
        menu.addItem(item("Find Previous", "g", [.command, .shift], .previousMatch))
        menu.addItem(item("Use Selection for Find", "e", .command, .setSearchString))
        return menu
    }

    private final class Target: NSObject {
        @objc func showSettings() {
            MainActor.assumeIsolated { AppWindows.showSettingsOrSetup() }
        }
    }
}
