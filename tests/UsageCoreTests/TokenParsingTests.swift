import Foundation
import Testing
@testable import UsageCore

@Suite struct KeychainTokenStoreIdentityTests {
    @Test func serviceNamesMatchIPhoneHandoff() {
        #expect(KeychainTokenStore.service(for: .claude) == "com.wandity.lilagents.token.claude")
        #expect(KeychainTokenStore.service(for: .grok) == "com.wandity.lilagents.token.grok")
        #expect(KeychainTokenStore.service(for: .codex) == "com.wandity.lilagents.token.codex")
        #expect(KeychainTokenStore.accessGroupSuffix == "group.com.wandity.lilagents")
    }
}

@Suite struct TokenParsingTests {
    @Test func claudeJSONExtractsAccessTokenAndExpiresAt() throws {
        let raw = """
        {"claudeAiOauth": {"accessToken": "tok-123", "expiresAt": 9999999999999, "refreshToken": "refresh-xyz"}}
        """
        let credentials = try TokenParsing.claude(raw)
        #expect(credentials.accessToken == "tok-123")
        #expect(credentials.expiresAt == 9_999_999_999_999)
    }

    @Test func claudeBareTokenHasNilExpiresAt() throws {
        let credentials = try TokenParsing.claude("  tok-bare  ")
        #expect(credentials.accessToken == "tok-bare")
        #expect(credentials.expiresAt == nil)
    }

    @Test func claudeEmptyPasteFails() {
        expectCredentialsMissing { try TokenParsing.claude("   ") }
        expectCredentialsMissing { try TokenParsing.claude("") }
    }

    @Test func claudeShellCommandIsNotAToken() {
        expectCredentialsMissing {
            try TokenParsing.claude(#"security find-generic-password -w -s "Claude Code-credentials""#)
        }
    }

    @Test func claudeJSONWithoutAccessTokenFails() {
        expectCredentialsMissing { try TokenParsing.claude(#"{"claudeAiOauth": {"expiresAt": 1}}"#) }
        expectCredentialsMissing { try TokenParsing.claude("{not json") }
    }

    @Test func claudeJSONWithSiblingMCPEntries() throws {
        let raw = """
        {"https://mcp.cloudflare.com":{"issuer":"https://mcp.cloudflare.com","accessToken":"mcp-x"},"claudeAiOauth":{"accessToken":"tok-123","expiresAt":1787507503542,"refreshToken":"refresh-xyz","scopes":["user:inference"],"subscriptionType":"max"}}
        """
        let credentials = try TokenParsing.claude(raw)
        #expect(credentials.accessToken == "tok-123")
        #expect(credentials.expiresAt == 1_787_507_503_542)
    }

    @Test func claudeJSONExtractsOauthFromTruncatedPrefix() throws {
        let raw = """
        zone.write","issuer":"https://mcp.cloudflare.com"},"claudeAiOauth":{"accessToken":"tok-123","expiresAt":99}}
        """
        let credentials = try TokenParsing.claude(raw)
        #expect(credentials.accessToken == "tok-123")
        #expect(credentials.expiresAt == 99)
    }

    @Test func codexSnakeCaseJSONDecodes() throws {
        let credentials = try TokenParsing.codex(
            #"{"tokens": {"access_token": "tok-abc", "account_id": "acct-1", "refresh_token": "refresh-xyz"}}"#
        )
        #expect(credentials.accessToken == "tok-abc")
        #expect(credentials.accountID == "acct-1")
    }

    @Test func codexCamelCaseJSONDecodes() throws {
        let credentials = try TokenParsing.codex(
            #"{"tokens": {"accessToken": "tok-abc", "accountId": "acct-1"}}"#
        )
        #expect(credentials.accessToken == "tok-abc")
        #expect(credentials.accountID == "acct-1")
    }

    @Test func codexBareTokenHasNilAccountID() throws {
        let credentials = try TokenParsing.codex("tok-abc")
        #expect(credentials.accessToken == "tok-abc")
        #expect(credentials.accountID == nil)
    }

    @Test func codexAPIKeyOnlyJSONFails() {
        expectCredentialsMissing { try TokenParsing.codex(#"{"OPENAI_API_KEY": "sk-abc123"}"#) }
    }

    @Test func grokBareKey() throws {
        #expect(try TokenParsing.grok("  tok-grok  ") == "tok-grok")
    }

    @Test func grokObjectWithKey() throws {
        #expect(try TokenParsing.grok(#"{"key": "tok-grok", "refresh_token": "refresh-xyz"}"#) == "tok-grok")
    }

    @Test func grokAuthJSONUnexpiredWins() throws {
        let raw = """
        {
          "https://auth.x.ai::old": {"key": "old", "expires_at": "2023-01-01T00:00:00Z", "refresh_token": "r1"},
          "https://auth.x.ai::fresh": {"key": "fresh", "expires_at": "2024-01-01T00:00:00Z", "refresh_token": "r2"}
        }
        """
        #expect(try TokenParsing.grok(raw, now: fixedNow) == "fresh")
    }

    @Test func grokAuthJSONAllExpiredStillReturnsNewest() throws {
        let raw = """
        {
          "https://auth.x.ai::older": {"key": "older", "expires_at": "2023-01-01T00:00:00Z"},
          "https://auth.x.ai::newer": {"key": "newer-expired", "expires_at": "2023-06-01T00:00:00Z"}
        }
        """
        #expect(try TokenParsing.grok(raw, now: fixedNow) == "newer-expired")
    }

    @Test func grokAuthJSONMissingDateSortsAsNewest() throws {
        let raw = """
        {
          "https://auth.x.ai::dated": {"key": "dated", "expires_at": "2024-01-01T00:00:00Z"},
          "https://auth.x.ai::undated": {"key": "undated"}
        }
        """
        #expect(try TokenParsing.grok(raw, now: fixedNow) == "undated")
    }

    @Test func grokAuthJSONWithNoUsableKeyFails() {
        expectCredentialsMissing {
            try TokenParsing.grok(
                #"{"https://auth.x.ai::aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee": {"expires_at": "2024-01-01T00:00:00Z", "refresh_token": "refresh-xyz"}}"#,
                now: fixedNow
            )
        }
    }

    @Test func grokEmptyPasteFails() {
        expectCredentialsMissing { try TokenParsing.grok("  ") }
        expectCredentialsMissing { try TokenParsing.grok(#"{"key": ""}"#) }
    }

    @Test func macCatCommandIsNotAToken() {
        expectCredentialsMissing { try TokenParsing.grok("cat ~/.grok/auth.json") }
        expectCredentialsMissing { try TokenParsing.codex("cat ~/.codex/auth.json") }
    }

    private func expectCredentialsMissing<T>(_ body: () throws -> T) {
        do {
            _ = try body()
            Issue.record("expected .credentialsMissing")
        } catch let error as UsageFetchError {
            #expect(error == .credentialsMissing)
        } catch {
            Issue.record("expected UsageFetchError, got \(error)")
        }
    }
}
