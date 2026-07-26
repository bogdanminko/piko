// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Piko",
    platforms: [
        .macOS(.v14)
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
