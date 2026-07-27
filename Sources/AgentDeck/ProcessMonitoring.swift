import Darwin
import Dispatch
import Foundation

/// Stable identity for one generation of a process. macOS can recycle a PID,
/// so lifecycle ownership always compares the PID and kernel-recorded start
/// time together.
struct ProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

/// Process inspection deliberately distinguishes "gone" from "could not
/// inspect". Permission or transient inspection failures are never treated as
/// proof that an agent ended; SessionEnd/stale pruning remain the fallback.
enum ProcessLookupResult: Equatable, Sendable {
    case running(ProcessIdentity)
    case notFound
    case unavailable(error: Int32)
}

protocol ProcessIdentityResolving: Sendable {
    func identity(for pid: pid_t) -> ProcessLookupResult
}

/// Resolves a PID to its kernel start-time fingerprint using libproc.
struct DarwinProcessIdentityResolver: ProcessIdentityResolving {
    func identity(for pid: pid_t) -> ProcessLookupResult {
        guard pid > 1 else { return .notFound }

        var info = proc_bsdinfo()
        let expectedBytes = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let bytes = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedBytes
        )

        if bytes == expectedBytes {
            if info.pbi_status == UInt32(SZOMB) {
                return .notFound
            }
            return .running(ProcessIdentity(
                pid: pid,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            ))
        }

        let inspectionError = errno
        errno = 0
        if kill(pid, 0) == -1 {
            let existenceError = errno
            if existenceError == ESRCH { return .notFound }
            return .unavailable(error: existenceError)
        }
        return .unavailable(error: inspectionError)
    }
}

@MainActor
protocol ProcessObservation: AnyObject {
    func cancel()
}

@MainActor
protocol ProcessExitObserving: AnyObject {
    func observe(
        _ identity: ProcessIdentity,
        onExit: @escaping @MainActor @Sendable (ProcessIdentity) -> Void
    ) -> any ProcessObservation
}

/// Creates one EVFILT_PROC/NOTE_EXIT dispatch source per observed agent.
/// Dispatch binds the source to the registered process generation; the
/// post-activation resolver check closes the remaining exit/PID-reuse race.
@MainActor
final class DispatchProcessExitObserver: ProcessExitObserving {
    private let resolver: any ProcessIdentityResolving

    init(resolver: any ProcessIdentityResolving) {
        self.resolver = resolver
    }

    func observe(
        _ identity: ProcessIdentity,
        onExit: @escaping @MainActor @Sendable (ProcessIdentity) -> Void
    ) -> any ProcessObservation {
        DispatchProcessObservation(identity: identity, resolver: resolver, onExit: onExit)
    }
}

@MainActor
private final class DispatchProcessObservation: ProcessObservation {
    private let identity: ProcessIdentity
    private let resolver: any ProcessIdentityResolving
    private let onExit: @MainActor @Sendable (ProcessIdentity) -> Void
    private var source: DispatchSourceProcess?
    private var isFinished = false

    init(
        identity: ProcessIdentity,
        resolver: any ProcessIdentityResolving,
        onExit: @escaping @MainActor @Sendable (ProcessIdentity) -> Void
    ) {
        self.identity = identity
        self.resolver = resolver
        self.onExit = onExit

        let source = DispatchSource.makeProcessSource(
            identifier: identity.pid,
            eventMask: .exit,
            queue: .main
        )
        self.source = source
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish()
            }
        }
        source.setRegistrationHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.validateRegisteredProcess()
            }
        }
        source.activate()

        // Also catch a process that vanished before Dispatch could register
        // the source at all. The registration-handler validation remains
        // necessary for an exit that occurs after this check but before
        // registration completes.
        Task { @MainActor [weak self] in
            self?.validateRegisteredProcess()
        }
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        source?.cancel()
        source = nil
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        source?.cancel()
        source = nil
        onExit(identity)
    }

    /// Dispatch only guarantees exit delivery after the process source has
    /// registered. Re-checking from the registration handler closes both the
    /// pre-registration exit gap and the PID-reuse gap.
    private func validateRegisteredProcess() {
        guard !isFinished else { return }
        switch resolver.identity(for: identity.pid) {
        case .running(let current) where current == identity:
            break
        case .unavailable:
            // Inspection failure is not proof of death. The now-registered
            // dispatch source remains armed and will deliver a real exit.
            break
        case .running, .notFound:
            finish()
        }
    }

    isolated deinit {
        cancel()
    }
}
