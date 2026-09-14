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
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            .upToNextMinor(from: "7.10.0")
        ),
        .package(
            url: "https://github.com/apple/swift-certificates.git",
            .upToNextMinor(from: "1.19.4")
        ),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            .upToNextMinor(from: "4.5.1")
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift-2.git",
            .upToNextMinor(from: "2.4.3")
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift-nio-transport.git",
            .upToNextMinor(from: "2.9.2")
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift-protobuf.git",
            .upToNextMinor(from: "2.4.1")
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            .upToNextMinor(from: "2.102.0")
        ),
        .package(
            url: "https://github.com/apple/swift-nio-ssl.git",
            .upToNextMinor(from: "2.37.4")
        ),
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
            dependencies: [
                "InferPeerCore",
                "InferPeerProtocol",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(
                    name: "GRPCNIOTransportHTTP2Posix",
                    package: "grpc-swift-nio-transport"
                ),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .target(
            name: "InferPeerStorage",
            dependencies: [
                "InferPeerCore",
                "InferPeerInference",
                "InferPeerProtocol",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "InferPeerDiscovery",
            dependencies: ["InferPeerCore"]
        ),
        .target(
            name: "InferPeerSecurity",
            dependencies: [
                "InferPeerCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
            ]
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
        .testTarget(
            name: "InferPeerStorageTests",
            dependencies: [
                "InferPeerStorage",
                "InferPeerCore",
                "InferPeerInference",
                "InferPeerProtocol",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "InferPeerSecurityTests",
            dependencies: [
                "InferPeerSecurity",
                "InferPeerCore",
                "InferPeerProtocol",
            ]
        ),
        .testTarget(
            name: "InferPeerGRPCTests",
            dependencies: [
                "InferPeerGRPC",
                "InferPeerCore",
                "InferPeerProtocol",
                "InferPeerSecurity",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
            ]
        ),
    ]
)
