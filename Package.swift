// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reclip",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Reclip",
            path: "Sources/Reclip"
        )
    ]
)
