// Added in this fork (taehee-pd/harperSwift).

import AppKit
import ServiceManagement

// Open at login, registered as Harper itself. macOS then names Harper, with its icon, in the
// background item notice and in System Settings › General › Login Items; a launch agent file
// is shown under the developer's name instead.

@_cdecl("harper_login_item_is_enabled")
public func harperLoginItemIsEnabled() -> Bool {
    SMAppService.mainApp.status == .enabled
}

/// 0: done. 1: Harper is registered but the user must allow it in System Settings, which happens
/// after they turned it off there. 2: macOS refused; the reason goes to standard error.
@_cdecl("harper_login_item_set_enabled")
public func harperLoginItemSetEnabled(_ enabled: Bool) -> Int32 {
    let service = SMAppService.mainApp
    do {
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    } catch {
        FileHandle.standardError.write(Data("Unable to change the login item: \(error.localizedDescription)\n".utf8))
    }

    switch (enabled, service.status) {
    case (true, .enabled), (false, .notRegistered), (false, .notFound): return 0
    case (true, .requiresApproval): return 1
    default: return 2
    }
}

@_cdecl("harper_login_item_open_settings")
public func harperLoginItemOpenSettings() {
    DispatchQueue.main.async { SMAppService.openSystemSettingsLoginItems() }
}
