// swift-tools-version:6.0
// SourceKit manifest. The app bundle is built by the Makefile via swiftc.
import PackageDescription

let package = Package(
    name: "AgentUsage",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AgentUsage",
            path: "Sources",
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "AgentUsageTests",
            dependencies: ["AgentUsage"],
            path: "Tests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
