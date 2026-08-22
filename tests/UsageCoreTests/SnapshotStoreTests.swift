import Foundation
import Testing
@testable import UsageCore

@Suite struct SnapshotStoreTests {
    @Test func missingFileReturnsEmptyDisabledSnapshots() {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = SnapshotStore(directory: dir)
        let snapshot = store.load()
        #expect(snapshot == .empty)
        #expect(snapshot.claude.enabled == false)
        #expect(snapshot.grok.enabled == false)
        #expect(snapshot.codex.enabled == false)
        #expect(snapshot.claude.usage == nil)
        #expect(snapshot.claude.lastError == nil)
    }

    @Test func roundTripsUsageAndError() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = SnapshotStore(directory: dir)
        let usage = ProviderUsage(
            session: UsageWindow(percent: 62.5, resetsAt: Date(timeIntervalSince1970: 1_700_003_600)),
            weekly: UsageWindow(percent: 41, resetsAt: nil),
            fetchedAt: fixedNow
        )
        let original = UsageSnapshot(
            claude: ProviderSnapshot(
                enabled: true,
                usage: usage,
                lastError: nil,
                lastAttemptAt: fixedNow,
                retryAfterUntil: nil
            ),
            grok: ProviderSnapshot(
                enabled: true,
                usage: nil,
                lastError: .rateLimited(retryAfter: 120),
                lastAttemptAt: fixedNow,
                retryAfterUntil: fixedNow.addingTimeInterval(120)
            ),
            codex: ProviderSnapshot(
                enabled: false,
                usage: nil,
                lastError: .network("boom"),
                lastAttemptAt: nil,
                retryAfterUntil: nil
            )
        )
        try store.save(original)
        let loaded = store.load()
        #expect(loaded == original)
        #expect(loaded.claude.usage?.session?.percent == 62.5)
        #expect(loaded.grok.lastError == .rateLimited(retryAfter: 120))
        #expect(loaded.codex.lastError == .network("boom"))
    }

    @Test func tokensNeverAppearInFileBytes() throws {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let store = SnapshotStore(directory: dir)
        let usage = ProviderUsage(session: nil, weekly: UsageWindow(percent: 7, resetsAt: nil), fetchedAt: fixedNow)
        try store.save(UsageSnapshot(
            claude: ProviderSnapshot(enabled: true, usage: usage, lastError: .tokenExpired),
            grok: .empty,
            codex: .empty
        ))
        let data = try Data(contentsOf: dir.appendingPathComponent(SnapshotStore.filename))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("accessToken"))
        #expect(!text.contains("access_token"))
        #expect(!text.contains("refresh_token"))
        #expect(!text.contains("Bearer"))
        #expect(!text.contains("tok-"))
        #expect(!text.lowercased().contains("\"key\""))
    }
}
