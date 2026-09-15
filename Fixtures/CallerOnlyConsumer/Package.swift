// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CallerOnlyConsumer",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "CallerOnlyConsumer", targets: ["CallerOnlyConsumer"])
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "CallerOnlyConsumer",
            dependencies: [
                .product(name: "InferPeer", package: "inferpeer-swift")
            ]
        )
    ]
)
