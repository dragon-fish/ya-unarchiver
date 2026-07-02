// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ArchiveKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
    ],
    targets: [
        .target(name: "ArchiveKit"),
        .testTarget(name: "ArchiveKitTests", dependencies: ["ArchiveKit"]),
    ]
)
