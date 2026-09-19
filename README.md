# InferPeer

![InferPeer logo](Documentation/Branding/inferpeer-logo-mark.png)

InferPeer is an experimental Swift package for private local AI on directly addressable Apple
resources. An app discovers approved nearby endpoints, inspects their current capabilities, and
runs a complete request on the exact local or remote resource it selects.

> Status: the `0.2.0` direct-resource API and `inferpeer.v2` protocol are under development. The
> package tests establish software contracts; they do not establish the PRD's physical-device,
> real-model, lifecycle, security, or performance release gates.

## Products

| Product | Responsibility |
| --- | --- |
| `InferPeerProtocol` | Isolated v1 and v2 Protobuf messages and protocol negotiation |
| `InferPeerInference` | Typed text, vision, transcription, and speech requests plus runtime contracts |
| `InferPeerCore` | Direct resource, discovery, session, run, telemetry, and error contracts |
| `InferPeerStorage` | Durable GRDB metadata, verified model manifests, deduplication, and owner-scoped resumable assets |
| `InferPeerSecurity` | Device identity, pairing invitations, certificate verification, and secrets |
| `InferPeerGRPC` | Generated v2 client/server adapters, authenticated session recovery, and the retained bounded v1 transport |
| `InferPeerDiscovery` | Wi-Fi Bonjour discovery, advertisement, and numeric LAN endpoint validation |
| `InferPeerTelemetry` | Content-free timing events and host/platform worker-status sampling |
| `InferPeerModelStore` | Signed catalogs, resource-aware recommendations, package-owned downloads/imports, verification, registry, and adapter lifecycle |
| `InferPeerMLX` | Serialized local MLX text generation from a verified model directory |
| `InferPeer` | Direct-resource facade with explicit local, discovery, exposure, and session dependencies |

`InferPeerMLX` is opt-in. The umbrella `InferPeer` product accepts any `InferenceBackend` and does
not require an inference engine merely to discover or connect to remote resources.

Multimodal adapters implement `DirectInferenceRuntime` and explicitly register the tasks supported
by each exact artifact. The compatibility `InferenceBackend` path remains text-only and is adapted
internally without claiming vision, transcription, or speech support.

## Requirements

- Swift 6.3 or later
- macOS 15 or later, or iOS/iPadOS 18 or later
- `swift-format` and SwiftLint for local quality checks
- Buf 1.71 or later for Protobuf linting and generation

Install the development tools with Homebrew:

```sh
brew install buf swift-format swiftlint
```

Add `https://github.com/kodlabs-in/inferpeer-swift.git` as a Swift Package dependency, then import
only the products required by the host application. A host using the MLX adapter for its `.local`
resource imports both modules:

```swift
import InferPeer
import InferPeerMLX
```

## Direct local execution

The local executor uses the same public query, event, timeout, queue, cancellation, memory, and
model-lifecycle contracts as a remote resource, without opening a loopback connection:

```swift
let inferPeer = try InferPeer(
    configuration: InferPeerConfiguration(
        localResource: LocalResourceConfiguration(
            displayName: "This Mac",
            platform: platform
        ),
        localRuntime: MLXInferenceBackend(),
        localModels: [verifiedArtifact],
        defaultTextModel: verifiedArtifact.descriptor.reference
    )
)

let run = try await inferPeer.run(
    .text(
        model: .exact(verifiedArtifact.descriptor.reference),
        messages: [.user("Hello")]
    ),
    resourceId: .local
)

for try await event in run.events {
    // Render ordered, bounded events.
}
let result = try await run.result()
```

For a remote resource, the host injects discovery, exposure, and authenticated session adapters,
pairs the endpoint, and passes that exact `ResourceID` to `run`. InferPeer never reroutes a failed
request to another resource.

## Model store and runtime adapters

`InferPeerModelStore` owns model acquisition. It verifies a signed built-in catalog, optionally
accepts signed HTTPS catalog updates, evaluates each exact artifact against the selected local or
connected resource, downloads into durable staging, verifies every declared size and SHA-256,
then atomically registers the installation. Directory and archive imports enter the same verified
registry path and require a manifest.

The store recommends from actual `ResourceSnapshot` facts—OS, hardware identifier, memory,
storage, chip features, and registered adapter versions. A recommendation never changes the
resource or silently substitutes a model. Missing measurements remain explicit compatibility
reasons.

Hosts register replaceable `InferPeerRuntimeAdapter` objects when opening the store. The adapter
owns its tokenizer, prompt template, preprocessing, generation loop, and loaded session; the store
owns download, import, hashes, persistence, lifecycle, and removal. `InferPeerConfiguration` can
expose the opened store through the umbrella facade.

Package tests use deterministic signed catalogs, model bytes, and mock llama.cpp/WhisperKit
adapter objects. Shipping catalog entries still require immutable publisher artifacts and the
physical-device validation records described in `RELEASE_CHECKLIST.md`; unvalidated entries
cannot be marked stable.

## Local-network setup

An iOS or iPadOS sandbox app that uses Bonjour must provide a user-facing
`NSLocalNetworkUsageDescription` and include `_inferpeer._tcp` in `NSBonjourServices`. Discovery is
restricted to Wi-Fi and accepts only numeric private, link-local, or unique-local endpoints;
loopback is disabled by default.

## Development

Run the complete local quality gate:

```sh
make check
```

Individual commands are also available:

```sh
make format
make lint
make build
make test
```

The lint policy warns when cyclomatic complexity exceeds 10 and fails when it exceeds 15. It also
enforces bounds for function, type, and file length.

The language-neutral schemas live in `Protos/inferpeer/v1` and `Protos/inferpeer/v2`. The v1
cluster wire contract is not compatible with a v2 direct resource. Generated Swift types and gRPC
service bindings are committed so package consumers do not need Buf or generator plugins. After a
schema change, regenerate them with:

```sh
make generate-protocol
```

`make check` also builds `Fixtures/CallerOnlyConsumer`, an independent downstream package that
imports only `InferPeer`. This protects the engine-optional integration boundary and ensures the
MLX adapter remains opt-in.

## Documentation

- [Compatibility report](COMPATIBILITY.md)
- [Security boundary and host responsibilities](SECURITY.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Experimental release checklist](RELEASE_CHECKLIST.md)
- [Changelog](CHANGELOG.md)
- DocC overview in `Sources/InferPeer/InferPeer.docc`

## Current validation boundary

The package suite validates the v2 direct API, fixed-destination routing, local bypass, queueing,
cancellation, timeouts, bounded event delivery, model lifecycle and memory admission, resource
state, task validation, owner-scoped resumable assets, request deduplication, terminal races,
restart interruption, generated protocol contracts, and the retained v1 behavior. The sibling
`InferPeerSandbox` app is the integration host used to build and exercise the package on macOS and
iOS; no RunLocalAI test app is created.

The remaining v2 release gates require the exact physical devices, approved model artifacts,
native text/VLM/ASR/TTS adapters, live Apple TLS/listener composition, lifecycle entitlements,
packet-capture/security evidence, and measured benchmarks listed in `RELEASE_CHECKLIST.md` and
`COMPATIBILITY.md`.

## License

InferPeer is available under the [Apache License 2.0](LICENSE). Dependencies and model artifacts
remain governed by their respective licences; see [Third-party notices](THIRD_PARTY_NOTICES.md).
