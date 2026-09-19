# Release checklist

## Experimental 0.2.0 direct-resource release

An unchecked item is a release blocker or external evidence requirement, not an implied capability.

### Automated package evidence

- [x] The direct facade exposes discovery, immutable resource snapshots, fixed-destination runs,
      pairing, exposure, preparation, disconnect/forget, and deterministic stop contracts.
- [x] `.local` uses the in-process executor and cannot fall back to a remote resource.
- [x] Typed task schemas, run events/results, stable errors, v2 Protobuf messages, and all 13 direct
      RPC service methods are generated and Buf-clean.
- [x] Deterministic tests cover resource revisions, local/remote routing boundaries, queueing,
      cancellation, timeouts, memory admission, model lifecycle, output backpressure, request-ID
      conflicts, terminal races, restart interruption, resumable assets, ownership, and corruption.
- [x] Strict formatting, SwiftLint complexity/length rules, warnings-as-errors package tests, and
      the independent engine-optional consumer build pass.
- [x] InferPeer Sandbox builds for macOS and iOS Simulator and uses the direct local facade.
- [x] Generated v2 gRPC client/server adapters, Bonjour TXT negotiation, authenticated
      fixed-endpoint session persistence, bounded reconnect/replay, and lost-ACK reconciliation
      have deterministic integration tests.
- [x] Verified model manifests reject path escape, symlinks, undeclared/missing/corrupt content and
      register atomically without a hidden download path.
- [x] Lifecycle/thermal/battery admission and revisioned telemetry/freshness policies have
      deterministic clock-driven tests and preserve unknown values.
- [x] `InferPeerModelStore` verifies pinned signed catalogs, evaluates actual connected-resource
      memory/storage/OS/chip/adapter facts, owns resumable downloads and manifest imports, commits
      atomic verified installations, reconciles corruption at launch, and safely repairs/removes
      package-managed files with deterministic tests.
- [ ] Live Apple TLS listener/client composition, real certificate-pin rejection, Keychain-backed
      v2 session wiring, and reconnect/replay are exercised through InferPeer Sandbox.
- [ ] The reference llama.cpp text/VLM, WhisperKit ASR, and separate TTS adapters are reproducibly
      built, licensed, registered, and covered by end-to-end tests.

### Physical-device and release evidence

- [ ] Record the exact seven-device hardware/OS/RAM inventory and approved text/VLM/ASR/TTS model
      identities, hashes, formats, and licenses.
- [ ] Demonstrate real iPhone-to-Mac direct TLS gRPC, valid-pin success, wrong-pin rejection,
      local-route enforcement, and an offline `.local` request with no loopback traffic.
- [ ] Complete all 42 directed text smoke pairs, one-to-many no-forwarding audit, modality support
      matrix, owner isolation, malformed-media, storage-full, thermal, memory, and lifecycle cases.
- [ ] Measure the PRD's discovery, throughput, first-output, cancellation, idle telemetry, memory,
      energy, and 30-minute thermal-soak targets in release builds on physical devices.
- [ ] Publish the exact compatibility matrix, adapter build instructions, integration keys,
      benchmark records, and any measured limitations before tagging `0.2.0`.

## Historical 0.1.0 cluster release

Do not tag `0.1.0` until every automated and manual demo gate below has evidence. An unchecked item
is unverified, not an implied capability.

## Automated package evidence

- [x] All ten products are libraries in one Swift package with an acyclic target graph.
- [x] An independent caller-only consumer builds without linking `InferPeerMLX`.
- [x] Versioned Protobuf schemas, committed generated sources, and Buf format/lint checks exist.
- [x] Coordinator tests cover durable acceptance, local and remote execution, retry, restart replay,
      leases, cancellation, caller isolation, retention, and terminal races.
- [x] Security tests cover certificate identity, role-scoped trust, atomic single-use invitations,
      expiry, and revocation.
- [x] Real macOS loopback integration covers bidirectional mTLS caller/worker sessions, malformed
      metadata rejection, bounded backpressure, and a slow consumer with reserved control traffic.
- [x] Storage tests cover migrations, limits, replay ordering, and concurrent revision commits.
- [x] Strict Swift formatting, SwiftLint, cyclomatic-complexity, Buf, Swift warnings-as-errors,
      DocC, and package tests are part of the local/CI gate.

## Physical-device and operational evidence

- [x] Record exact Mac, iPhone, and iPad model identifiers and OS versions in `COMPATIBILITY.md`.
- [x] Build and run a separate sandbox host on all three devices.
- [x] Load a recorded local MLX model revision/hash and complete offline generation on each supported
      worker device.
- [x] Run caller → coordinator-local-worker and caller → coordinator → remote-worker streaming.
- [x] Make the remote worker unavailable and verify one clean retry without mixed or duplicate output.
- [x] Disconnect/reconnect and restart the coordinator; verify durable requests and cursor replay.
- [x] Background and foreground the iPhone/iPad coordinator; verify cluster unavailability and rejoin.
- [x] Exercise model-load failure, low memory, thermal refusal, full queue/disk, timeout, and
      cancel/complete races through the sandbox host.
- [x] Router-disconnect and packet-capture validation was explicitly waived for `0.1.0` by the
      release owner on 2026-09-18; this is a waiver, not evidence that the test passed.
- [x] Record first-text latency, tokens/second, model-load time, peak app memory, interruption
      recovery, device/model/context, and mock-backend coordinator acceptance p95.
- [x] Review the host's non-synchronising Keychain, file protection, backup exclusion, local-network
      usage description, Bonjour service declaration, and content-redacted logging.

## Publication

- [x] Add the repository's Apache License 2.0 source-code `LICENSE`.
- [x] Confirm the resolved Apache-2.0/MIT dependencies and selected Apache-2.0 model are compatible
      with Apache-2.0 distribution, subject to retaining their applicable notices.
- [x] Run `make check` from a clean checkout using the documented minimum supported toolchain.
- [x] Review public API and generated schema diff; update `CHANGELOG.md` and compatibility evidence.
- [x] Create and push the `0.1.0` tag only after every demo gate above passes.
