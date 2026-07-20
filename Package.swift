// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Sparkle powers in-app auto-updates (Check for Updates… + background checks).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "AgentDeck",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AgentDeck",
            swiftSettings: [
                // Pragmatic: v5 language mode avoids strict-concurrency churn for an
                // AppKit/Network app whose callbacks hop to the main actor manually.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // Sparkle.framework ships as a binary XCFramework and is embedded into
                // Contents/Frameworks/ by scripts/build-app.sh. This rpath lets the
                // executable find it at runtime. (.unsafeFlags is fine for a leaf app.)
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(
            name: "AgentDeckTests",
            dependencies: ["AgentDeck"],
            path: "tests/AgentDeckTests",
            swiftSettings: [
                // Match the main target's language mode (6b flips both).
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
