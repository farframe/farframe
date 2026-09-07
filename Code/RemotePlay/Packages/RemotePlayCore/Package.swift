// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RemotePlayCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(name: "ExperienceDomain", targets: ["ExperienceDomain"]),
        .library(name: "InputCore", targets: ["InputCore"]),
        .library(name: "StreamingCore", targets: ["StreamingCore"]),
        .library(name: "AppleMediaCore", targets: ["AppleMediaCore"]),
        .library(name: "AccountsAndSecurity", targets: ["AccountsAndSecurity"]),
        .library(name: "CommerceCore", targets: ["CommerceCore"]),
        .library(name: "FarframeStorefront", targets: ["FarframeStorefront"]),
        .library(name: "FarframeCommerceUI", targets: ["FarframeCommerceUI"]),
        .library(name: "PlayStationRemotePlay", targets: ["PlayStationRemotePlay"]),
        .library(name: "PlayStationRemotePlayUI", targets: ["PlayStationRemotePlayUI"]),
    ],
    targets: [
        .binaryTarget(
            name: "ChiakiNative",
            path: "Binaries/ChiakiNative.xcframework"
        ),
        .target(name: "ExperienceDomain"),
        .target(
            name: "InputCore",
            dependencies: ["ExperienceDomain"],
            linkerSettings: [
                .linkedFramework("CoreHaptics"),
                .linkedFramework("GameController"),
            ]
        ),
        .target(name: "StreamingCore", dependencies: ["ExperienceDomain", "InputCore"]),
        .target(
            name: "AppleMediaCore",
            dependencies: ["ExperienceDomain", "StreamingCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .target(
            name: "AccountsAndSecurity",
            dependencies: ["ExperienceDomain"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(name: "CommerceCore"),
        .target(
            name: "FarframeStorefront",
            dependencies: ["CommerceCore"],
            linkerSettings: [.linkedFramework("StoreKit")]
        ),
        .target(
            name: "FarframeCommerceUI",
            dependencies: ["CommerceCore", "FarframeStorefront"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("StoreKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .target(
            name: "PlayStationRemotePlay",
            dependencies: [
                "AccountsAndSecurity",
                "AppleMediaCore",
                "ExperienceDomain",
                "InputCore",
                "StreamingCore",
                "ChiakiNative",
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .target(
            name: "PlayStationRemotePlayUI",
            dependencies: ["ExperienceDomain", "PlayStationRemotePlay"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "RemotePlayCoreTests",
            dependencies: [
                "ExperienceDomain",
                "InputCore",
                "StreamingCore",
                "AppleMediaCore",
                "AccountsAndSecurity",
                "CommerceCore",
                "FarframeStorefront",
                "PlayStationRemotePlay",
                "PlayStationRemotePlayUI",
            ]
        ),
    ]
)
