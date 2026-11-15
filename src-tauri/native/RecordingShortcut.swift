import Foundation
import Carbon

#if SATURN_BRIDGE
/// Carbon reserves only these key combinations, without monitoring keyboard input.
@MainActor final class RecordingShortcut {
    static let shared = RecordingShortcut()
    private var hotKey: EventHotKeyRef?
    private var pauseHotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var held: Set<UInt32> = []
    private var action: (@convention(c) () -> Void)?

    private var pauseAction: (@convention(c) () -> Void)?

    func register(_ callback: @escaping @convention(c) () -> Void, pause: @escaping @convention(c) () -> Void, modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)) -> OSStatus {
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
            guard status == noErr, id.signature == 0x5354524E, [1, 2].contains(id.id) else { return OSStatus(eventNotHandledErr) }
            let shortcut = RecordingShortcut.shared
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                shortcut.held.remove(id.id)
            } else if shortcut.held.insert(id.id).inserted {
                if id.id == 1 { shortcut.action?() } else { shortcut.pauseAction?() }
            }
            return noErr
        }, events.count, &events, nil, &handler)
        guard installed == noErr else { return installed }
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_R), modifiers,
                                            EventHotKeyID(signature: 0x5354524E, id: 1), GetApplicationEventTarget(),
                                            OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registered == noErr else {
            unregister()
            return registered
        }
        let pauseRegistered = RegisterEventHotKey(UInt32(kVK_ANSI_P), modifiers,
                                                 EventHotKeyID(signature: 0x5354524E, id: 2), GetApplicationEventTarget(),
                                                 OptionBits(kEventHotKeyExclusive), &pauseHotKey)
        guard pauseRegistered == noErr else {
            unregister()
            return pauseRegistered
        }
        action = callback; pauseAction = pause
        return noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let pauseHotKey { UnregisterEventHotKey(pauseHotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; pauseHotKey = nil; handler = nil; action = nil; pauseAction = nil; held.removeAll()
    }
}

@_cdecl("saturn_register_recording_shortcut")
func registerRecordingShortcut(_ callback: @escaping @convention(c) () -> Void, _ pause: @escaping @convention(c) () -> Void) -> Int32 {
    // Tauri setup runs on the application's main thread.
    return MainActor.assumeIsolated { RecordingShortcut.shared.register(callback, pause: pause) }
}

@_cdecl("saturn_unregister_recording_shortcut")
func unregisterRecordingShortcut() {
    MainActor.assumeIsolated { RecordingShortcut.shared.unregister() }
}
#endif

