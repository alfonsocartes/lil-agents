import Foundation
import Testing
@testable import AgentDeck

@Suite struct PathNormalizationTests {

    // MARK: WezTermJumper.normalizeTTY

    @Test func normalizeTTYStripsDevPrefix() {
        #expect(WezTermJumper.normalizeTTY("/dev/ttys004") == "ttys004")
    }

    @Test func normalizeTTYLeavesBareFormUntouched() {
        #expect(WezTermJumper.normalizeTTY("ttys004") == "ttys004")
    }

    // MARK: GhosttyJumper.normalizedCWDVariants

    @Test func tmpGetsPrivateVariant() {
        let v = GhosttyJumper.normalizedCWDVariants("/tmp/x")
        #expect(v.plain == "/tmp/x")
        #expect(v.privatePath == "/private/tmp/x")
    }

    @Test func alreadyPrivateIsNotDoublePrefixed() {
        let v = GhosttyJumper.normalizedCWDVariants("/private/tmp/x")
        #expect(v.plain == "/private/tmp/x")
        #expect(v.privatePath == "/private/tmp/x")   // no /private/private/...
    }

    @Test func ordinaryPathHasEqualVariants() {
        let v = GhosttyJumper.normalizedCWDVariants("/Users/foo")
        #expect(v.plain == "/Users/foo")
        #expect(v.privatePath == "/Users/foo")
    }

    @Test func trailingSlashIsTrimmed() {
        let v = GhosttyJumper.normalizedCWDVariants("/Users/foo/")
        #expect(v.plain == "/Users/foo")
        #expect(v.privatePath == "/Users/foo")
    }
}
