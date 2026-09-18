# InferPeer

![InferPeer logo](Documentation/Branding/inferpeer-logo-mark.png)

InferPeer is an experimental Swift package for private, text-only inference across trusted Apple
devices on an approved local network. A host app can act as a caller, coordinator, worker, or a
combination of those roles.

> Status: experimental `0.1.0` development. All ten package products have implementation and
> unit-test coverage. Physical-device and real-model results are recorded separately in the
> compatibility report and are not implied by the package test suite alone.

## Products

| Product | Responsibility |
| --- | --- |
| `InferPeerProtocol` | Versioned Protobuf messages and protocol negotiation |
| `InferPeerInference` | Text-generation requests, model descriptors, events, and backend contracts |
| `InferPeerCore` | Scheduling, request lifecycles, worker control, trust, and transport contracts |
| `InferPeerStorage` | Durable GRDB stores for jobs, events, peers, models, and the caller outbox |
| `InferPeerSecurity` | Device identity, pairing invitations, certificate verification, and secrets |
| `InferPeerGRPC` | Bounded mTLS gRPC transport for caller and worker sessions |
| `InferPeerDiscovery` | Wi-Fi Bonjour discovery, advertisement, and numeric LAN endpoint validation |
| `InferPeerTelemetry` | Content-free timing events and host/platform worker-status sampling |
| `InferPeerMLX` | Serialized local MLX text generation from a verified model directory |
| `InferPeer` | Role-aware facade that composes the focused modules through injected dependencies |

`InferPeerMLX` is opt-in. The umbrella `InferPeer` product accepts any `InferenceBackend` and does
not link MLX into caller-only or coordinator-only applications.

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
only the products required by the host application. A worker using the production MLX adapter
typically imports both modules:

```swift
import InferPeer
import InferPeerMLX
```

## Local model policy

`MLXInferenceBackend` loads a model from a host-provided local directory. InferPeer does not
download models, execute tool calls, or send prompts and generated text to telemetry. The host app
is responsible for acquiring a compatible model, verifying it, registering its descriptor and
local path, and injecting the backend into `InferPeerNode`.

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

The language-neutral schema lives in `Protos/inferpeer/v1`. Its generated Swift types and gRPC
service bindings are committed so package consumers do not need Buf or generator plugins. After a
schema change, regenerate them with:

```sh
make generate-protocol
```

`make check` also builds `Fixtures/CallerOnlyConsumer`, an independent downstream package that
imports only `InferPeer`. This protects the caller-only integration boundary and ensures the MLX
adapter remains opt-in.

## Documentation

- [Compatibility report](COMPATIBILITY.md)
- [Security boundary and host responsibilities](SECURITY.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Experimental release checklist](RELEASE_CHECKLIST.md)
- [Changelog](CHANGELOG.md)
- DocC overview in `Sources/InferPeer/InferPeer.docc`

## Current validation boundary

The package suite validates contracts, persistence, security, discovery policy, telemetry privacy,
MLX adapter behavior through a deterministic runtime double, facade lifecycle, and real macOS
loopback gRPC/TLS integration. A separate sibling sandbox has exercised real local-model inference,
cross-device mTLS/Bonjour traffic, lifecycle transitions, retries, replay, and failure policy on
Mac, iPhone, and iPad. See `COMPATIBILITY.md` for the exact evidence and remaining limitations. The
sandbox and model weights are intentionally not part of this package repository.

## License

InferPeer is available under the [Apache License 2.0](LICENSE). Dependencies and model artifacts
remain governed by their respective licences; see [Third-party notices](THIRD_PARTY_NOTICES.md).
