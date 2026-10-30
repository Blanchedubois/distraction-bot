// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DistractionBot",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "DistractionBot",
            path: "Sources/DistractionBot",
            resources: [.copy("Resources/Fonts")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
