// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v26), .iOS(.v18)],
    dependencies: [
        // Sparkle powers in-app auto-updates (Check for Updates… + background checks).
        // macOS-only: UsageCore is the iOS-safe target and must not grow this dep.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "AgentDeck",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/AgentDeck",
            resources: [
                .process("Resources"),
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
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore"
        ),
        .testTarget(
            name: "AgentDeckTests",
            dependencies: ["AgentDeck"],
            path: "tests/AgentDeckTests",
            resources: [
                .process("../../Sources/AgentDeck/Resources"),
            ]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "tests/UsageCoreTests"
        )
    ]
)
