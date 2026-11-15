import Foundation
import AppKit
import Carbon

private var invocations = 0
private var pauses = 0
private func paused() { pauses += 1 }
private func invoked() { invocations += 1 }

@main struct RecordingShortcutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        // Isolate test reservations from a running Saturn app's production shortcuts.
        let modifiers = UInt32(controlKey | optionKey | cmdKey | shiftKey)
        func register() -> OSStatus {
            RecordingShortcut.shared.register(invoked, pause: paused, modifiers: modifiers)
        }
        // An existing reservation must fail visibly and leave no handler behind.
        var conflict: EventHotKeyRef?
        precondition(RegisterEventHotKey(UInt32(kVK_ANSI_R), modifiers,
                                        EventHotKeyID(signature: 2, id: 2), GetApplicationEventTarget(),
                                        OptionBits(kEventHotKeyExclusive), &conflict) == noErr)
        precondition(register() != noErr)
        precondition(UnregisterEventHotKey(conflict) == noErr)
        precondition(register() == noErr)

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
        send(UInt32(kEventHotKeyPressed), id: 2)
        send(UInt32(kEventHotKeyPressed), id: 2)
        precondition(pauses == 1, "Holding pause must toggle only once")
        send(UInt32(kEventHotKeyReleased), id: 2)
        send(UInt32(kEventHotKeyPressed), id: 2)
        precondition(pauses == 2 && invocations == 2, "Pause and recording shortcuts must be independent")
        unregisterRecordingShortcut()
        send(UInt32(kEventHotKeyReleased))
        send(UInt32(kEventHotKeyPressed))
        send(UInt32(kEventHotKeyReleased), id: 2)
        send(UInt32(kEventHotKeyPressed), id: 2)
        precondition(invocations == 2 && pauses == 2, "Cleanup must remove both callbacks")
        precondition(register() == noErr)
        send(UInt32(kEventHotKeyPressed))
        precondition(invocations == 3, "Cleanup must release the key and held state")
        unregisterRecordingShortcut()
        precondition(RegisterEventHotKey(UInt32(kVK_ANSI_P), modifiers,
                                        EventHotKeyID(signature: 2, id: 3), GetApplicationEventTarget(),
                                        OptionBits(kEventHotKeyExclusive), &conflict) == noErr)
        precondition(register() != noErr, "Pause conflicts must be reported")
        precondition(UnregisterEventHotKey(conflict) == noErr)
        precondition(register() == noErr, "A pause conflict must release the recording reservation too")
        unregisterRecordingShortcut()
        print("Recording shortcuts passed: R/P callbacks, conflicts, independent key repeats, release, cleanup, re-registration.")
    }
}
