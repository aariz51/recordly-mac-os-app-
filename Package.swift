// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Reclip",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Reclip",
            path: "Sources/Reclip",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
