import Foundation
import Testing
@testable import UsageCore

@Suite struct PKCETests {
    @Test func challengeIsS256OfVerifier() {
        let pkce = PKCE.generate()
        #expect(!pkce.verifier.isEmpty)
        #expect(!pkce.challenge.contains("+"))
        #expect(!pkce.challenge.contains("/"))
        #expect(!pkce.challenge.contains("="))
        #expect(pkce.state != pkce.verifier)
        #expect(pkce.verifier.count == 43)
        #expect(pkce.challenge.count == 43)
        #expect(pkce.state.count == 43)
    }
}

@Suite struct ClaudeOAuthTests {
    @Test func startURLUsesHostedCallbackAndPKCE() {
        let pkce = PKCE(verifier: "ver", challenge: "chal", state: "st")
        let start = ClaudeOAuth.start(pkce: pkce)
        let items = URLComponents(url: start.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(start.authorizationURL.host == "claude.com")
        #expect(map["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(map["redirect_uri"] == "https://platform.claude.com/oauth/code/callback")
        #expect(map["code"] == "true")
        #expect(map["code_challenge"] == "chal")
        #expect(map["state"] == "st")
        #expect(map["scope"] == "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload")
    }

    @Test func exchangeSplitsCodeHashStateAndPostsJSON() async throws {
        let pkce = PKCE(verifier: "ver", challenge: "chal", state: "st")
        let body = #"{"access_token":"tok","refresh_token":"ref","expires_in":3600}"#
        let spy = TransportSpy([.success(status: 200, body: Data(body.utf8))])
        let tokens = try await ClaudeOAuth.exchange(
            pasted: "AUTHCODE#st",
            pkce: pkce,
            transport: spy.handle,
            now: fixedNow
        )
        #expect(tokens.accessToken == "tok")
        #expect(tokens.refreshToken == "ref")
        #expect(tokens.expiresAt == fixedNow.addingTimeInterval(3600))
        let sent = spy.requests.first!
        #expect(sent.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
        let json = try JSONSerialization.jsonObject(with: sent.httpBody!) as! [String: String]
        #expect(json["code"] == "AUTHCODE")
        #expect(json["code_verifier"] == "ver")
        #expect(json["state"] == "st")
        #expect(json["redirect_uri"] == "https://platform.claude.com/oauth/code/callback")
    }
}

@Suite struct CodexDeviceAuthTests {
    @Test func startParsesUserCode() async throws {
        let body = #"{"device_auth_id":"dev1","user_code":"ABCD-1234","interval":"5"}"#
        let spy = TransportSpy([.success(status: 200, body: Data(body.utf8))])
        let pending = try await CodexDeviceAuth.start(transport: spy.handle)
        #expect(pending.userCode == "ABCD-1234")
        #expect(pending.deviceAuthID == "dev1")
        #expect(pending.verificationURL.absoluteString == "https://auth.openai.com/codex/device")
        let sent = spy.requests.first!
        #expect(sent.url?.absoluteString == "https://auth.openai.com/api/accounts/deviceauth/usercode")
    }

    @Test func start404MeansDeviceCodeDisabled() async {
        let spy = TransportSpy([.success(status: 404, body: Data())])
        do {
            _ = try await CodexDeviceAuth.start(transport: spy.handle)
            Issue.record("expected denied")
        } catch let error as OAuthLoginError {
            guard case .denied = error else {
                Issue.record("expected .denied, got \(error)")
                return
            }
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func pollThenExchange() async throws {
        let pending = CodexDeviceAuth.Pending(
            userCode: "ABCD-1234",
            verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
            deviceAuthID: "dev1",
            interval: 0
        )
        let poll = #"{"authorization_code":"ac","code_verifier":"cv","code_challenge":"cc"}"#
        let token = #"{"access_token":"atok","refresh_token":"rtok","id_token":"x.e30.x"}"#
        let spy = TransportSpy([
            .success(status: 403, body: Data()),
            .success(status: 200, body: Data(poll.utf8)),
            .success(status: 200, body: Data(token.utf8)),
        ])
        let tokens = try await CodexDeviceAuth.poll(
            pending: pending,
            transport: spy.handle,
            sleep: { _ in },
            now: { fixedNow },
            maxWait: 60
        )
        #expect(tokens.accessToken == "atok")
        #expect(tokens.refreshToken == "rtok")
        #expect(spy.callCount == 3)
        #expect(spy.requests[2].url?.absoluteString == "https://auth.openai.com/oauth/token")
    }
}

@Suite struct GrokDeviceAuthTests {
    @Test func startAndPollRFC8628() async throws {
        let startBody = #"{"device_code":"dc","user_code":"WDJB-MJHT","verification_uri":"https://accounts.x.ai/oauth2/device","expires_in":900,"interval":1}"#
        let pendingSpy = TransportSpy([.success(status: 200, body: Data(startBody.utf8))])
        let pending = try await GrokDeviceAuth.start(transport: pendingSpy.handle)
        #expect(pending.userCode == "WDJB-MJHT")
        #expect(pending.deviceCode == "dc")

        let waiting = #"{"error":"authorization_pending"}"#
        let token = #"{"access_token":"gkey","refresh_token":"gref","expires_in":3600}"#
        let spy = TransportSpy([
            .success(status: 400, body: Data(waiting.utf8)),
            .success(status: 200, body: Data(token.utf8)),
        ])
        let tokens = try await GrokDeviceAuth.poll(
            pending: pending,
            transport: spy.handle,
            sleep: { _ in },
            now: { fixedNow }
        )
        #expect(tokens.accessToken == "gkey")
        #expect(tokens.refreshToken == "gref")
    }
}

@Suite struct CredentialBlobTests {
    @Test func claudeBlobRoundTripsThroughTokenParsing() throws {
        let blob = CredentialBlob.claude(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: fixedNow))
        let creds = try TokenParsing.claude(blob)
        #expect(creds.accessToken == "a")
    }

    @Test func tokenRefreshReadsRefreshTokenFromClaudeJSON() throws {
        let blob = CredentialBlob.claude(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: fixedNow))
        let session = try TokenRefresh.refreshable(kind: .claude, raw: blob)
        #expect(session.refreshToken == "r")
        #expect(TokenRefresh.needsRefresh(kind: .claude, raw: blob, now: fixedNow.addingTimeInterval(1)))
    }
}
