# Changelog

All notable changes to InferPeer will be documented here.

## Unreleased

- Added the experimental v2 direct-resource facade with `discovery()`, `resources()`,
  `run(_:resourceId:options:)`, pairing, exposure, explicit model preparation, and deterministic
  shutdown. Local execution uses an in-process path and remote execution never falls back to a
  different resource.
- Added typed text, image-understanding, transcription, and speech-synthesis queries and results,
  stable v2 errors, bounded run/resource streams, queueing, cancellation, timeouts, output
  backpressure, memory admission, and bounded warm-model retention.
- Added the isolated `inferpeer.v2` Protobuf/gRPC surface, SQLite direct-request metadata and
  restart interruption, and owner-scoped resumable asset uploads with exact offsets and SHA-256
  verification.
- Added concrete generated v2 client/server adapters for all 13 RPCs, bounded streaming bridges,
  strict wire mappings, direct Bonjour metadata, authenticated fixed-endpoint session recovery,
  lost-ack reconciliation, and bounded same-process output replay.
- Added the adapter-neutral multimodal runtime contract, verified content-derived model manifests,
  lifecycle/thermal/battery admission policy, and revisioned resource telemetry publication.
- Added `InferPeerModelStore` with pinned Ed25519 catalogs, connected-resource compatibility and
  recommendation explanations, resumable package-owned HTTPS downloads, mandatory-manifest
  imports, atomic hash-verified installation, GRDB lifecycle metadata, adapter sessions, startup
  reconciliation, and safe removal.
- Added v2 state, protocol, facade, query, storage, race, and failure-path tests. InferPeer Sandbox
  now exercises the direct `.local` text and multimodal facade paths on macOS and iOS instead of a
  RunLocalAI test app.

## 0.1.0 - 2026-09-18

- Added the ten-library Swift package architecture and versioned Protobuf protocol.
- Added durable caller outbox, coordinator jobs, replay cursors, queue limits, retention tombstones,
  and conversation revision ordering.
- Added local and remote execution, status-based scheduling, leases, retries, cancellation, and
  typed command rejection.
- Added mutually authenticated gRPC transport, role-scoped trust, single-use pairing, Bonjour
  discovery, and Wi-Fi-only endpoint/socket policy.
- Added the opt-in MLX backend, content-free telemetry, strict formatting/linting, CI, DocC, and an
  independent caller-only consumer fixture.
- Replaced overflow-prone transport buffering with bounded backpressure, ordered delivery, and a
  reserved control slot so text deltas cannot starve cancellation, lease, or heartbeat traffic.
- Added host-driven coordinator-local worker status refresh for foreground/background eligibility.
- Improved Wi-Fi path enforcement by ignoring pre-establishment snapshots and revalidating a
  transient disallowed update before closing established transport resources.
- Added stable, named gRPC error descriptions for host diagnostics.
- Expanded physical-device evidence across Mac, iPhone, and iPad for real MLX inference, mobile
  coordinators, retries, replay, lifecycle rejoin, failure policy, and operational metrics.
- Adopted Apache License 2.0 and completed the resolved dependency/model licence inventory.
