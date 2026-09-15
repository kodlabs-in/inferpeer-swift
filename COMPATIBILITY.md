# Compatibility report

This report distinguishes package checks from device claims. Passing the package suite does not by
itself establish real-model or physical-device support.

## Current package baseline

| Item | Current value |
| --- | --- |
| Swift tools version | 6.3 |
| Declared platforms | macOS 15+, iOS/iPadOS 18+ |
| Local validation host | MacBook Pro (Mac17,2), Apple M5, 32 GB, macOS 26.6.2 |
| Local toolchain observed | Xcode 27.0 (27A266a), Swift 6.4 |
| Dependency reproducibility | Exact revisions recorded in `Package.resolved` |
| MLX linkage | Opt-in `InferPeerMLX`; excluded from the `InferPeer` target graph |

Direct dependency versions currently resolved include SwiftProtobuf 1.38.1, GRDB 7.10.0,
gRPC Swift 2.4.3, gRPC NIO transport 2.9.2, gRPC Protobuf 2.4.1, Swift Certificates 1.19.4,
Swift Crypto 4.5.2, SwiftNIO 2.102.0, NIOSSL 2.37.4, MLX Swift 0.31.6, MLX Swift LM 3.31.4,
and Swift Transformers 1.3.4.

Swift 6.3 is the effective minimum because MLX Swift 0.31.6 declares that tools version. The
package manifest and consumer fixture use the same floor so unsupported Swift 6.1 and 6.2
toolchains fail clearly during manifest evaluation.

## Validation matrix

| Environment | Package build/tests | Real MLX model | Cross-device mTLS/Bonjour | Lifecycle/pressure |
| --- | --- | --- | --- | --- |
| Local Apple Silicon Mac | Automated gate | Not yet verified | Loopback only | Deterministic doubles |
| Physical iPhone | Not yet run | Not yet verified | Not yet verified | Not yet verified |
| Physical iPad | Not yet run | Not yet verified | Not yet verified | Not yet verified |

The `InferPeer` and `InferPeerMLX` targets compile for a generic arm64 iOS 18 destination with Xcode
27.0 and Swift 6.4. This is a cross-compilation check, not a physical-device run.

Xcode currently detects a physical iPhone 15 (iPhone15,4) on iOS 26.5.2. An iPad (iPad14,3) on
iPadOS 26.6.2 is paired, but `xctrace` reported it offline during the latest inventory check.
Detection is not package execution evidence.

The independent `Fixtures/CallerOnlyConsumer` package is built by `make check` and CI. It imports
only the `InferPeer` product and provides evidence that a downstream caller target compiles without
linking the MLX adapter.

## Manual device gate

The future sandbox app must record exact device model, OS, model ID/revision/hash, context size,
first-text latency, tokens per second, model load time, peak app memory, cancellation recovery, and
network observations. Test foreground coordinator behavior, background unavailability, reconnect,
router-internet disconnection, and packet capture on iPhone, iPad, and Mac.

The package repository intentionally contains no production or sandbox application, so physical
iOS execution requires the separate future sandbox host. Track each remaining gate in
`RELEASE_CHECKLIST.md`; do not tag `0.1.0` while any demo gate is unchecked.
