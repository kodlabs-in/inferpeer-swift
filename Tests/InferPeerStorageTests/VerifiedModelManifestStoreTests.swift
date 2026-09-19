import CryptoKit
import Foundation
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import Testing

@Suite("Verified model manifest store")
struct VerifiedModelManifestStoreTests {
    @Test("Complete multimodal manifests verify every declared asset")
    func verifiesCompleteManifest() throws {
        let fixture = try ModelManifestFixture()
        defer { fixture.remove() }

        let verified = try ModelManifestVerifier().verify(
            fixture.manifest,
            in: fixture.stagingDirectory
        )

        #expect(verified.key.modelID == fixture.manifest.modelID)
        #expect(verified.key.revision.hasPrefix("manifest-v1-"))
        #expect(verified.manifest.files.count == 7)
        #expect(verified.manifest.capabilities.count == 4)
    }

    @Test("Canonical manifest identity is order independent and content sensitive")
    func stableContentIdentity() throws {
        let first = try ModelManifestFixture()
        let reordered = try ModelManifestFixture(reversingDeclarations: true)
        let changed = try ModelManifestFixture(processorData: Data("changed!!".utf8))
        defer {
            first.remove()
            reordered.remove()
            changed.remove()
        }

        let verifier = ModelManifestVerifier()
        let firstKey = try verifier.verify(first.manifest, in: first.stagingDirectory).key
        let reorderedKey = try verifier.verify(
            reordered.manifest,
            in: reordered.stagingDirectory
        ).key
        let changedKey = try verifier.verify(changed.manifest, in: changed.stagingDirectory).key

        #expect(firstKey == reorderedKey)
        #expect(firstKey != changedKey)
    }

