// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentDeck",
            path: "Sources/AgentDeck",
            swiftSettings: [
                // Pragmatic: v5 language mode avoids strict-concurrency churn for an
                // AppKit/Network app whose callbacks hop to the main actor manually.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
