// swift-tools-version: 6.0
import PackageDescription

// YTA builds with Swift Package Manager from the Command Line Tools alone.
// Core modules are plain Foundation so their tests also run on Linux.
// The app, design system and canvas need SwiftUI and are added on macOS only.

var products: [Product] = [
    .library(name: "YTACore", targets: ["Support", "ChannelStore", "Workflow", "Secrets", "Engines"]),
]

var targets: [Target] = [
    .target(name: "Support"),
    .target(name: "Secrets", dependencies: ["Support"]),
    .target(name: "ChannelStore", dependencies: ["Support"]),
    .target(name: "Workflow", dependencies: ["Support", "ChannelStore"]),
    .target(name: "Engines", dependencies: ["Support"]),

    .testTarget(name: "SupportTests", dependencies: ["Support"]),
    .testTarget(name: "SecretsTests", dependencies: ["Secrets", "Support"]),
    .testTarget(name: "ChannelStoreTests", dependencies: ["ChannelStore", "Support"]),
    .testTarget(name: "WorkflowTests", dependencies: ["Workflow", "ChannelStore", "Support"]),
    .testTarget(name: "EnginesTests", dependencies: ["Engines", "Support"]),
]

#if os(macOS)
products.append(.executable(name: "YTA", targets: ["YTAApp"]))
targets += [
    .target(name: "DesignSystem"),
    .target(name: "Canvas", dependencies: ["DesignSystem", "Workflow", "Support"]),
    .executableTarget(
        name: "YTAApp",
        dependencies: ["DesignSystem", "Canvas", "Workflow", "ChannelStore", "Engines", "Secrets", "Support"]
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
