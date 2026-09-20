# InferPeer 1.0 release checklist

The 1.0 release is text and still-image only. Audio, speech, background iOS execution, forwarding,
automatic resource selection, and cross-device model splitting are outside this release.

## Package and API

- [x] Public direct-resource API discovers, pairs, watches, prepares, runs, disconnects, forgets,
      and stops without breaking the earlier public surface.
- [x] `.local` executes in process; remote runs use the exact selected `ResourceID` and never fall
      back or forward to another device.
- [x] Client-only apps can link `InferPeer` without MLX, llama.cpp, or model weights.
- [x] Text and still-image requests use one bounded event/result model with cancellation, timeout,
      queueing, terminal-race, replay, and error contracts.
- [x] Audio entries are absent from the signed starter catalog and test apps. Compatibility types
      remain available without a 1.0 support claim.

## Security and transport

- [x] Bonjour advertises only the receiving resource and its bounded v2 metadata.
- [x] Pairing invitations are short-lived, single-use, and bind the exact resource identity,
      numeric LAN endpoint, certificate pin, and scoped credential.
- [x] Durable credentials are stored through the host secret store; wrong pins, revoked access,
      unapproved principals, malformed invitations, and replays fail closed.
- [x] Direct gRPC text/vision wire mapping, bounded streams, reconnect, request deduplication,
      image receipts, owner isolation, and same-process replay have deterministic tests.
- [x] Physical iPad-to-Mac and iPad-to-iPhone direct TLS sessions completed in Release builds.

## Model store and runtimes

- [x] The package owns catalog verification, download, resume, staging, hashes, atomic install,
      registry, import, load/unload, and removal.
- [x] The built-in catalog is Ed25519-signed and every artifact uses an immutable upstream revision,
      exact file sizes, hashes, license metadata, requirements, and validation status.
- [x] Native llama.cpp/libmtmd and MLX adapters are registered independently behind the runtime
      protocol; callers never choose an engine object per request.
- [x] Interrupted/corrupt downloads never appear installed, and a verified installation survives
      an application-container path change without downloading again.
- [x] Stable Qwen3 MLX text and SmolVLM2 native vision artifacts completed on both the iPhone and
      Mac. The unbenchmarked native Qwen3 text artifact remains beta.

## Apps and physical validation

- [x] iPad-only InferPeer Sandbox is a clean text/image chat client with exact named resource/model
      selection and no private download/runtime implementation.
- [x] Separate iPhone and macOS foreground resource-host apps expose only package-managed models.
- [x] Signed Release apps install and launch on iPad14,3, iPhone15,4, and Mac17,2.
- [x] Three-sample text and vision benchmarks pass on the exact iPhone and Mac resources and are
      recorded in `COMPATIBILITY.md`.
- [x] Physical-only automation hooks are compile-time excluded from normal Release builds.

## Quality and publication

- [x] Swift formatting, SwiftLint complexity/length rules, Buf format/lint, and the complete package
      suite pass.
- [x] Container-relocation regressions cover both the model-store registry and verified-manifest
      persistence paths.
- [x] Normal signed archives build for the iPad, iPhone, and macOS apps, include the privacy
      manifest, and pass bundle metadata and release-hook inspection.
- [ ] App Store distribution exports are produced for all three apps. This currently requires an
      App Store distribution identity and profiles for the InferPeer bundle identifiers.
- [ ] App Store Connect records exist for all three bundle identifiers and builds are available to
      the configured TestFlight group.
- [x] The package release commit and `1.0.0` tag are pushed after the package gates above.

## Historical 0.1.0

The coordinator-based `0.1.0` release and its evidence remain available in Git history. The v2
direct-resource implementation supersedes its topology without removing compatibility symbols.
