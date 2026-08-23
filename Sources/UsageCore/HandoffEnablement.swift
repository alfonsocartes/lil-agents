/// Policy for turning a provider on because a token arrived via iCloud
/// Keychain (Mac → iPhone), not because the user tapped the toggle.
public enum HandoffEnablement {
    /// Auto-enable only when the user has never toggled this provider.
    /// An explicit "Show in widgets" off stays off even if a token exists.
    public static func shouldAutoEnable(explicitSetting: Bool?) -> Bool {
        explicitSetting == nil
    }
}
