// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "s3", platforms: [.macOS("26.0")],
  targets: [
    .target(name: "S3Guard", path: "Sources/S3Guard", swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "s3", dependencies: ["S3Guard"], path: "Sources/s3", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "S3GuardTests", dependencies: ["S3Guard"], path: "Tests/S3GuardTests", swiftSettings: [.swiftLanguageMode(.v5)]),
  ])
