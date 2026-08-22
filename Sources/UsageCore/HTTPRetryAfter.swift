import Foundation

/// Shared HTTP status / `Retry-After` mapping used by all three fetchers.
/// Extracted from the duplicated AgentDeck helpers (Claude/Codex/Grok
/// UsageFetcher.swift, 2026-08-22) — keep the mapping in lockstep:
/// 2xx ok; 401/403 → `.tokenExpired`; 429 → `.rateLimited(retryAfter:)`
/// (delta-seconds or RFC 1123 relative to `now`); other → `.badResponse`.
enum HTTPRetryAfter {
    static func validate(response: HTTPURLResponse, now: Date) throws {
        let status = response.statusCode
        if (200..<300).contains(status) { return }
        switch status {
        case 401, 403:
            throw UsageFetchError.tokenExpired
        case 429:
            let retryAfter = parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now)
            throw UsageFetchError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageFetchError.badResponse("HTTP \(status)")
        }
    }

    /// `Retry-After` is either a bare delta-seconds integer OR an RFC 1123
    /// HTTP-date (e.g. `"Wed, 21 Oct 2015 07:28:00 GMT"`) — parsed as a
    /// delta from the injected `now` in the latter case.
    static func parseRetryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let header, !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return seconds }
        if let date = makeHTTPDateFormatter().date(from: header) {
            return date.timeIntervalSince(now)
        }
        return nil
    }

    // `DateFormatter` isn't `Sendable`, so this is built fresh per call
    // rather than cached as a static — cheap at usage-fetch frequency.
    static func makeHTTPDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }

    static func perform(
        _ request: URLRequest,
        transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        do {
            return try await transport(request)
        } catch let error as URLError {
            throw UsageFetchError.network(error.localizedDescription)
        } catch let error as UsageFetchError {
            throw error
        } catch {
            throw UsageFetchError.network(String(describing: error))
        }
    }
}
