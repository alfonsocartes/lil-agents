import Foundation
import Testing
@testable import AgentDeck

@MainActor
@Suite struct AppSettingsTests {
    @Test func sessionsEnabledDefaultsOnWhenKeyIsMissing() {
        withScratchDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.sessionsEnabled)
        }
    }

    @Test func sessionsEnabledPersistsAndFiresChange() {
        withScratchDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            var seen: [Bool] = []
            settings.onSessionsEnabledChange = { seen.append($0) }

            settings.sessionsEnabled = false
            #expect(settings.sessionsEnabled == false)
            #expect(defaults.object(forKey: "sessions.enabled") as? Bool == false)
            #expect(seen == [false])

            settings.sessionsEnabled = true
            #expect(settings.sessionsEnabled)
            #expect(defaults.object(forKey: "sessions.enabled") as? Bool == true)
            #expect(seen == [false, true])
        }
    }

    @Test func sessionsEnabledReadsStoredFalse() {
        withScratchDefaults { defaults in
            defaults.set(false, forKey: "sessions.enabled")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.sessionsEnabled == false)
        }
    }
}
