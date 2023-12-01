// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LiveKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "LiveKit",
            targets: ["LiveKit"]
        ),
    ],
    dependencies: [
        .package(name: "WebRTC", url: "https://github.com/riotbroadcast/webrtc-xcframework-static.git", .exact("114.5735.09-riot-3")),
        .package(name: "SwiftProtobuf", url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.21.0")),
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMajor(from: "1.5.2")),
    ],
    targets: [
        .systemLibrary(name: "CHeaders"),
        .target(
            name: "LiveKit",
            dependencies: [
                .target(name: "CHeaders"),
                "WebRTC",
                "SwiftProtobuf",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "LiveKitTests",
            dependencies: ["LiveKit"]
        ),
    ]
)