    @Test("Manifest paths cannot be absolute or escape the artifact root")
    func rejectsUnsafeManifestPaths() throws {
        let digest = try modelDigest(Data("weights".utf8))

        #expect(throws: ModelManifestValidationError.self) {
            _ = try ModelManifestFile(
                relativePath: "../weights.bin",
                role: .weights,
                byteCount: 7,
                sha256: digest
            )
        }
        #expect(throws: ModelManifestValidationError.self) {
            _ = try ModelManifestFile(
                relativePath: "/tmp/weights.bin",
                role: .weights,
                byteCount: 7,
                sha256: digest
            )
        }
    }

    @Test("Vision manifests require matching projector and processor declarations")
    func enforcesTaskFilesAndLimits() throws {
        let fixture = try ModelManifestFixture()
        defer { fixture.remove() }
        let withoutProjector = fixture.manifest.files.filter { $0.role != .projector }

        #expect(throws: ModelManifestValidationError.missingFileRole(.projector)) {
            _ = try fixture.rebuildManifest(files: withoutProjector)
        }
        #expect(throws: ModelManifestValidationError.self) {
            _ = try ModelTaskCapability(
                task: .imageUnderstanding,
                contextTokenLimit: 4_096,
                maximumOutputTokens: 512,
                maximumInputAssets: 0,
                inputFormats: ["image/jpeg"]
            )
        }
    }

    @Test("Verification rejects missing, corrupt, and undeclared files")
    func rejectsInvalidFileTrees() throws {
        try expectVerificationFailure(
            mutation: { fixture in
                try FileManager.default.removeItem(
                    at: fixture.stagingDirectory.appendingPathComponent("model.gguf")
                )
            },
            error: .declaredFileMissing("model.gguf")
        )
        try expectVerificationFailure(
            mutation: { fixture in
                try Data("bad-data!".utf8).write(
                    to: fixture.stagingDirectory.appendingPathComponent("processor.json")
                )
            },
            error: .fileHashMismatch("processor.json")
        )
        try expectVerificationFailure(
            mutation: { fixture in
                try Data("extra".utf8).write(
                    to: fixture.stagingDirectory.appendingPathComponent("undeclared.bin")
                )
            },
            error: .undeclaredFile("undeclared.bin")
        )
    }

    @Test("Verification rejects symbolic links even when their target bytes match")
    func rejectsSymbolicLinks() throws {
        let fixture = try ModelManifestFixture()
        defer { fixture.remove() }
        let declared = fixture.stagingDirectory.appendingPathComponent("model.gguf")
        let outside = fixture.installRoot.appendingPathComponent("outside.bin")
        try Data("weights".utf8).write(to: outside)
        try FileManager.default.removeItem(at: declared)
        try FileManager.default.createSymbolicLink(at: declared, withDestinationURL: outside)

        #expect(throws: ModelManifestRegistrationError.symbolicLinkForbidden("model.gguf")) {
            _ = try ModelManifestVerifier().verify(
                fixture.manifest,
                in: fixture.stagingDirectory
            )
        }
    }

    @Test("Successful registration atomically moves staging and persists idempotently")
    func registersAtomicallyAndPersists() async throws {
        let fixture = try ModelManifestFixture()
        defer { fixture.remove() }
        let databaseURL = fixture.installRoot.appendingPathComponent("registry.sqlite")
        let store = try SQLiteVerifiedModelManifestStore(databaseURL: databaseURL)
        let first = try await store.register(
            fixture.manifest,
            stagingDirectory: fixture.stagingDirectory,
            installRoot: fixture.installRoot
        )
        let registered = try registeredValue(first)

        #expect(!FileManager.default.fileExists(atPath: fixture.stagingDirectory.path))
        #expect(FileManager.default.fileExists(atPath: registered.verified.directoryURL.path))
        #expect(try await store.model(key: registered.verified.key) == registered)
        try await store.close()

        let reopened = try SQLiteVerifiedModelManifestStore(databaseURL: databaseURL)
        #expect(try await reopened.models() == [registered])

        let duplicateStaging = fixture.installRoot.appendingPathComponent("duplicate.stage")
        try fixture.writeFiles(to: duplicateStaging)
        let duplicate = try await reopened.register(
            fixture.manifest,
            stagingDirectory: duplicateStaging,
            installRoot: fixture.installRoot
        )
        guard case .duplicate(let repeated) = duplicate else {
            Issue.record("Expected duplicate manifest registration")
            return
        }
        #expect(repeated == registered)
        #expect(FileManager.default.fileExists(atPath: duplicateStaging.path))
        try await reopened.close()
    }

    @Test("Failed verification leaves staging in place and commits no registration")
    func verificationFailureIsAtomic() async throws {
        let fixture = try ModelManifestFixture()
        defer { fixture.remove() }
        let databaseURL = fixture.installRoot.appendingPathComponent("registry.sqlite")
        let store = try SQLiteVerifiedModelManifestStore(databaseURL: databaseURL)
        try Data("corrupt".utf8).write(
            to: fixture.stagingDirectory.appendingPathComponent("model.gguf")
        )

        await #expect(throws: ModelManifestRegistrationError.self) {
            _ = try await store.register(
                fixture.manifest,
                stagingDirectory: fixture.stagingDirectory,
                installRoot: fixture.installRoot
            )
        }

        #expect(FileManager.default.fileExists(atPath: fixture.stagingDirectory.path))
        #expect(try await store.models().isEmpty)
        try await store.close()
    }

    @Test("Registration accepts only host-provisioned local staging directories")
    func rejectsRemoteAndExternalStaging() async throws {
        let fixture = try ModelManifestFixture()
        defer { fixture.remove() }
        let store = try SQLiteVerifiedModelManifestStore(
            databaseURL: fixture.installRoot.appendingPathComponent("registry.sqlite")
        )
        let remoteURL = try #require(URL(string: "https://example.invalid/model"))

        await #expect(throws: ModelManifestRegistrationError.localFileURLRequired) {
            _ = try await store.register(
                fixture.manifest,
                stagingDirectory: remoteURL,
                installRoot: fixture.installRoot
            )
        }

        let external = fixture.installRoot.deletingLastPathComponent()
            .appendingPathComponent("external.stage")
        await #expect(
            throws: ModelManifestRegistrationError.stagingMustBeInsideInstallRoot
        ) {
            _ = try await store.register(
                fixture.manifest,
                stagingDirectory: external,
                installRoot: fixture.installRoot
            )
        }
        try await store.close()
    }

    private func expectVerificationFailure(
        mutation: (ModelManifestFixture) throws -> Void,
        error: ModelManifestRegistrationError
    ) throws {
        let fixture = try ModelManifestFixture()
        defer { fixture.remove() }
        try mutation(fixture)

        #expect(throws: error) {
            _ = try ModelManifestVerifier().verify(
                fixture.manifest,
                in: fixture.stagingDirectory
            )
        }
    }

    private func registeredValue(
        _ result: VerifiedModelRegistrationResult
    ) throws -> StoredVerifiedModelManifest {
        guard case .registered(let registration) = result else {
            Issue.record("Expected a new manifest registration")
            throw ManifestTestError.unexpectedResult
        }
        return registration
    }
}

