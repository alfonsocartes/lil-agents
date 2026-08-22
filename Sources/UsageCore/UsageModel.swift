import Foundation

/// A single usage window (Claude's 5-hour session window, or either
/// provider's weekly window) as reported by a provider's usage API. Fetchers
/// build these AFTER decoding — by the time a `UsageWindow` exists it always
/// carries a `percent`; only `resetsAt` may be genuinely absent.
public struct UsageWindow: Codable, Equatable, Sendable {
    public var percent: Double
    public var resetsAt: Date?

    public init(percent: Double, resetsAt: Date? = nil) {
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// A snapshot of one provider's usage, as of `fetchedAt`. `session` and
/// `weekly` are independently optional: Claude's endpoint reports both from
/// one call, while Codex's current plans only ever expose a weekly window —
/// `session == nil` for Codex is the normal case, not a decoding failure.
public struct ProviderUsage: Codable, Equatable, Sendable {
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    public var fetchedAt: Date

    public init(session: UsageWindow?, weekly: UsageWindow?, fetchedAt: Date) {
        self.session = session
        self.weekly = weekly
        self.fetchedAt = fetchedAt
    }
}

/// Every way a usage fetch can fail, mapped from each fetcher's HTTP/decoding
/// layer so callers never need to know about status codes or JSON shapes.
public enum UsageFetchError: Error, Equatable, Codable, Sendable {
    /// No usable credentials: paste was empty/unparseable, or the injected
    /// credentials closure threw something other than a `UsageFetchError`.
    case credentialsMissing
    /// Credentials were found but are dead: a locally-computed `expiresAt`
    /// already in the past (Claude only — short-circuits before any network
    /// call), or the server itself rejected them (401/403).
    case tokenExpired
    /// HTTP 429. `retryAfter` is the delta-seconds to wait, parsed from the
    /// `Retry-After` header (bare delta-seconds or an RFC 1123 HTTP-date
    /// minus the fetcher's injected `now`) — nil when the header was absent
    /// or unparseable.
    case rateLimited(retryAfter: TimeInterval?)
    /// Transport-level failure (`URLError` from the injected transport),
    /// stringified for logging/display.
    case network(String)
    /// Any other non-2xx response (or a response that failed to decode),
    /// stringified for logging/display.
    case badResponse(String)
}

/// One provider's usage lifecycle. Mirrors AgentDeck's `ProviderUsageState`
/// so the iOS app/widget can use the same vocabulary.
public enum ProviderUsageState: Equatable, Sendable {
    case disabled
    case loading
    case available(ProviderUsage)
    case stale(ProviderUsage, UsageFetchError)
    case unavailable(UsageFetchError)

    public var usage: ProviderUsage? {
        switch self {
        case .available(let usage), .stale(let usage, _): return usage
        case .disabled, .loading, .unavailable: return nil
        }
    }

    public var isDimmed: Bool {
        switch self {
        case .loading, .stale, .unavailable: return true
        case .disabled, .available: return false
        }
    }
}

/// How urgently a usage window needs the user's attention, derived purely
/// from its percent. Classifies on the ROUNDED percent — the same integer
/// `UsageFormatting.percentLabel` prints — so the tier can never disagree
/// with the number next to it (89.6 displays as "90%" and must be red).
public enum UsageUrgency: Equatable, Sendable {
    case normal
    case elevated
    case critical

    public init(percent: Double?) {
        guard let percent else {
            self = .normal
            return
        }
        let displayed = Int(percent.rounded())
        if displayed >= 90 {
            self = .critical
        } else if displayed >= 75 {
            self = .elevated
        } else {
            self = .normal
        }
    }
}

/// Pure string-formatting helpers — `"62%"` / `"resets 3 PM"` phrasing
/// defined exactly once for app + widget.
public enum UsageFormatting {
    public static func percentLabel(_ percent: Double?) -> String {
        guard let percent else { return "--" }
        return "\(Int(percent.rounded()))%"
    }

    /// `"resets 3 PM"` when `date` falls on the same calendar day as `now`;
    /// `"resets Fri 9 AM"` otherwise. Empty string when there's no reset date.
    /// `calendar` is a test seam; the formatter's locale is pinned to
    /// `en_US_POSIX` so AM/PM phrasing stays deterministic.
    public static func resetLabel(for date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h a" : "EEE h a"
        return "resets \(formatter.string(from: date))"
    }
}
