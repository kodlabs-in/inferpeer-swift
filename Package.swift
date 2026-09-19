// swift-tools-version: 6.3

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
        .library(name: "InferPeerModelStore", targets: ["InferPeerModelStore"]),
        .library(name: "InferPeerApple", targets: ["InferPeerApple"]),
        .library(name: "InferPeerMLX", targets: ["InferPeerMLX"]),
        .library(name: "InferPeerLlama", targets: ["InferPeerLlama"]),
        .library(name: "InferPeerWhisperKit", targets: ["InferPeerWhisperKit"]),
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
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            .upToNextMinor(from: "0.31.6")
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            .upToNextMajor(from: "3.31.4")
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            .upToNextMinor(from: "1.3.3")
        ),
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.1.0"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-docc-plugin",
            .upToNextMajor(from: "1.5.0")
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
                .product(name: "Crypto", package: "swift-crypto"),
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
            dependencies: ["InferPeerCore", "InferPeerInference", "InferPeerProtocol"]
        ),
        .target(
            name: "InferPeerModelStore",
            dependencies: [
                "InferPeerCore",
                "InferPeerInference",
                "InferPeerProtocol",
                "InferPeerStorage",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "InferPeerApple",
            dependencies: [
                "InferPeerCore",
                "InferPeerModelStore",
            ]
        ),
        .target(
            name: "InferPeerMLX",
            dependencies: [
                "InferPeerCore",
                "InferPeerInference",
                "InferPeerModelStore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .target(
            name: "InferPeerLlamaBridge",
            dependencies: ["LlamaFramework"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-std=c++17"])]
        ),
        .target(
            name: "InferPeerLlama",
            dependencies: [
                "InferPeerCore",
                "InferPeerInference",
                "InferPeerLlamaBridge",
                "InferPeerModelStore",
            ]
        ),
        .target(
            name: "InferPeerWhisperKit",
            dependencies: [
                "InferPeerCore",
                "InferPeerInference",
                "InferPeerModelStore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .target(
            name: "InferPeer",
            dependencies: [
                "InferPeerCore",
                "InferPeerInference",
                "InferPeerProtocol",
                "InferPeerGRPC",
                "InferPeerStorage",
                "InferPeerDiscovery",
                "InferPeerSecurity",
                "InferPeerTelemetry",
                "InferPeerModelStore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
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
                "InferPeerModelStore",
                "InferPeerApple",
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
            name: "InferPeerCoordinatorTests",
            dependencies: [
                "InferPeerCore",
                "InferPeerInference",
                "InferPeerProtocol",
                "InferPeerStorage",
            ]
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
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .testTarget(
            name: "InferPeerDiscoveryTests",
            dependencies: ["InferPeerDiscovery", "InferPeerCore"]
        ),
        .testTarget(
            name: "InferPeerTelemetryTests",
            dependencies: ["InferPeerTelemetry", "InferPeerCore", "InferPeerInference"]
        ),
        .testTarget(
            name: "InferPeerModelStoreTests",
            dependencies: [
                "InferPeer",
                "InferPeerModelStore",
                "InferPeerCore",
                "InferPeerInference",
                "InferPeerProtocol",
                "InferPeerStorage",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "InferPeerMLXTests",
            dependencies: ["InferPeerMLX", "InferPeerInference", "InferPeerProtocol"]
        ),
        .testTarget(
            name: "InferPeerLlamaTests",
            dependencies: [
                "InferPeerLlama",
                "InferPeerInference",
                "InferPeerModelStore",
                "InferPeerProtocol",
            ]
        ),
        .testTarget(
            name: "InferPeerWhisperKitTests",
            dependencies: [
                "InferPeerWhisperKit",
                "InferPeerInference",
                "InferPeerModelStore",
                "InferPeerProtocol",
            ]
        ),
        .testTarget(
            name: "InferPeerFacadeTests",
            dependencies: [
                "InferPeer",
                "InferPeerCore",
                "InferPeerGRPC",
                "InferPeerInference",
                "InferPeerProtocol",
                "InferPeerStorage",
                "InferPeerTelemetry",
            ]
        ),
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10982/llama-b10982-xcframework.zip",
            checksum: "a37d89f31a4bafecf6e5b619f0fb6c4d1783adcd1e475e976d52f98396a2c864"
        ),
    ]
)
