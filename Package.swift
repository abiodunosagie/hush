// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Hush", path: "Sources/Hush")
    ],
    swiftLanguageModes: [.v5]
)
