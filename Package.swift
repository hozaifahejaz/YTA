// swift-tools-version: 6.0
import PackageDescription

// YTA builds with Swift Package Manager from the Command Line Tools alone.
// Core modules are plain Foundation so their tests also run on Linux.
// The app, design system and canvas need SwiftUI and are added on macOS only.

var products: [Product] = [
    .library(name: "YTACore", targets: ["Support", "ChannelStore", "Workflow", "Secrets", "Engines", "YouTubeData", "Naming", "Brand", "Voice"]),
    .executable(name: "yta-engine-check", targets: ["EngineCheck"]),
    .executable(name: "yta-youtube-check", targets: ["YouTubeCheck"]),
]

var targets: [Target] = [
    .target(name: "Support"),
    .target(name: "Secrets", dependencies: ["Support"]),
    .target(name: "ChannelStore", dependencies: ["Support"]),
    .target(name: "Workflow", dependencies: ["Support", "ChannelStore", "Engines", "YouTubeData", "Naming", "Brand", "Voice"]),
    .target(name: "Engines", dependencies: ["Support"]),
    .target(name: "YouTubeData", dependencies: ["Support", "ChannelStore"]),
    .target(name: "Naming", dependencies: ["Support", "YouTubeData"]),
    .target(name: "Brand", dependencies: ["Support"]),
    .target(name: "Voice", dependencies: ["Support", "YouTubeData"]),
    .executableTarget(name: "EngineCheck", dependencies: ["Support", "ChannelStore", "Workflow", "Engines"]),
    .executableTarget(name: "YouTubeCheck", dependencies: ["Support", "Secrets", "YouTubeData"]),

    .testTarget(name: "SupportTests", dependencies: ["Support"]),
    .testTarget(name: "SecretsTests", dependencies: ["Secrets", "Support"]),
    .testTarget(name: "ChannelStoreTests", dependencies: ["ChannelStore", "Support"]),
    .testTarget(name: "WorkflowTests", dependencies: ["Workflow", "ChannelStore", "Engines", "Support", "YouTubeData", "Naming", "Brand", "Voice"]),
    .testTarget(name: "VoiceTests", dependencies: ["Voice", "YouTubeData", "Support"]),
    .testTarget(name: "EnginesTests", dependencies: ["Engines", "Support"]),
    .testTarget(name: "YouTubeDataTests", dependencies: ["YouTubeData", "ChannelStore", "Support"]),
    .testTarget(name: "NamingTests", dependencies: ["Naming", "YouTubeData", "Support"]),
    .testTarget(name: "BrandTests", dependencies: ["Brand", "Support"]),
]

#if os(macOS)
products.append(.executable(name: "YTA", targets: ["YTAApp"]))
targets += [
    .target(name: "DesignSystem"),
    .target(name: "Canvas", dependencies: ["DesignSystem", "Workflow", "Support"]),
    .target(name: "Artwork", dependencies: ["Brand", "Support"]),
    .testTarget(name: "ArtworkTests", dependencies: ["Artwork", "Brand"]),
    .target(name: "MediaTools", dependencies: ["Voice", "Support"]),
    .executableTarget(
        name: "YTAApp",
        dependencies: ["DesignSystem", "Canvas", "Workflow", "ChannelStore", "Engines", "Secrets", "Support", "YouTubeData", "Naming", "Brand", "Artwork", "Voice", "MediaTools"]
    ),
]
#endif

let package = Package(
    name: "YTA",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
