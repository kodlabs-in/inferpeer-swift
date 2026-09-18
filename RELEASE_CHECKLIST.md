# Experimental release checklist

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
- [ ] Create and push the `0.1.0` tag only after every demo gate above passes.
