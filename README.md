# InferPeer

InferPeer is an experimental Swift package for distributing private, text-only inference across
trusted Apple devices on an approved local network. A host app can act as a caller, coordinator,
worker, or a combination of those roles.

> Status: experimental `0.1.0` development. `InferPeerProtocol`, `InferPeerInference`,
> `InferPeerCore`, `InferPeerStorage`, `InferPeerSecurity`, and `InferPeerGRPC` are implemented;
> the remaining products are scaffolds rather than completed capabilities.

## Package structure

This repository publishes one Swift package, `inferpeer-swift`, with ten library products:

1. `InferPeerProtocol`
2. `InferPeerInference`
3. `InferPeerCore`
4. `InferPeerStorage`
5. `InferPeerSecurity`
6. `InferPeerGRPC`
7. `InferPeerDiscovery`
8. `InferPeerTelemetry`
9. `InferPeerMLX`
10. `InferPeer`

Implementation proceeds in that dependency-aware order. `InferPeerMLX` remains opt-in so a
caller-only consumer does not link the MLX runtime.

## Requirements

- Swift 6.1 or later
- macOS 15 or later, or iOS/iPadOS 18 or later
- `swift-format` and `SwiftLint` for local quality checks
- Buf 1.71 or later for Protobuf linting and generation

Install the development tools with Homebrew:

```sh
brew install buf swift-format swiftlint
```

Run the complete local check suite:

```sh
make check
```

Use `make format`, `make lint`, `make build`, or `make test` for individual tasks. The lint policy
warns when cyclomatic complexity exceeds 10 and fails when it exceeds 15.

The language-neutral schema lives in `Protos/inferpeer/v1`. Regenerate its committed Swift types
and gRPC service bindings with `make generate-protocol`; the command builds matching generators
from the resolved SwiftProtobuf and gRPC Swift Protobuf dependencies.

`InferPeerGRPC` supplies the concrete gRPC Swift 2 transport for caller and worker sessions. It
uses HTTP/2 over mutually authenticated TLS, endpoint-specific coordinator certificate pins,
certificate-bound peer authorization, protocol negotiation, ordered message metadata, explicit
interface and endpoint allowlists, message-size limits, and bounded streams that fail instead of
silently dropping messages. Integration tests exercise real TCP and TLS on macOS loopback.

The next module is `InferPeerDiscovery`. Physical iPhone and iPad transport validation remains a
sandbox-app milestone because a Swift package cannot by itself be installed and run on a device.
