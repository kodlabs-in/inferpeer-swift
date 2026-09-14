# InferPeer

InferPeer is an experimental Swift package for private, text-only inference across trusted Apple
devices on an approved local network. A host app can act as a caller, coordinator, worker, or a
combination of those roles.

> Status: experimental `0.1.0` development. All ten package products now have their initial
> implementation and unit-test coverage. Physical-device and real-model validation belongs to the
> upcoming InferPeer sandbox app and is not implied by the package test suite.

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

- Swift 6.1 or later
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

## Current validation boundary

The package suite validates contracts, persistence, security, discovery policy, telemetry privacy,
MLX adapter behavior through a deterministic runtime double, facade lifecycle, and real macOS
loopback gRPC/TLS integration. The following checks still require the sandbox app:

- real model loading and generation on supported Apple hardware;
- Bonjour discovery and mTLS traffic between separate devices;
- backgrounding, thermal pressure, memory pressure, cancellation, and reconnection behavior;
- iPhone, iPad, and Mac installation and end-to-end testing.
