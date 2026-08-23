import Testing
@testable import AgentDeck

@Suite struct IPhoneTokenHandoffTests {
    @Test func itemIdentityMatchesUsageCore() {
        #expect(IPhoneTokenHandoff.accessGroup == "S74M2P6469.group.com.wandity.lilagents")
        #expect(IPhoneTokenHandoff.service("claude") == "com.wandity.lilagents.token.claude")
        #expect(IPhoneTokenHandoff.service("grok") == "com.wandity.lilagents.token.grok")
        #expect(IPhoneTokenHandoff.service("codex") == "com.wandity.lilagents.token.codex")
    }
}
