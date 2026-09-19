import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import Testing

@Suite("Signed model catalog and compatibility")
struct ModelCatalogTests {
    @Test("Catalog signatures reject changed payload bytes")
    func rejectsTamperedCatalog() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let signed = try fixture.signedCatalog()
        let verifier = ModelCatalogVerifier(
            trustedKeys: [fixture.keyID: fixture.privateKey.publicKey.rawRepresentation]
        )

        #expect(try verifier.verify(signed).entries == [fixture.entry])
        var tampered = signed.payload
        tampered[tampered.startIndex] ^= 1
        let invalid = SignedModelCatalog(
            keyID: signed.keyID,
            payload: tampered,
            signature: signed.signature
        )
        #expect(throws: ModelCatalogError.invalidSignature) {
            _ = try verifier.verify(invalid)
        }
    }

    @Test("Catalog updates cannot mutate an existing model version")
    func preservesImmutableVersions() throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.remove() }
        let verifier = ModelCatalogVerifier(
            trustedKeys: [fixture.keyID: fixture.privateKey.publicKey.rawRepresentation]
        )
        let original = try verifier.verify(fixture.signedCatalog())
        let changedMetadata = ModelCatalogMetadata(
            key: fixture.entry.metadata.key,
            displayName: "Changed after publication",
            publisher: fixture.entry.metadata.publisher,
            status: fixture.entry.metadata.status,
            recommendedTier: fixture.entry.metadata.recommendedTier
        )
        let changedEntry = try ModelCatalogEntry(
            metadata: changedMetadata,
            manifest: fixture.entry.manifest,
            downloadFiles: fixture.entry.downloadFiles,
            license: fixture.entry.license,
            requirements: fixture.entry.requirements,
            validation: fixture.entry.validation
        )
        let replacement = try verifier.verify(
            fixture.signedCatalog(
                entries: [changedEntry],
                revision: "catalog-2",
                generatedAt: Date(timeIntervalSince1970: 3_000)
            )
        )

        #expect(
            throws: ModelCatalogError.immutableVersionChanged(fixture.entry.metadata.key)
        ) {
            try verifier.validateUpdate(current: original, replacement: replacement)
        }
    }

    @Test("Recommendation uses actual memory and explains rejected candidates")
    func recommendsForActualResources() async throws {
        let small = try ModelStoreFixture(modelID: "small", minimumPhysicalMemoryBytes: 2_000)
        let large = try ModelStoreFixture(
            modelID: "large",
            version: "2.0.0",
            tier: .mac,
            minimumPhysicalMemoryBytes: 16_000
        )
        defer {
            small.remove()
            large.remove()
        }
        let store = try await selectionStore(primary: small, entries: [large.entry, small.entry])
        let resource = try connectedResource(physicalMemoryBytes: 8_000)

        let candidates = await store.catalog(
            task: .textGeneration,
            resource: resource
        )

        #expect(candidates.count == 2)
        #expect(candidates[0].entry.metadata.key == small.entry.metadata.key)
        #expect(candidates[0].support == .supported)
        guard case .unsupported(let reasons) = candidates[1].support else {
            Issue.record("Expected the memory-heavy candidate to be unsupported")
            return
        }
        #expect(
            reasons.contains(
                .physicalMemoryInsufficient(required: 16_000, available: 8_000)
            )
        )
        #expect(
            await store.recommendedModel(
                task: .textGeneration,
                resource: resource
            )?.entry.metadata.key == small.entry.metadata.key
        )
    }

    @Test("Missing resource telemetry remains unknown instead of becoming zero")
    func preservesUnknownTelemetry() throws {
        let available = try TelemetryMeasurement(
            value: 4_096,
            unit: "bytes",
            scope: .resource,
            quality: .measured
        )
        let snapshot = ResourceSnapshot(
            id: ResourceID(rawValue: "remote-phone"),
            displayName: "Phone",
            platform: PlatformDescriptor(
                operatingSystem: .iOS,
                operatingSystemVersion: "18.2",
                hardwareIdentifier: "iPhone15,4"
            ),
            connection: .connected,
            execution: .available,
            capabilities: CapabilitySnapshot(supportedTasks: [.textGeneration]),
            models: [],
            telemetry: TelemetrySnapshot(
                measurements: [ModelStoreDeviceProfile.availableMemoryMeasurement: available]
            ),
            revision: 1
        )

        let profile = ModelStoreDeviceProfile(snapshot: snapshot)

        #expect(profile.availableMemoryBytes == 4_096)
        #expect(profile.physicalMemoryBytes == nil)
        #expect(profile.freeStorageBytes == nil)
    }
}

private func connectedResource(physicalMemoryBytes: UInt64) throws -> ResourceSnapshot {
    func measurement(_ value: UInt64) throws -> TelemetryMeasurement {
        try TelemetryMeasurement(
            value: Double(value),
            unit: "bytes",
            scope: .resource,
            quality: .measured
        )
    }
    return ResourceSnapshot(
        id: ResourceID(rawValue: "connected-phone"),
        displayName: "Connected phone",
        platform: PlatformDescriptor(
            operatingSystem: .iOS,
            operatingSystemVersion: "18.2",
            hardwareIdentifier: "iPhone15,4"
        ),
        connection: .connected,
        execution: .available,
        capabilities: CapabilitySnapshot(supportedTasks: [.textGeneration]),
        models: [],
        telemetry: TelemetrySnapshot(
            measurements: [
                ModelStoreDeviceProfile.physicalMemoryMeasurement: try measurement(
                    physicalMemoryBytes
                ),
                ModelStoreDeviceProfile.availableMemoryMeasurement: try measurement(
                    physicalMemoryBytes
                ),
                ModelStoreDeviceProfile.freeStorageMeasurement: try measurement(1_000_000),
            ]
        ),
        revision: 1
    )
}

private func selectionStore(
    primary: ModelStoreFixture,
    entries: [ModelCatalogEntry]
) async throws -> InferPeerModelStore {
    let signed = try primary.signedCatalog(entries: entries)
    let configuration = InferPeerModelStoreConfiguration(
        rootDirectory: primary.root,
        builtInCatalog: signed,
        trustedCatalogKeys: [
            primary.keyID: primary.privateKey.publicKey.rawRepresentation
        ],
        runtimeAdapters: [TestRuntimeAdapter()],
        services: .init(downloader: MemoryModelDownloader(data: primary.data))
    )
    return try await InferPeerModelStore.open(configuration: configuration)
}
