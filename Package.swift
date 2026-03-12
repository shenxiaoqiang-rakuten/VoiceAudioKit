// swift-tools-version: 5.9
// VoiceAudioKit: iOS audio recording, playback, and voice call with AEC.
// Protocol-based design with default implementations and PCM plugins.
import PackageDescription

let package = Package(
    name: "VoiceAudioKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "VoiceAudioProtocol", targets: ["VoiceAudioProtocol"]),
        .library(name: "VoiceAudioImplementation", targets: ["VoiceAudioImplementation"])
    ],
    targets: [
        .target(
            name: "VoiceAudioProtocol",
            dependencies: [],
            path: "Sources/VoiceAudioProtocol"
        ),
        .target(
            name: "VoiceAudioImplementation",
            dependencies: ["VoiceAudioProtocol"],
            path: "Sources/VoiceAudioImplementation"
        ),
        .testTarget(
            name: "VoiceAudioImplementationTests",
            dependencies: ["VoiceAudioImplementation"],
            path: "Tests/VoiceAudioImplementationTests"
        )
    ]
)
