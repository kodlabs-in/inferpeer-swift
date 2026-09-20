# ``InferPeerModelStore``

Acquire, verify, select, and run immutable model packages on an explicitly selected Apple
resource.

## Overview

The model store is the package-owned boundary for signed catalogs, HTTPS downloads, local imports,
file verification, GRDB metadata, and runtime-adapter sessions. A host supplies a signed built-in
``ModelCatalog`` and its pinned Ed25519 public key when it calls
``InferPeerModelStore/open(configuration:)``.

Use ``InferPeerModelStore/catalog(task:resource:chipFeatures:)`` with a local or connected resource
snapshot. The result preserves supported, experimental, and unsupported candidates together with
their reasons. ``InferPeerModelStore/recommendedModel(task:resource:chipFeatures:)`` ranks only
within that resource; it never reroutes work or silently changes the chosen artifact.

Install an exact ``ModelCatalogKey`` with ``InferPeerModelStore/install(_:task:on:authorization:)``
and consume its state and byte progress. Downloads remain in durable partial files until size and
SHA-256 checks pass. Imports through ``InferPeerModelStore/importModel(from:manifest:on:)`` require
a manifest and use the same verified registration path.

Register one or more ``InferPeerRuntimeAdapter`` values when configuring the store. After an
installation is loaded, ``InferPeerModelStore/run(_:using:)`` streams the same direct runtime
events used elsewhere in InferPeer. The adapter owns runtime-specific tokenization and media
preprocessing; the model store owns files and lifecycle.

At startup the store verifies installed files and marks missing or modified packages corrupt.
``InferPeerModelStore/status(of:)`` reports durable state, whether the model is loaded in this
process, and whether default removal is safe.

## Topics

### Configuration and catalogs

- ``InferPeerModelStoreConfiguration``
- ``SignedModelCatalog``
- ``ModelCatalog``
- ``ModelCatalogEntry``
- ``ModelCandidate``
- ``ModelSupport``

### Resources and compatibility

- ``ModelStoreDeviceProfile``
- ``ModelCompatibilityReason``
- ``ModelDeviceTier``

### Installation and lifecycle

- ``ModelInstallation``
- ``ModelInstallationEvent``
- ``ModelInstallationProgress``
- ``InstalledModel``
- ``InstalledModelStatus``
- ``ModelRemovalPolicy``

### Runtime adapters

- ``InferPeerRuntimeAdapter``
- ``InferPeerModelSession``
- ``RuntimeAdapterRegistry``
- ``RuntimeID``
