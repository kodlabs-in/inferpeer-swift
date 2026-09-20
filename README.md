# InferPeer

![InferPeer logo](Documentation/Branding/inferpeer-logo-mark.png)

InferPeer is a Swift package for private, direct local AI across Apple devices. An app discovers
approved nearby resources, inspects their live capabilities, and runs a request on the exact local
or remote resource and exact model selected by the host app.

> Release status: `1.0.0` supports streaming text generation and still-image understanding on
> foreground iOS, iPadOS, and macOS hosts. Audio is outside this release. Existing audio-facing
> public types and the optional WhisperKit target remain available for source compatibility, but
> they are not advertised by the signed 1.0 starter catalog.

## Products

| Product | Responsibility |
| --- | --- |
| `InferPeerProtocol` | Isolated v1 and v2 Protobuf messages and protocol negotiation |
| `InferPeerInference` | Typed inference requests, manifests, events, and runtime contracts |
| `InferPeerCore` | Direct-resource discovery, sessions, runs, telemetry, and errors |
| `InferPeerStorage` | Durable metadata, verified manifests, resumable assets, and replay |
| `InferPeerSecurity` | Identity, single-use invitations, certificate pins, and credentials |
| `InferPeerGRPC` | Authenticated TLS client/server adapters and bounded streaming |
| `InferPeerDiscovery` | Wi-Fi Bonjour discovery, advertisement, and LAN validation |
| `InferPeerTelemetry` | Content-free timing and live resource-status publication |
| `InferPeerModelStore` | Signed catalogs, recommendations, downloads, verification, and lifecycle |
| `InferPeerLlama` | Native llama.cpp text and libmtmd still-image execution |
| `InferPeerMLX` | Apple MLX text execution |
| `InferPeer` | Public direct-resource facade and host composition |

Apps link only the adapters they use. A client-only app can discover and call remote resources
without linking an inference engine. A resource host embeds InferPeer and calls `expose(...)`; the
SDK never installs or wakes a separate daemon.

## Requirements

- Swift 6.3 or later
- iOS/iPadOS 18 or later, or macOS 15 or later
- Apple Silicon for the built-in starter artifacts
- `swift-format`, SwiftLint, and Buf for development checks

Add `https://github.com/kodlabs-in/inferpeer-swift.git` as a Swift Package dependency. A host that
executes MLX locally imports the public facade plus the adapter:

```swift
import InferPeer
import InferPeerMLX
```

## Exact-resource execution

Local execution uses the same typed request and event contracts as remote execution, but remains
in process. Remote execution connects directly to the selected resource. InferPeer does not
forward, reroute, combine device memory, or silently substitute another model.

```swift
let run = try await inferPeer.run(
    .text(
        model: .exact(selectedModel),
        messages: [.user("Hello")]
    ),
    resourceId: selectedResourceID
)

for try await event in run.events {
    // Render ordered, bounded events.
}
let result = try await run.result()
```

Call `discovery()` to browse local Bonjour candidates, `pair(_:)` after explicit user approval,
and `watchResources(_:)` for immutable live resource snapshots. Pairing is single-use and binds the
resource identity, endpoint, certificate pin, and scoped credential. Installed resources reconnect
through stored credentials; wrong pins and unapproved principals fail closed.

## Package-owned model management

Open `InferPeerModelStore` with the signed starter catalog and the runtime adapters supported by the
host. The store evaluates the selected device's OS, hardware identifier, memory, storage, chip
features, and registered adapter versions. The host or user still chooses the exact artifact.

Downloads use immutable HTTPS URLs, durable staging, exact byte counts, SHA-256 hashes, and atomic
registration. Interrupted downloads resume; incomplete content is never exposed as installed.
Registry paths are relative to the current model root, so verified installations survive an app
container change after an update. Imports use the same verification and registry path.

The signed `starter-2026-09-19.6` catalog contains:

| Artifact | Runtime | Tasks | Status |
| --- | --- | --- | --- |
| Qwen3 0.6B 4-bit | MLX | Text | Stable |
| Qwen3 0.6B Q8_0 | llama.cpp | Text | Beta |
| SmolVLM2 500M Q8_0 + projector | llama.cpp/libmtmd | Text + still-image understanding | Stable |

The stable artifacts were downloaded by the package and executed through signed Release builds on
the physical hardware listed in [COMPATIBILITY.md](COMPATIBILITY.md). Model files remain governed
by their upstream licenses and are not stored in this repository.

## Host integration

iOS and iPadOS hosts that use Bonjour must include `_inferpeer._tcp` in `NSBonjourServices` and a
clear `NSLocalNetworkUsageDescription`. A client that selects photos also owns its photo-library
usage description. Resource hosts must forward lifecycle state and stop remote admission when the
foreground execution grant disappears. This release intentionally makes no background-execution
claim.

## Development

Run the complete package gate:

```sh
make check
```

Individual gates are available through `make format`, `make lint`, `make build`, `make test`, and
`make consumer`. SwiftLint warns when cyclomatic complexity exceeds 10 and fails above 15. The
independent caller-only fixture verifies that a remote client does not link MLX or llama.cpp.

Generated Protobuf and gRPC Swift sources are committed so package consumers do not need Buf. Run
`make generate-protocol` after changing files under `Protos/inferpeer`.

## Documentation

- [Compatibility and physical-device evidence](COMPATIBILITY.md)
- [Security boundary and host responsibilities](SECURITY.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [1.0 release checklist](RELEASE_CHECKLIST.md)
- [Changelog](CHANGELOG.md)
- DocC overview in `Sources/InferPeer/InferPeer.docc`

## License

InferPeer is available under the [Apache License 2.0](LICENSE). Dependencies and model artifacts
remain governed by their respective licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
