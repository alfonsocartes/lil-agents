import AppKit
import Carbon.HIToolbox

/// Registers a single system-wide hotkey via Carbon's `RegisterEventHotKey`.
///
/// Carbon hotkeys are the right tool here: they work globally without the
/// Accessibility (TCC) permission that an `NSEvent` global monitor would require,
/// and they fire even while another app is focused — exactly what's needed to
/// summon a hidden overlay from inside iTerm2.
final class HotKeyCenter {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    private let signature: OSType = 0x41474454 // 'AGDT'
    private let hotKeyID: UInt32 = 1

    /// Register (replacing any previous registration). `handler` is always called
    /// on the main thread. Returns false if the OS refused the registration
    /// (e.g. the combo is already claimed by another app).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        unregister()
        self.handler = handler

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var received = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &received
            )
            if received.id == center.hotKeyID {
                DispatchQueue.main.async { center.handler?() }
            }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)

        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit { unregister() }
}
