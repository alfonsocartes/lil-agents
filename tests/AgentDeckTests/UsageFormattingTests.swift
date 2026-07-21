import Foundation
import Testing
@testable import AgentDeck

@Suite struct UsageFormattingTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func nilPercentFormatsAsPlaceholder() {
        #expect(UsageFormatting.percentLabel(nil) == "--")
    }

    @Test func percentRoundsToNearestInteger() {
        #expect(UsageFormatting.percentLabel(61.5) == "62%")
        #expect(UsageFormatting.percentLabel(61.4) == "61%")
        #expect(UsageFormatting.percentLabel(0) == "0%")
        #expect(UsageFormatting.percentLabel(100) == "100%")
    }

    @Test func nilResetDateFormatsAsEmptyString() {
        #expect(UsageFormatting.resetLabel(for: nil, now: Date(), calendar: utcCalendar) == "")
    }

    @Test func sameDayResetOmitsWeekday() {
        let calendar = utcCalendar
        let now = calendar.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 9))!
        let resetsAt = calendar.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 15))!
        #expect(UsageFormatting.resetLabel(for: resetsAt, now: now, calendar: calendar) == "resets 3 PM")
    }

    @Test func otherDayResetIncludesWeekday() {
        let calendar = utcCalendar
        let now = calendar.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 9))!         // Tue
        let resetsAt = calendar.date(from: DateComponents(year: 2023, month: 11, day: 17, hour: 9))!     // Fri
        #expect(UsageFormatting.resetLabel(for: resetsAt, now: now, calendar: calendar) == "resets Fri 9 AM")
    }
}

/// `UsageUrgency` classifies on the ROUNDED percent — the same integer
/// `percentLabel` prints — so the boundary cases pin the "color can never
/// disagree with the displayed number" contract: 74.5 displays as "75%" and
/// must be elevated; 89.5 displays as "90%" and must be critical.
@Suite struct UsageUrgencyTests {
    @Test func nilPercentIsNormal() {
        #expect(UsageUrgency(percent: nil) == .normal)
    }

    @Test func thresholdsMatchTheRoundedDisplayValue() {
        #expect(UsageUrgency(percent: 0) == .normal)
        #expect(UsageUrgency(percent: 74.4) == .normal)     // displays "74%"
        #expect(UsageUrgency(percent: 74.5) == .elevated)   // displays "75%"
        #expect(UsageUrgency(percent: 89.4) == .elevated)   // displays "89%"
        #expect(UsageUrgency(percent: 89.5) == .critical)   // displays "90%"
        #expect(UsageUrgency(percent: 100) == .critical)
    }
}
