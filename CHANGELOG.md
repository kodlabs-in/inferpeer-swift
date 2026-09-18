# Changelog

All notable changes to InferPeer will be documented here.

## Unreleased

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
