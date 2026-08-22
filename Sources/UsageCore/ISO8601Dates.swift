import Foundation

/// ISO 8601 parse used by Claude/Grok response dates and Grok `auth.json`
/// `expires_at`. Built fresh per call because `ISO8601DateFormatter` isn't
/// `Sendable`. Tries fractional seconds first, then without.
enum ISO8601Dates {
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        return withoutFractional.date(from: string)
    }
}
