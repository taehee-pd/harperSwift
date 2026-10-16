// Added in this fork (taehee-pd/harperSwift).

import Carbon.HIToolbox

/// Control-Command-Y accepts the popup's first suggestion. The shortcut is registered only while
/// the popup is open, so other apps keep it the rest of the time. A system hot key works without
/// Harper being the active app, which the popup never is.
@MainActor
final class AcceptShortcut {
    /// Shown next to the action it triggers.
    static let symbols = "\u{2303}\u{2318}Y"

    private static let id = EventHotKeyID(signature: 0x4852_5052 /* "HRPR" */, id: 1)
    private static var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(onPress: @escaping () -> Void) {
        Self.onPress = onPress
    }

    func enable() {
        guard hotKey == nil else { return }
        installHandlerIfNeeded()

        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_Y),
            UInt32(cmdKey | controlKey),
            Self.id,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if status != noErr {
            hotKey = nil
        }
    }

    func disable() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                )
                guard status == noErr, pressed.signature == AcceptShortcut.id.signature,
                      pressed.id == AcceptShortcut.id.id else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon delivers hot keys on the main thread.
                MainActor.assumeIsolated { AcceptShortcut.onPress?() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handler
        )
    }
}
