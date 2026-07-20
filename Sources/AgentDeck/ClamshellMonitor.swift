import Foundation
import IOKit
import IOKit.pwr_mgt

/// Watches the laptop lid (clamshell) state and invokes `onClosed` whenever the
/// lid is shut. Needed because with `SleepDisabled` set, closing the lid no
/// longer sleeps the machine — and the internal panel can stay backlit — so we
/// force the display off ourselves on lid close.
@MainActor
final class ClamshellMonitor {
    private let onClosed: () -> Void
    private var notifyPort: IONotificationPortRef?
    private var interest: io_object_t = 0
    private var rootDomain: io_service_t = 0
    private var wasClosed = false

    init(onClosed: @escaping () -> Void) {
        self.onClosed = onClosed
    }

    func start() {
        guard rootDomain == 0 else { return }   // already running
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return }

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort else { return }
        let source = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        // Pass `self` as the callback's refcon so each monitor gets its own
        // callbacks (no fragile shared singleton). Unretained is safe: the owner
        // keeps this instance alive for the whole registration, and stop()
        // unregisters before it can be deallocated. We ignore the message type and
        // detect the lid open→closed transition from the registry state (the
        // clamshell-change message constant isn't exposed to Swift).
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(
            notifyPort,
            rootDomain,
            kIOGeneralInterest,
            { refcon, _, _, _ in
                guard let refcon else { return }
                // Sound: the notify port's run-loop source is added to
                // CFRunLoopGetMain() (see start() above), so IOKit delivers
                // this callback on the main thread — main-actor isolation is
                // genuinely guaranteed, the C function pointer just can't
                // express it.
                MainActor.assumeIsolated {
                    Unmanaged<ClamshellMonitor>.fromOpaque(refcon).takeUnretainedValue().handleInterest()
                }
            },
            ctx,
            &interest
        )

        wasClosed = isClosed()
    }

    func stop() {
        if interest != 0 { IOObjectRelease(interest); interest = 0 }
        if let notifyPort {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
                                  .defaultMode)
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
        if rootDomain != 0 { IOObjectRelease(rootDomain); rootDomain = 0 }
    }

    /// True when the lid is currently shut.
    func isClosed() -> Bool {
        guard rootDomain != 0 else { return false }
        guard let value = IORegistryEntryCreateCFProperty(
            rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return false }
        return (value as? Bool) ?? false
    }

    // MARK: - C-callback bridging

    /// Fire `onClosed` only on the open→closed transition (ignoring the many other
    /// general-interest messages that also arrive on IOPMrootDomain).
    private func handleInterest() {
        let closed = isClosed()
        defer { wasClosed = closed }
        if closed && !wasClosed { onClosed() }
    }
}
