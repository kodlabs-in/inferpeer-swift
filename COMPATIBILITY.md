# Compatibility report

This report records the exact 1.0 build and physical-device evidence. InferPeer's API remains
generic: these devices are the available validation hardware, not a hard-coded topology or limit.

## Package baseline

| Item | 1.0 value |
| --- | --- |
| Swift tools version | 6.3 |
| Platforms | macOS 15+, iOS/iPadOS 18+ |
| Validation toolchain | Xcode 27.0 (27A266a), Swift 6.4 |
| Dependency locking | Exact revisions in `Package.resolved` |
| Client-only boundary | Independent `InferPeer` consumer builds without runtime adapters |
| Release modalities | Streaming text and still-image understanding |
| Execution policy | Foreground resource hosts only |

The 1.0 implementation is source compatible with the earlier public API. Legacy cluster and audio
types remain compiled, while the new direct-resource surface and starter catalog define the
shipping behavior.

## Physical hardware

| Device | Role in validation | OS | Models executed |
| --- | --- | --- | --- |
| Mac17,2, Apple M5, 32 GB | Foreground resource host | macOS 27.0 (26A428) | Qwen3 MLX, SmolVLM2 GGUF |
| iPhone15,4 | Foreground resource host | iOS 26.5.2 (23F84) | Qwen3 MLX, SmolVLM2 GGUF |
| iPad14,3 | Sandbox chat client | iPadOS 27.0 (24A437) | Remote text and image requests |

The iPad discovered and paired with independently running iPhone and Mac hosts over Bonjour and
certificate-pinned TLS. It selected an exact resource and exact model for each request. Neither
resource advertised another device or forwarded a run.

## Signed starter artifacts

| Model | Immutable upstream revision | Runtime/format | Declared bytes | 1.0 status |
| --- | --- | --- | ---: | --- |
| Qwen3 0.6B 4-bit | `73e3e38d981303bc594367cd910ea6eb48349da8` | MLX / Safetensors | 351,383,618 | Stable |
| Qwen3 0.6B Q8_0 | `1eaf4d9657fe65ad10a51eab76a8db5b363bddaa` | llama.cpp / GGUF | 639,446,688 | Beta |
| SmolVLM2 500M Q8_0 | `ccd7aae53bcb1997355c2f094959e72b3642ce17` | llama.cpp/libmtmd / GGUF | 545,593,888 | Stable |

Every file is pinned to its byte count and SHA-256 in the Ed25519-signed catalog. Qwen3 MLX and
SmolVLM2 were downloaded into package-managed storage and completed fully offline inference after
installation. The native Qwen3 Q8 artifact remains beta because it was not part of this physical
benchmark pass.

## Release-build measurements

Measurements are three-sample end-to-end direct requests from the iPad Sandbox, including network
transport and streamed completion. Token totals are the aggregate reported output-token count for
the three samples; they are evidence records, not cross-model quality comparisons.

| Executing resource | Task/model | p50 | Aggregate output tokens |
| --- | --- | ---: | ---: |
| Mac17,2 | Qwen3 0.6B MLX text | 2.05 s | 739 |
| iPhone15,4 | Qwen3 0.6B MLX text | 4.11 s | 969 |
| Mac17,2 | SmolVLM2 500M still-image understanding | 1.05 s | 3 |
| iPhone15,4 | SmolVLM2 500M still-image understanding | 1.06 s | 3 |

## Verified boundaries

- Signed Release builds were installed and launched on the iPad, iPhone, and Mac.
- Package-owned downloads, signed-catalog verification, exact hashes, registration, reload, and
  post-container-move recovery were exercised.
- Single-use pairing, certificate pins, durable scoped credentials, exact-resource selection,
  streaming text, still-image upload, and native image inference completed across devices.
- Deterministic tests cover wrong pins, unapproved principals, invitation replay/expiry, malformed
  assets, resumable offsets, corrupt installations, cancellation, timeouts, restart interruption,
  bounded output, and stale resource updates.
- Normal Release configurations exclude the physical-test environment hooks.

This report does not claim background iOS service availability, audio support, video understanding,
cross-device tensor splitting, cloud relays, or automatic resource/model selection.
