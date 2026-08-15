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
        ),
        .testTarget(
            name: "ReclipTests",
            dependencies: ["Reclip"],
            path: "Tests/ReclipTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
