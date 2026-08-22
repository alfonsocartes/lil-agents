import Foundation
import UsageCore

enum AppGroup {
    static let id = "group.com.wandity.lilagents"

    /// App Group container when entitlements are present. Falls back to
    /// Application Support so an unsigned simulator still launches.
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lil-usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: id) ?? .standard
    }

    static var snapshotStore: SnapshotStore { SnapshotStore(directory: containerURL) }
}
