import Testing
@testable import UsageCore

@Suite struct HandoffEnablementTests {
    @Test func neverToggledMayAutoEnable() {
        #expect(HandoffEnablement.shouldAutoEnable(explicitSetting: nil))
    }

    @Test func explicitOffIsNotOverriddenByAToken() {
        #expect(!HandoffEnablement.shouldAutoEnable(explicitSetting: false))
    }

    @Test func explicitOnIsLeftAlone() {
        #expect(!HandoffEnablement.shouldAutoEnable(explicitSetting: true))
    }
}
