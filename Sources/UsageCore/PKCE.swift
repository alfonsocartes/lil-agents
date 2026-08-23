import CryptoKit
import Foundation
import Security

public struct PKCE: Equatable, Sendable {
    public var verifier: String
    public var challenge: String
    public var state: String

    public static func generate() -> PKCE {
        // Claude Code 2.1.240: verifier and state are both base64url(32 random
        // bytes) — 43 chars. A 16-byte state is rejected as "Invalid request format".
        let verifier = randomURLSafe(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        let state = randomURLSafe(byteCount: 32)
        return PKCE(verifier: verifier, challenge: challenge, state: state)
    }

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = 4 - s.count % 4
        if pad < 4 { s += String(repeating: "=", count: pad) }
        self.init(base64Encoded: s)
    }
}

enum FormURLEncoder {
    static func encode(_ pairs: [(String, String)]) -> Data {
        pairs.map { key, value in
            "\(escape(key))=\(escape(value))"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
    }

    private static func escape(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}

enum JWTPayload {
    static func json(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, let data = Data(base64URL: String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func chatgptAccountID(_ jwt: String) -> String? {
        guard let payload = json(jwt) else { return nil }
        if let id = payload["chatgpt_account_id"] as? String, !id.isEmpty { return id }
        if let nested = payload["https://api.openai.com/auth"] as? [String: Any],
           let id = nested["chatgpt_account_id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }
}
