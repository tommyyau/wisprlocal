// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "S4Speaker",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "S4Speaker",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
