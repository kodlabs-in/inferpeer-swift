# Changelog

All notable changes to InferPeer are documented here.

## 1.0.0 - 2026-09-19

- Replaced implicit cluster routing with a generic direct-resource API: discover, pair, inspect,
  and run on one exact local or remote resource with no forwarding or fallback.
- Added the `inferpeer.v2` Protobuf/gRPC surface, authenticated TLS sessions, certificate pinning,
  one-time invitations, durable credentials, reconnect, bounded streams, cancellation, timeout,
  same-process replay, and owner-scoped resumable image assets.
- Added live immutable resource snapshots with explicit connectivity, execution availability,
  model readiness, telemetry freshness, and five-second host heartbeats.
- Added package-owned model acquisition: a pinned Ed25519 starter catalog, immutable HTTPS files,
  resumable staging, exact size/SHA-256 verification, atomic registration, import, lifecycle, and
  container-path recovery after application updates.
- Added replaceable runtime adapters for native llama.cpp/libmtmd and MLX. The 1.0 signed catalog
  ships stable Qwen3 0.6B MLX text and SmolVLM2 500M Q8 still-image entries plus a beta native
  Qwen3 Q8 text entry.
- Added deterministic tests for direct routing, transport mapping, pairing and authorization,
  model-store recovery, corrupt content, restart behavior, lifecycle admission, and text/vision
  task boundaries.
- Preserved existing public cluster and audio-facing types for source compatibility. Speech/audio
  are not part of the 1.0 catalog, test apps, or support claim.

## 0.1.0 - 2026-09-18

- Added the original ten-library Swift package architecture and versioned Protobuf protocol.
- Added durable caller outbox, coordinator jobs, replay cursors, queue limits, retention tombstones,
  conversation ordering, authenticated gRPC transport, MLX execution, telemetry, and CI gates.
- Adopted Apache License 2.0 and recorded resolved dependency/model license notices.
