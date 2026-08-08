import Foundation
import ServiceManagement
import Testing
@testable import AgentDeck

// MARK: - Fake backend

/// Stands in for `SMAppServiceLoginItemBackend` so tests never touch the real
/// login-item registry — registering/unregistering for real would actually
/// add/remove this repo's build product from the developer's login items
/// every time the suite runs.
///
/// `register()`/`unregister()` mimic `SMAppService`'s real behavior on
/// success: they flip `status` to the resulting state. On a thrown error
/// (`errorToThrow` set) `status` is left untouched, matching a real
/// "already registered"/"already unregistered" failure that changes nothing.
@MainActor
private final class FakeLoginItemBackend: LoginItemBackend {
    var isAvailable = true
    var status: SMAppService.Status = .notRegistered
    var errorToThrow: Error?

    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSystemSettingsCallCount = 0

    func register() throws {
        registerCallCount += 1
        if let errorToThrow { throw errorToThrow }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let errorToThrow { throw errorToThrow }
        status = .notRegistered
    }

    func openSystemSettings() {
        openSystemSettingsCallCount += 1
    }
}

private struct FakeError: Error, LocalizedError {
    var errorDescription: String? { "fake backend error" }
}

// MARK: - Tests

@MainActor
@Suite struct LoginItemControllerTests {
    @Test func togglingOnRegistersAndReadsBackAsEnabled() {
        withScratchDefaults { defaults in
            let backend = FakeLoginItemBackend()
            let controller = LoginItemController(backend: backend, defaults: defaults)

            controller.isEnabled = true

            #expect(backend.registerCallCount == 1)
            #expect(backend.unregisterCallCount == 0)
            #expect(controller.isEnabled == true)
        }
    }

    @Test func togglingOffUnregistersAndReadsBackAsDisabled() {
        withScratchDefaults { defaults in
            let backend = FakeLoginItemBackend()
            backend.status = .enabled
            let controller = LoginItemController(backend: backend, defaults: defaults)
            #expect(controller.isEnabled == true)

            controller.isEnabled = false

            #expect(backend.unregisterCallCount == 1)
            #expect(controller.isEnabled == false)
        }
    }

    @Test func registerThrowingWhileStillNotRegisteredSurfacesTheError() {
        withScratchDefaults { defaults in
            let backend = FakeLoginItemBackend()
            backend.errorToThrow = FakeError()
            let controller = LoginItemController(backend: backend, defaults: defaults)

            controller.isEnabled = true

            #expect(backend.registerCallCount == 1)
            #expect(controller.isEnabled == false)
            #expect(controller.lastError != nil)
        }
    }

    @Test func lastErrorIsClearedOnALaterSuccess() {
        withScratchDefaults { defaults in
            let backend = FakeLoginItemBackend()
            backend.errorToThrow = FakeError()
            let controller = LoginItemController(backend: backend, defaults: defaults)

            controller.isEnabled = true
            #expect(controller.lastError != nil)

            backend.errorToThrow = nil
            controller.isEnabled = true

            #expect(controller.isEnabled == true)
            #expect(controller.lastError == nil)
        }
    }

    @Test func refreshClearsAStaleLastErrorEvenWithoutTogglingAgain() {
        withScratchDefaults { defaults in
            let backend = FakeLoginItemBackend()
            backend.errorToThrow = FakeError()
            let controller = LoginItemController(backend: backend, defaults: defaults)
            controller.isEnabled = true
            #expect(controller.lastError != nil)

            // Mirrors the user fixing it by hand in System Settings rather
            // than retrying the toggle: only `status` moves, `lastError` is
            // never touched by anything except a bare `refresh()` call.
            backend.status = .enabled

            controller.refresh()

            #expect(controller.lastError == nil)
        }
    }

    @Test func openSystemSettingsCallsThroughToBackend() {
        withScratchDefaults { defaults in
            let backend = FakeLoginItemBackend()
            backend.status = .requiresApproval
            let controller = LoginItemController(backend: backend, defaults: defaults)

            controller.openSystemSettings()

            #expect(backend.openSystemSettingsCallCount == 1)
        }
    }

    @Test func registerThrowingAlreadyRegisteredIsBenign() {
        withScratchDefaults { defaults in
            let backend = FakeLoginItemBackend()
            backend.status = .enabled
            backend.errorToThrow = FakeError()
            let controller = LoginItemController(backend: backend, defaults: defaults)

            controller.isEnabled = true

            #expect(backend.registerCallCount == 1)
            #expect(controller.isEnabled == true)
            #expect(controller.lastError == nil)
        }
    }

    @Test func requiresApprovalCountsAsEnabledAndNeedsApproval() {
        withScratchDefaults { defaults in
            let backend = FakeLoginItemBackend()
            backend.status = .requiresApproval
            let controller = LoginItemController(backend: backend, defaults: defaults)

            #expect(controller.isEnabled == true)
            #expect(controller.needsApproval == true)
        }
    }

    @Test func unavailableBackendMakesTheSetterANoOp() {
        withScratchDefaults { defaults in
            let backend = FakeLoginItemBackend()
            backend.isAvailable = false
            let controller = LoginItemController(backend: backend, defaults: defaults)
            let statusBefore = controller.status

            controller.isEnabled = true

            #expect(backend.registerCallCount == 0)
            #expect(backend.unregisterCallCount == 0)
            #expect(controller.status == statusBefore)
        }
    }

    @Test func firstLaunchPromptFiresOnceEverAcrossControllerInstances() {
        withScratchDefaults { defaults in
            let backend = FakeLoginItemBackend()
            let controller = LoginItemController(backend: backend, defaults: defaults)

            #expect(controller.consumeFirstLaunchPrompt() == true)
            #expect(controller.consumeFirstLaunchPrompt() == false)

            // A freshly constructed controller sharing the same defaults must
            // see the flag already set — the one-shot survives process/instance
            // boundaries, not just repeat calls on the same object.
            let secondController = LoginItemController(backend: backend, defaults: defaults)
            #expect(secondController.consumeFirstLaunchPrompt() == false)
        }
    }

    @Test func firstLaunchPromptDoesNotFireWhenUnavailableOrAlreadyEnabled() {
        withScratchDefaults { defaults in
            let unavailableBackend = FakeLoginItemBackend()
            unavailableBackend.isAvailable = false
            let unavailableController = LoginItemController(backend: unavailableBackend, defaults: defaults)
            #expect(unavailableController.consumeFirstLaunchPrompt() == false)
            #expect(defaults.object(forKey: "loginItem.promptShown") == nil)

            let enabledBackend = FakeLoginItemBackend()
            enabledBackend.status = .enabled
            let enabledController = LoginItemController(backend: enabledBackend, defaults: defaults)
            #expect(enabledController.consumeFirstLaunchPrompt() == false)
            #expect(defaults.object(forKey: "loginItem.promptShown") == nil)
        }
    }
}
