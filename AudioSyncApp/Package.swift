// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AudioSyncApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "AudioSyncApp",
            targets: ["AudioSyncApp"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AudioSyncApp",
            dependencies: []),
        .testTarget(
            name: "AudioSyncAppTests",
            dependencies: ["AudioSyncApp", // .product(name: "XCTest")]),
    ]
)