private struct ModelManifestFixture {
    let installRoot: URL
    let stagingDirectory: URL
    let manifest: ModelManifest
    private let files: [(String, ModelManifestFileRole, Data)]

    init(
        reversingDeclarations: Bool = false,
        processorData: Data = Data("processor".utf8)
    ) throws {
        installRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        stagingDirectory = installRoot.appendingPathComponent("incoming.stage", isDirectory: true)
        files = [
            ("model.gguf", .weights, Data("weights".utf8)),
            ("tokenizer.json", .tokenizer, Data("tokenizer".utf8)),
            ("template.txt", .chatTemplate, Data("template".utf8)),
            ("projector.gguf", .projector, Data("projector".utf8)),
            ("processor.json", .processorConfiguration, processorData),
            ("audio.bin", .audioModel, Data("audio-model".utf8)),
            ("voice.bin", .voiceAsset, Data("voice".utf8)),
        ]
        try Self.write(files: files, to: stagingDirectory)
        let declarations = try files.map { path, role, data in
            try ModelManifestFile(
                relativePath: path,
                role: role,
                byteCount: UInt64(data.count),
                sha256: modelDigest(data)
            )
        }
        manifest = try Self.makeManifest(
            files: reversingDeclarations ? declarations.reversed() : declarations
        )
    }

    func rebuildManifest(files: [ModelManifestFile]) throws -> ModelManifest {
        try Self.makeManifest(files: files)
    }

    func writeFiles(to directory: URL) throws {
        try Self.write(files: files, to: directory)
    }

    private static func write(
        files: [(String, ModelManifestFileRole, Data)],
        to directory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for (path, _, data) in files {
            try data.write(to: directory.appendingPathComponent(path))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: installRoot)
    }

    private static func makeManifest(files: some Sequence<ModelManifestFile>) throws
        -> ModelManifest
    {
        let modelID = try #require(ModelID(rawValue: "vision-speech-model"))
        return try ModelManifest(
            modelID: modelID,
            family: "Fixture Family",
            name: "Fixture Model",
            upstreamRevision: "upstream-1",
            source: "host-provisioned fixture",
            license: "Apache-2.0",
            runtime: ModelManifestRuntime(
                runtimeIdentifier: "fixture-runtime",
                format: "fixture-format",
                quantization: "q4",
                tensorLayout: "layout-1",
                minimumBackendVersion: "1.0.0"
            ),
            files: Array(files),
            capabilities: try capabilities(),
            deviceProfiles: [
                ModelDeviceProfile(
                    deviceClass: "test-device",
                    loadMilliseconds: 10,
                    steadyMemoryBytes: 100,
                    peakMemoryBytes: 200,
                    workingMemoryBytes: 50
                )
            ]
        )
    }

    private static func capabilities() throws -> [ModelTaskCapability] {
        [
            try ModelTaskCapability(
                task: .textGeneration,
                contextTokenLimit: 4_096,
                maximumOutputTokens: 512,
                outputFormats: ["text/plain"]
            ),
            try ModelTaskCapability(
                task: .imageUnderstanding,
                contextTokenLimit: 4_096,
                maximumOutputTokens: 512,
                maximumInputAssets: 8,
                inputFormats: ["image/jpeg"],
                outputFormats: ["text/plain"]
            ),
            try ModelTaskCapability(
                task: .transcribe,
                inputFormats: ["audio/wav"],
                outputFormats: ["text/plain"],
                languageCodes: ["en"]
            ),
            try ModelTaskCapability(
                task: .synthesizeSpeech,
                outputFormats: ["audio/pcm"],
                languageCodes: ["en"],
                voiceIDs: ["voice-1"]
            ),
        ]
    }
}

private func modelDigest(_ data: Data) throws -> ModelContentDigest {
    try ModelContentDigest(bytes: Data(SHA256.hash(data: data)))
}

private enum ManifestTestError: Error {
    case unexpectedResult
}
