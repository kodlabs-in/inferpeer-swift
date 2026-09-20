# ``InferPeer``

Run private local AI on the exact local or approved nearby Apple resource selected by the host app.

## Overview

InferPeer is a dependency-injected direct-resource facade over focused protocol, persistence,
discovery, security, transport, telemetry, and inference modules. A host application owns UI,
operating-system permissions, lifecycle notifications, storage locations, pairing approval, exact
resource selection, and model files.

The package does not start itself, download models, install a daemon, or silently switch to a
cloud transport. `InferPeerMLX` is a separate opt-in product and is not linked by the `InferPeer`
facade. A run targeting `.local` stays in process; a remote run is sent only to its selected
authenticated resource and is never rerouted automatically.

## Configure the local resource

Construct a stopped facade with explicit local identity, runtime, and verified model artifacts:

```swift
import InferPeer
import InferPeerMLX

let inferPeer = try InferPeer(
    configuration: InferPeerConfiguration(
        localResource: LocalResourceConfiguration(
            displayName: "This Mac",
            platform: platform
        ),
        localRuntime: MLXInferenceBackend(),
        localModels: [verifiedArtifact],
        defaultTextModel: verifiedArtifact.descriptor.reference
    )
)
```

Construction does not open sockets or load a model. Hosts that only consume remote resources can
omit the local runtime and avoid linking an engine adapter.

For vision, transcription, or speech, inject a `DirectInferenceRuntime`, declare the exact
`localModelTasks` for every registered artifact, and configure any `defaultModels` explicitly.
InferPeer resolves a task default before admission and reports the exact selected model. A runtime
result for a different model or modality is rejected instead of being silently accepted.

## Run on one exact resource

Create an immutable typed query and select `.local` or one paired resource ID:

```swift
let handle = try await inferPeer.run(
    .text(
        model: .exact(modelKey),
        messages: [.user("Hello")]
    ),
    resourceId: .local
)

for try await event in handle.events {
    // Render ordered, bounded progress and output.
}
let result = try await handle.result()
```

`result()` is independent of event iteration. `cancel()` targets only the selected resource.
`stop()` shuts down discovery, exposure, sessions, queued or running local work, and loaded local
model state owned by this facade.

## Discovery and exposure

`discovery()` returns a reference-counted event subscription for untrusted candidates. Pairing
promotes a candidate into an authenticated `ResourceID`. `expose()` is independent: it binds the
injected authenticated endpoint before its real listening port is advertised. A device does not
become a resource merely because another device is browsing.

The host must withdraw mobile availability before losing its execution grant and request the local
network, media, and background permissions needed by the features it actually enables.

Direct sessions remain pinned to one endpoint identity. Ambiguous acceptance is reconciled with
that same endpoint, and output resumes from an acknowledged sequence within bounded replay and
disconnect-grace budgets. Expired replay is a typed failure; it never causes an automatic run on a
different resource.

## Topics

### Direct-resource facade

- ``InferPeer``
- ``InferPeerConfiguration``
- ``LocalResourceConfiguration``
- ``RunHandle``
