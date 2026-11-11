import Foundation
import Carbon

#if SATURN_BRIDGE
/// Carbon reserves only this key combination, without monitoring keyboard input.
@MainActor final class RecordingShortcut {
    static let shared = RecordingShortcut()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var held = false
    private var action: (@convention(c) () -> Void)?

    func register(_ callback: @escaping @convention(c) () -> Void) -> OSStatus {
        guard hotKey == nil else { return noErr }
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == 0x5354524E, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let shortcut = RecordingShortcut.shared
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                shortcut.held = false
            } else if !shortcut.held {
                shortcut.held = true
                shortcut.action?()
            }
            return noErr
        }, events.count, &events, nil, &handler)
        guard installed == noErr else { return installed }
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey),
                                            EventHotKeyID(signature: 0x5354524E, id: 1), GetApplicationEventTarget(),
                                            OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registered == noErr else {
            unregister()
            return registered
        }
        action = callback
        return noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil; action = nil; held = false
    }
}

@_cdecl("saturn_register_recording_shortcut")
func registerRecordingShortcut(_ callback: @escaping @convention(c) () -> Void) -> Int32 {
    // Tauri setup runs on the application's main thread.
    return MainActor.assumeIsolated { RecordingShortcut.shared.register(callback) }
}

@_cdecl("saturn_unregister_recording_shortcut")
func unregisterRecordingShortcut() {
    MainActor.assumeIsolated { RecordingShortcut.shared.unregister() }
}
#endif

