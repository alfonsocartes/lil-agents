import Testing
@testable import UsageCore

@Suite struct WidgetSetupPromptTests {
    @Test func hidesWhenNobodyIsSignedIn() {
        #expect(WidgetSetupPrompt(hasSignedInProvider: false, dismissed: false) == .hidden)
        #expect(WidgetSetupPrompt(hasSignedInProvider: false, dismissed: true) == .hidden)
    }

    @Test func showsCardWhenSignedIn() {
        #expect(WidgetSetupPrompt(hasSignedInProvider: true, dismissed: false) == .card)
    }

    @Test func showsLinkAfterDismissSoTheStepsStayReachable() {
        #expect(WidgetSetupPrompt(hasSignedInProvider: true, dismissed: true) == .link)
    }
}

@Suite struct SignedInProviderTests {
    @Test func emptySnapshotIsNotSignedIn() {
        #expect(!UsageSnapshot.empty.hasSignedInProvider)
    }

    @Test func usageCountsAsSignedIn() {
        var snapshot = UsageSnapshot.empty
        snapshot.claude.usage = ProviderUsage(
            session: nil,
            weekly: UsageWindow(percent: 10),
            fetchedAt: fixedNow
        )
        #expect(snapshot.hasSignedInProvider)
    }

    @Test func staleExpiredTokenStillCountsAsSignedIn() {
        var snapshot = UsageSnapshot.empty
        snapshot.codex.lastError = .tokenExpired
        #expect(snapshot.hasSignedInProvider)
    }

    @Test func networkErrorCountsAsSignedIn() {
        var snapshot = UsageSnapshot.empty
        snapshot.grok.lastError = .network("offline")
        #expect(snapshot.hasSignedInProvider)
    }

    @Test func credentialsMissingIsNotSignedIn() {
        var snapshot = UsageSnapshot.empty
        snapshot.claude.enabled = true
        snapshot.claude.lastError = .credentialsMissing
        #expect(!snapshot.hasSignedInProvider)
    }

    @Test func togglingAProviderOnWithoutSigningInIsNotSignedIn() {
        var snapshot = UsageSnapshot.empty
        snapshot.claude.enabled = true
        #expect(!snapshot.hasSignedInProvider)
    }
}
