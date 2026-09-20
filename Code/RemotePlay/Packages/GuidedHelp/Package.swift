// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GuidedHelp",
    platforms: [.iOS(.v18), .macOS(.v15), .visionOS(.v2)],
    products: [.library(name: "GuidedHelp", targets: ["GuidedHelp"])],
    targets: [
        .target(name: "GuidedHelp"),
        .testTarget(name: "GuidedHelpTests", dependencies: ["GuidedHelp"]),
    ]
)
