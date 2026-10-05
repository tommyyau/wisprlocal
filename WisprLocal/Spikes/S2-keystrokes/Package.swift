// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "keytest",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "KeyMap", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "keytest", dependencies: ["KeyMap"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "KeyMapTests", dependencies: ["KeyMap"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
