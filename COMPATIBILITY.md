# Compatibility report

This report distinguishes package checks from device claims. Passing the package suite does not by
itself establish real-model or physical-device support.

## Current package baseline

| Item | Current value |
| --- | --- |
| Swift tools version | 6.3 |
| Declared platforms | macOS 15+, iOS/iPadOS 18+ |
| Local validation host | MacBook Pro (Mac17,2), Apple M5, 32 GB, macOS 27.0 (26A428) |
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

The official Swift 6.3.3 toolchain package was signature- and notarization-verified before local
installation. A standalone 6.3.3 compiler cannot be paired with this host's newer Xcode 27 SDK, so
CI pins `DEVELOPER_DIR` to Xcode 26.6, whose matching Swift 6.3.3 toolchain performs the clean
minimum-version gate after changes are pushed.

## Validation matrix

| Environment | Package build/tests | Real MLX model | Cross-device mTLS/Bonjour | Lifecycle/pressure |
| --- | --- | --- | --- | --- |
| Mac17,2, macOS 27.0 (26A428) | 190 tests and full local gate | Pass | Coordinator and local worker pass | Deterministic pressure doubles |
| iPhone15,4, iOS 26.5.2 (23F84) | Sandbox build/run pass | Pass | Caller and coordinator pass | Coordinator lifecycle pass; failure matrix passes |
| iPad14,3, iPadOS 27.0 (24A437) | Sandbox build/run pass | Pass | Caller, coordinator, and remote worker pass | Coordinator lifecycle pass; failure matrix passes |

The `InferPeer` and `InferPeerMLX` targets compile for a generic arm64 iOS 18 destination with Xcode
27.0 and Swift 6.4. The separate sandbox was also signed, installed, and run on the physical iPhone
and iPad listed above.

The independent `Fixtures/CallerOnlyConsumer` package is built by `make check` and CI. It imports
only the `InferPeer` product and provides evidence that a downstream caller target compiles without
linking the MLX adapter.

SwiftPM's API breakage diagnostic compared every library product against commit `068a4f5` and found
no breaking changes. The versioned Protobuf schemas and committed generated Swift/gRPC sources are
unchanged from that baseline.

## Pinned-model results

All measurements below used `mlx-community/Qwen3-0.6B-4bit` at revision
`73e3e38d981303bc594367cd910ea6eb48349da8`. The verified `model.safetensors` SHA-256 was
`392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2`; the declared context limit
was 40,960 tokens.

| Device | Load | First text | Generation | Throughput | Peak app memory |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mac17,2 | 0.824 s | 0.051 s | 0.294 s | 108.959 tok/s | 1,278,656,512 bytes |
| iPhone15,4 | 1.140 s | 0.118 s | 0.495 s | 64.617 tok/s | 746,078,208 bytes |
| iPad14,3 | 1.215 s | 0.066 s | 0.468 s | 68.434 tok/s | 758,267,904 bytes |

The snapshot was bundled only by the non-shipping sandbox and inference completed without a model
download on every device. The package itself does not bundle model weights.

## Physical cluster results

- iPhone caller to the Mac coordinator-local MLX worker completed 36 ordered events in one attempt;
  coordinator acceptance was 0.056 seconds.
- iPhone caller through the Mac coordinator to the iPad MLX worker completed 36 ordered events in
  one attempt; coordinator acceptance was 0.164 seconds.
- iPad caller to the iPhone coordinator-local MLX worker completed an authenticated streamed
  request.
- iPhone caller to the iPad coordinator-local MLX worker completed an authenticated streamed
  request.
- Removing the iPad worker during a 512-token request produced one interruption and one clean retry:
  612 ordered events across two attempts, without mixed terminal output.
- A deterministic sandbox-only first-attempt interruption on the physical iPad measured 0.071
  seconds from the interruption event to resumed generation: 526 ordered events across two attempts
  with one interruption and successful real-model completion.
- Caller disconnect/reconnect resumed after acknowledged cursor 699 and replayed 504 events.
- A Mac coordinator process restart preserved the durable request/cursor and replayed 504 events.
- Thirty sequential idle-LAN submissions measured 0.012-second median and 0.106-second p95
  coordinator acceptance, below the 0.250-second target.
- On both mobile devices, foreground coordinators changed local-worker participation to unavailable
  on background. A caller then failed with the expected deadline while the coordinator was
  suspended; foregrounding restored participation and the same unconsumed invitation rejoined and
  streamed successfully (0.023 seconds for the iPad coordinator and 0.020 seconds for the iPhone
  coordinator).
- The sandbox failure matrix passed on Mac, iPhone, and iPad for model-load failure, low-memory and
  thermal refusal, no eligible worker, full queue, database quota, timeout, and both terminal-race
  orderings.

Both mobile devices hosted inbound coordinator traffic on the current LAN. The sandbox discovers
the active Wi-Fi interface instead of assuming `en0`, and transport path enforcement revalidates a
disallowed update after a one-second grace period before closing an established listener.

## Remaining release gates

The release owner explicitly waived router-disconnect and packet-capture validation for `0.1.0` on
2026-09-18. Source inspection found no package or sandbox runtime HTTP/download path, and the MLX
adapter accepts only a local directory URL, but that is not equivalent to an offline packet-capture
pass and no such claim is made here.

The clean-checkout CI gate passed using the pinned Xcode 26.6/Swift 6.3.3 environment. The remaining
publication action is creating and pushing the `0.1.0` tag.

The package repository intentionally contains no production or sandbox application. Physical-device
evidence comes from the separate sibling sandbox host. Track every remaining gate in
`RELEASE_CHECKLIST.md`; do not tag `0.1.0` while any demo gate is unchecked.
