// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "S1Parakeet",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "S1Parakeet",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
