// swift-tools-version: 6.2
import PackageDescription

// S5 spike: live transcript preview (S5Live) + on-device translation (S5Translate).
// Standalone; does not touch WisprLocal/App. Offline at runtime.
let package = Package(
    name: "S5Live",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "S5Live",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "S5Translate",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
