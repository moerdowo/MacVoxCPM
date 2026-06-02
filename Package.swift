// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacVoxCPM",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MacVoxCPM", targets: ["MacVoxCPM"])
    ],
    targets: [
        .executableTarget(
            name: "MacVoxCPM",
            path: "Sources/MacVoxCPM",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
