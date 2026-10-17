// swift-tools-version: 6.4
// Linerale — iOS 27 music & podcast player (SPM multi-module clean architecture)
import PackageDescription

let package = Package(
    name: "Linerale",
    // The App host enforces iOS 27 via IPHONEOS_DEPLOYMENT_TARGET in
    // App/project.yml and `@available(iOS 27, *)` guards on 27-only APIs.
    // swift-tools-version: 6.4 maps to Xcode 27 / the iOS 27 SDK toolchain.
    platforms: [
        .iOS(.v27)
    ],
    products: [
        .library(name: "LineraleDomain", targets: ["LineraleDomain"]),
        .library(name: "LineraleData", targets: ["LineraleData"]),
        .library(name: "LineralePlayback", targets: ["LineralePlayback"]),
        .library(name: "LineraleUI", targets: ["LineraleUI"]),
    ],
    targets: [
        // Domain: pure Swift, no Apple frameworks beyond Foundation.
        .target(name: "LineraleDomain"),
        .testTarget(name: "LineraleDomainTests", dependencies: ["LineraleDomain"]),

        // Data: networking + local file/Realm-backed cache (no external deps).
        .target(name: "LineraleData", dependencies: ["LineraleDomain"]),
        .testTarget(name: "LineraleDataTests", dependencies: ["LineraleData"]),

        // Playback: AVFoundation + Now Playing bridge.
        .target(name: "LineralePlayback", dependencies: ["LineraleDomain", "LineraleData"]),
        .testTarget(name: "LineralePlaybackTests", dependencies: ["LineralePlayback"]),

        // UI: SwiftUI scenes; depends on all inner layers.
        .target(name: "LineraleUI", dependencies: ["LineraleDomain", "LineralePlayback", "LineraleData"]),
        .testTarget(name: "LineraleUITests", dependencies: ["LineraleUI"]),
    ]
)
