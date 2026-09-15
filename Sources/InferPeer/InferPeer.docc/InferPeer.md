# ``InferPeer``

Build private, text-only inference flows across explicitly trusted Apple devices on an approved
local Wi-Fi network.

## Overview

InferPeer is a dependency-injected facade over focused protocol, coordinator, persistence,
discovery, security, transport, telemetry, and inference modules. A host application chooses its
roles and owns UI, operating-system permissions, lifecycle notifications, storage locations,
pairing approval, and model files.

The package does not start itself, download models, install a daemon, or silently switch to a
cloud transport. `InferPeerMLX` is a separate opt-in product and is not linked by the `InferPeer`
facade.

## Create a caller configuration

Import the facade product and enable only the roles the host intends to use:

```swift
import InferPeer

let configuration = try InferPeerNodeConfiguration(roles: [.caller])
```

Construct an ``InferPeerNode`` with explicit ``InferPeerDependencies``. A caller dependency graph
must include a durable `InferPeerCallerOutbox`; joining fails before use when it is absent.

## Caller lifecycle

After the host starts the node and obtains an approved invitation, it can join, submit an immutable
context snapshot, and consume durable events:

```swift
try await node.start()
_ = try await node.join(invitation)

let handle = try await node.submit(request)
let events = try await node.events(requestID: handle.requestID)

for try await event in events {
    // Persist or render the event before acknowledging its cursor.
    try await node.acknowledge(requestID: event.requestID, through: event.cursor)
}
```

Call ``InferPeerNode/leaveCoordinator()`` to close joined caller and worker sessions while keeping
the node started for an explicit rejoin. Call ``InferPeerNode/stop()`` when the host no longer wants
the package to own network or execution resources.

## Mobile lifecycle

The host must call `setParticipation(.unavailable)` before an iPhone or iPad enters the background
and refresh status when it returns to the foreground. The worker cancels active inference when it
becomes unavailable; the coordinator also relies on heartbeat expiry because suspension may prevent
the final status message from being delivered.

## Topics

### Node facade

- ``InferPeerNode``
- ``InferPeerNodeConfiguration``
- ``InferPeerDependencies``
- ``InferPeerOptionalServices``
- ``InferPeerRequestHandle``
- ``InferPeerRequestEvent``
- ``InferPeerCommandRejection``
