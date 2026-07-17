// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AudioSyncApp",
    platforms: [
        .macOS(.v13)  // ScreenCaptureKit requires macOS 12.3+, we target 13+ for API stability
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
            dependencies: [],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                // Embed Info.plist into the binary so macOS shows permission dialogs
                // with our NSMicrophoneUsageDescription and NSScreenCaptureUsageDescription
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"]),
            ]
        ),
        .testTarget(
            name: "AudioSyncAppTests",
            dependencies: ["AudioSyncApp"]
        ),
    ]
)
