import AppKit
import Carbon

/// Registered hot keys work while another app has focus, without monitoring its keystrokes.
@MainActor
final class GlobalShortcuts {
    private var handler: EventHandlerRef?
    private var recordKey: EventHotKeyRef?
    private var frameKey: EventHotKeyRef?
    private let toggleRecording: () -> Void
    private let toggleFrame: () -> Void

    init(toggleRecording: @escaping () -> Void, toggleFrame: @escaping () -> Void) {
        self.toggleRecording = toggleRecording
        self.toggleFrame = toggleFrame
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            // Carbon dispatches application hot keys on the main event loop.
            MainActor.assumeIsolated {
                if identifier.id == 1 { shortcuts.toggleRecording() }
                if identifier.id == 2 { shortcuts.toggleFrame() }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let signature: OSType = 0x5643414D // VCAM
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey),
                            EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &recordKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(cmdKey | shiftKey),
                            EventHotKeyID(signature: signature, id: 2), GetApplicationEventTarget(), 0, &frameKey)
    }

    deinit {
        if let recordKey { UnregisterEventHotKey(recordKey) }
        if let frameKey { UnregisterEventHotKey(frameKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
