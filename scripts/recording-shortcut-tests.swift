import Foundation
import AppKit
import Carbon

private var invocations = 0
private func invoked() { invocations += 1 }

@main struct RecordingShortcutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        // An existing reservation must fail visibly and leave no handler behind.
        var conflict: EventHotKeyRef?
        precondition(RegisterEventHotKey(UInt32(kVK_ANSI_R), modifiers,
                                        EventHotKeyID(signature: 2, id: 2), GetApplicationEventTarget(),
                                        OptionBits(kEventHotKeyExclusive), &conflict) == noErr)
        precondition(registerRecordingShortcut(invoked) != noErr)
        precondition(UnregisterEventHotKey(conflict) == noErr)
        precondition(registerRecordingShortcut(invoked) == noErr)

        func send(_ kind: UInt32, id: UInt32 = 1) {
            var event: EventRef?
            precondition(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event) == noErr)
            defer { ReleaseEvent(event) }
            var identifier = EventHotKeyID(signature: 0x5354524E, id: id)
            precondition(SetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size,
                                          &identifier) == noErr)
            _ = SendEventToEventTarget(event, GetApplicationEventTarget())
        }
        send(UInt32(kEventHotKeyPressed), id: 99)
        precondition(invocations == 0, "Unrelated hotkeys must pass through")
        send(UInt32(kEventHotKeyPressed))
        send(UInt32(kEventHotKeyPressed))
        precondition(invocations == 1, "Holding the key must toggle only once")
        send(UInt32(kEventHotKeyReleased))
        send(UInt32(kEventHotKeyPressed))
        precondition(invocations == 2, "The next press must toggle again")
        unregisterRecordingShortcut()
        send(UInt32(kEventHotKeyReleased))
        send(UInt32(kEventHotKeyPressed))
        precondition(invocations == 2, "Cleanup must remove the callback")
        precondition(registerRecordingShortcut(invoked) == noErr)
        send(UInt32(kEventHotKeyPressed))
        precondition(invocations == 3, "Cleanup must release the key and held state")
        unregisterRecordingShortcut()
        print("Recording shortcut passed: conflict, unrelated keys, repeats, release, cleanup, re-registration.")
    }
}
