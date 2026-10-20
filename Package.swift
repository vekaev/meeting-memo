// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingMemo",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MeetingMemo",
            path: "Sources/MeetingMemo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
