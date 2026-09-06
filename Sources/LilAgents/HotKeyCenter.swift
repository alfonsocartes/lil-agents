import AppKit
import Carbon.HIToolbox

/// Registers a single system-wide hotkey via Carbon's `RegisterEventHotKey`.
///
/// Carbon hotkeys are the right tool here: they work globally without the
/// Accessibility (TCC) permission that an `NSEvent` global monitor would require,
/// and they fire even while another app is focused — exactly what's needed to
/// summon a hidden overlay from inside iTerm2.
@MainActor
final class HotKeyCenter {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    private let signature: OSType = 0x41474454 // 'AGDT'
    // Accessed from the nonisolated C callback below — legal because it's an
    // immutable Sendable `let` (nonisolated access to such storage is allowed).
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

        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
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
                // Carbon application-target handlers run on the main thread;
                // invoke synchronously so an App-Napped accessory app actually
                // toggles the overlay instead of scheduling an unstructured
                // Task that may never run. The else branch is defensive.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { center.handler?() }
                } else {
                    DispatchQueue.main.async { center.handler?() }
                }
            }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)

        guard handlerStatus == noErr else {
            // The handler never got installed, so there's nothing for a
            // hotkey registration to call into — don't register one, and
            // don't leave a dangling `eventHandler` around for `unregister()`
            // to trip over (InstallEventHandler leaves the out-param
            // untouched on failure, so it's already nil here).
            return false
        }

        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            // The hotkey itself was refused (e.g. combo already claimed) —
            // tear down the handler we just installed so this call leaves no
            // half-registered state behind for `unregister()` to find later.
            unregister()
            return false
        }
        return true
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

    // `isolated deinit`: runs on the main actor, so it can call `unregister()`
    // (which touches @MainActor state). The only owner is AppDelegate — itself
    // main-actor — so in practice deallocation happens there anyway.
    isolated deinit { unregister() }
}
