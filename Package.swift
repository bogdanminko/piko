// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Piko",
    platforms: [
        // 14.4, not 14.0: system-audio capture uses Core Audio process taps
        // (14.2+) and their "Audio Capture" TCC prompt only behaves correctly
        // from 14.4 on.
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "Piko",
            path: "Piko",
            linkerSettings: [
                // SPM autolinking pulls in the _AVKit_SwiftUI overlay but not
                // AVKit itself; without it VideoPlayer crashes at runtime
                // (getSuperclassMetadata cannot resolve AVPlayerView).
                .linkedFramework("AVKit")
            ]
        )
    ]
)
