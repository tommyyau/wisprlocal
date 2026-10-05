// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WisprLocal",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "WisprLocal", targets: ["WisprLocal"]),
        .library(name: "WisprLocalCore", targets: ["WisprLocalCore"]),
        .executable(name: "WisprLocalReceiver", targets: ["WisprLocalReceiver"]),
    ],
    dependencies: [
        // ASR/VAD only: exclude the optional native text-normalization engine used by TTS/ITN.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: [])
    ],
    targets: [
        .target(
            name: "WisprLocalCore",
            dependencies: ["WisprLocalStatsC", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        // Insights' word-level cleanup diff, in plain C so it stays fast in unoptimised builds.
        .target(name: "WisprLocalStatsC"),
        .executableTarget(
            name: "WisprLocal",
            dependencies: ["WisprLocalCore"]
        ),
        // P3 menu-bar receiver for the REMOTE Mac (tailnet-only; scripts/build_receiver.sh).
        .executableTarget(
            name: "WisprLocalReceiver",
            dependencies: ["WisprLocalCore"]
        ),
        // Dev-only ONLINE downloader used by scripts/fetch_models.sh. Not linked into the app.
        .executableTarget(
            name: "wisprlocal-fetch-models",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Tools/ModelFetcher"
        ),
        // Dev-only OFFLINE replay of a saved debug recording: `swift run WisprLocalReplay <wav>`.
        .executableTarget(
            name: "WisprLocalReplay",
            dependencies: ["WisprLocalCore"],
            path: "Tools/Replay"
        ),
        .testTarget(
            name: "WisprLocalCoreTests",
            dependencies: ["WisprLocalCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
