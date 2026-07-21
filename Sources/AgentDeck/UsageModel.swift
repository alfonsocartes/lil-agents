import Foundation

/// A single usage window (Claude's 5-hour session window, or either
/// provider's weekly window) as reported by a provider's usage API. Both
/// fetchers build these AFTER decoding — see ClaudeUsageFetcher.swift and
/// CodexUsageFetcher.swift for the tolerant wire-format Decodable types that
/// feed into this — so by the time a `UsageWindow` exists it always carries a
/// `percent`; only `resetsAt` may be genuinely absent (an API response that
/// didn't include a reset time).
struct UsageWindow: Equatable, Sendable {
    var percent: Double
    var resetsAt: Date?
}

/// A snapshot of one provider's usage, as of `fetchedAt`. `session` and
/// `weekly` are independently optional: Claude's endpoint reports both from
/// one call, while Codex's current plans only ever expose a weekly window —
/// `session == nil` for Codex is the normal case, not a decoding failure (see
/// CodexUsageFetcher.swift's classification comment).
struct ProviderUsage: Equatable, Sendable {
    var session: UsageWindow?
    var weekly: UsageWindow?
    var fetchedAt: Date
}

/// Every way a usage fetch can fail, mapped from each fetcher's HTTP/decoding
/// layer so `UsageStore` and the UI never need to know about status codes or
/// JSON shapes. Both `ClaudeUsageFetcher` and `CodexUsageFetcher` map onto
/// this identically (see their "Error mapping" sections).
enum UsageFetchError: Error, Equatable {
    /// No usable credentials found: the on-disk file was absent/unreadable
    /// AND (Claude only) the Keychain fallback was absent or denied, or
    /// (Codex only) `auth.json` exists but is API-key-only — no `tokens`
    /// object at all. v1 never writes credentials or refreshes tokens, so
    /// this state means "run `claude`/`codex` to sign in", not "retry".
    case credentialsMissing
    /// Credentials were found but are dead: a locally-computed `expiresAt`
    /// already in the past (Claude only — short-circuits before any network
    /// call), or the server itself rejected them (401/403). Same fix as
    /// `credentialsMissing`: sign in again via the CLI.
    case tokenExpired
    /// HTTP 429. `retryAfter` is the delta-seconds to wait, parsed from the
    /// `Retry-After` header (either a bare delta-seconds value or an
    /// RFC 1123 HTTP-date, in which case it's the date minus the fetcher's
    /// injected `now()) — nil` when the header was absent or unparseable.
    case rateLimited(retryAfter: TimeInterval?)
    /// Transport-level failure (`URLError` from the injected transport),
    /// stringified for logging/display.
    case network(String)
    /// Any other non-2xx response (or a response that failed to decode),
    /// stringified for logging/display.
    case badResponse(String)
}

/// One provider's usage lifecycle, as tracked by `UsageStore`. Mirrors
/// `SessionStatus`'s role for sessions: a small state machine the UI reads
/// directly rather than reconstructing from raw fetch results.
enum ProviderUsageState: Equatable {
    /// The user hasn't opted this provider in (Settings toggle off). The
    /// initial state for both providers in a fresh `UsageStore`.
    case disabled
    /// A fetch is in flight and there's no prior data to show meanwhile.
    case loading
    /// The most recent fetch succeeded; `ProviderUsage` is fresh.
    case available(ProviderUsage)
    /// The most recent fetch failed, but a PRIOR successful fetch's data is
    /// still available to show (dimmed, per `isDimmed` below) alongside the
    /// error that explains why it isn't being refreshed right now.
    case stale(ProviderUsage, UsageFetchError)
    /// The most recent fetch failed and there has never been a successful
    /// one for this provider (this launch) — nothing to show but the error.
    case unavailable(UsageFetchError)

    /// The most recent usage snapshot available to display, regardless of
    /// current state. Only `.available`/`.stale` carry one.
    var usage: ProviderUsage? {
        switch self {
        case .available(let usage), .stale(let usage, _): return usage
        case .disabled, .loading, .unavailable: return nil
        }
    }

    /// True when the UI should render this provider's numbers de-emphasized:
    /// no fresh data yet, a fetch is currently failing, or the last
    /// successful fetch is now stale. `.disabled` is excluded — a disabled
    /// provider's row is omitted entirely by the UI, not dimmed.
    var isDimmed: Bool {
        switch self {
        case .loading, .stale, .unavailable: return true
        case .disabled, .available: return false
        }
    }
}

/// Pure string-formatting helpers shared by the menu bar icon, overlay
/// header, and dropdown section — kept here (rather than duplicated in each
/// UI file) so the "62%" / "resets 3 PM" phrasing is defined exactly once.
enum UsageFormatting {
    /// `"62%"` for a present percent (rounded to the nearest integer — the
    /// upstream APIs report fractional percents, but nobody reads decimals
    /// off a 9pt menu bar glyph), or `"--"` when there's nothing to show
    /// (nil window, disabled provider, never-fetched).
    static func percentLabel(_ percent: Double?) -> String {
        guard let percent else { return "--" }
        return "\(Int(percent.rounded()))%"
    }

    /// `"resets 3 PM"` when `date` falls on the same calendar day as `now`;
    /// `"resets Fri 9 AM"` otherwise. Empty string when there's no reset date
    /// to show. `calendar` is a test seam (inject a fixed time zone for
    /// deterministic same-day/other-day boundaries); the formatter's locale
    /// is pinned to `en_US_POSIX` independent of `calendar`'s so the AM/PM
    /// phrasing itself stays deterministic regardless of the user's system
    /// locale.
    static func resetLabel(for date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h a" : "EEE h a"
        return "resets \(formatter.string(from: date))"
    }
}
