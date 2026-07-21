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
