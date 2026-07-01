// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "7zip-swiftui",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ArchiveKit"),
        .executableTarget(
            name: "SevenZipApp",
            dependencies: ["ArchiveKit"]
        ),
        .testTarget(
            name: "ArchiveKitTests",
            dependencies: ["ArchiveKit"]
        ),
    ]
)
