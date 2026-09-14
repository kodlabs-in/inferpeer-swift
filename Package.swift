// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "inferpeer-swift",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "InferPeerProtocol", targets: ["InferPeerProtocol"]),
        .library(name: "InferPeerInference", targets: ["InferPeerInference"]),
        .library(name: "InferPeerCore", targets: ["InferPeerCore"]),
        .library(name: "InferPeerGRPC", targets: ["InferPeerGRPC"]),
        .library(name: "InferPeerStorage", targets: ["InferPeerStorage"]),
        .library(name: "InferPeerDiscovery", targets: ["InferPeerDiscovery"]),
        .library(name: "InferPeerSecurity", targets: ["InferPeerSecurity"]),
        .library(name: "InferPeerTelemetry", targets: ["InferPeerTelemetry"]),
        .library(name: "InferPeerMLX", targets: ["InferPeerMLX"]),
        .library(name: "InferPeer", targets: ["InferPeer"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            .upToNextMinor(from: "1.38.1")
        )
    ],
    targets: [
        .target(
            name: "InferPeerProtocol",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ]
        ),
        .target(
            name: "InferPeerInference",
            dependencies: ["InferPeerProtocol"]
        ),
        .target(
            name: "InferPeerCore",
            dependencies: ["InferPeerProtocol", "InferPeerInference"]
        ),
        .target(
            name: "InferPeerGRPC",
            dependencies: ["InferPeerCore", "InferPeerProtocol"]
        ),
        .target(
            name: "InferPeerStorage",
            dependencies: ["InferPeerCore"]
        ),
        .target(
            name: "InferPeerDiscovery",
            dependencies: ["InferPeerCore"]
        ),
        .target(
            name: "InferPeerSecurity",
            dependencies: ["InferPeerCore"]
        ),
        .target(
            name: "InferPeerTelemetry",
            dependencies: ["InferPeerCore"]
        ),
        .target(
            name: "InferPeerMLX",
            dependencies: ["InferPeerInference"]
        ),
        .target(
            name: "InferPeer",
            dependencies: [
                "InferPeerCore",
                "InferPeerGRPC",
                "InferPeerStorage",
                "InferPeerDiscovery",
                "InferPeerSecurity",
                "InferPeerTelemetry",
            ]
        ),
        .testTarget(
            name: "InferPeerPackageTests",
            dependencies: [
                "InferPeer",
                "InferPeerProtocol",
                "InferPeerInference",
                "InferPeerCore",
                "InferPeerGRPC",
                "InferPeerStorage",
                "InferPeerDiscovery",
                "InferPeerSecurity",
                "InferPeerTelemetry",
                "InferPeerMLX",
            ]
        ),
        .testTarget(
            name: "InferPeerProtocolTests",
            dependencies: [
                "InferPeerProtocol",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "InferPeerInferenceTests",
            dependencies: ["InferPeerInference", "InferPeerProtocol"]
        ),
        .testTarget(
            name: "InferPeerCoreTests",
            dependencies: ["InferPeerCore", "InferPeerInference", "InferPeerProtocol"]
        ),
    ]
)
