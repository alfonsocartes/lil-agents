import Testing
@testable import AgentDeck

@Suite struct IPhoneTokenHandoffTests {
    @Test func itemIdentityMatchesUsageCore() {
        #expect(IPhoneTokenHandoff.accessGroup == "S74M2P6469.group.com.wandity.lilagents")
        #expect(IPhoneTokenHandoff.service("claude") == "com.wandity.lilagents.token.claude")
        #expect(IPhoneTokenHandoff.service("grok") == "com.wandity.lilagents.token.grok")
        #expect(IPhoneTokenHandoff.service("codex") == "com.wandity.lilagents.token.codex")
    }

    @Test func disableDoesNotDelete() {
        #expect(IPhoneTokenHandoff.action(enabled: false, cliBlob: "x") == .skip)
    }

    @Test func missingCLIBlobDoesNotDelete() {
        #expect(IPhoneTokenHandoff.action(enabled: true, cliBlob: nil) == .skip)
        #expect(IPhoneTokenHandoff.action(enabled: true, cliBlob: "") == .skip)
    }

    @Test func presentCLIBlobUpserts() {
        #expect(IPhoneTokenHandoff.action(enabled: true, cliBlob: "{\"a\":1}") == .upsert("{\"a\":1}"))
    }
}
