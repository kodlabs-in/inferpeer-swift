import Crypto
import Foundation
import InferPeerInference

/// Signed exact catalog payload. Signatures never depend on re-encoding JSON.
public struct SignedModelCatalog: Codable, Hashable, Sendable {
    /// Identifier of the pinned signing key.
    public let keyID: String
    /// Exact signed catalog bytes.
    public let payload: Data
    /// Ed25519 signature over `payload`.
    public let signature: Data

    /// Creates a signed envelope without re-encoding its payload.
    public init(keyID: String, payload: Data, signature: Data) {
        self.keyID = keyID
        self.payload = payload
        self.signature = signature
    }
}

/// Verifies built-in and refreshed catalogs against pinned Ed25519 public keys.
public struct ModelCatalogVerifier: Sendable {
    private let trustedKeys: [String: Data]

    /// Creates a verifier with pinned Ed25519 public-key representations.
    public init(trustedKeys: [String: Data]) {
        self.trustedKeys = trustedKeys
    }

    /// Verifies the signature and reconstructs validated catalog values.
    public func verify(_ signedCatalog: SignedModelCatalog) throws -> ModelCatalog {
        guard let keyData = trustedKeys[signedCatalog.keyID] else {
            throw ModelCatalogError.untrustedSigningKey
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        } catch {
            throw ModelCatalogError.untrustedSigningKey
        }
        guard publicKey.isValidSignature(signedCatalog.signature, for: signedCatalog.payload) else {
            throw ModelCatalogError.invalidSignature
        }
        return try Self.decodeAndValidate(signedCatalog.payload)
    }

    /// Rejects catalog rollback and mutation of an existing model version.
    public func validateUpdate(current: ModelCatalog, replacement: ModelCatalog) throws {
        guard replacement.generatedAt >= current.generatedAt else {
            throw ModelCatalogError.catalogRollback
        }
        let currentEntries = Dictionary(
            uniqueKeysWithValues: current.entries.map {
                ($0.metadata.key, $0)
            })
        for entry in replacement.entries {
            if let existing = currentEntries[entry.metadata.key], existing != entry {
                throw ModelCatalogError.immutableVersionChanged(entry.metadata.key)
            }
        }
    }

    /// Produces deterministic bytes suitable for signing.
    public static func encode(_ catalog: ModelCatalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(catalog)
    }

    /// Decodes and structurally revalidates an unsigned local import manifest.
    public static func decodeEntry(_ data: Data) throws -> ModelCatalogEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try revalidate(decoder.decode(ModelCatalogEntry.self, from: data))
        } catch let error as ModelCatalogError {
            throw error
        } catch {
            throw ModelCatalogError.invalidPayload
        }
    }

    private static func decodeAndValidate(_ data: Data) throws -> ModelCatalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded: ModelCatalog
        do {
            decoded = try decoder.decode(ModelCatalog.self, from: data)
        } catch {
            throw ModelCatalogError.invalidPayload
        }
        do {
            let entries = try decoded.entries.map(Self.revalidate)
            return try ModelCatalog(
                formatVersion: decoded.formatVersion,
                revision: decoded.revision,
                generatedAt: decoded.generatedAt,
                entries: entries
            )
        } catch let error as ModelCatalogError {
            throw error
        } catch {
            throw ModelCatalogError.invalidPayload
        }
    }

    private static func revalidate(_ entry: ModelCatalogEntry) throws -> ModelCatalogEntry {
        let manifest = try revalidate(entry.manifest)
        let downloads = try entry.downloadFiles.map { file in
            try ModelDownloadFile(
                relativePath: file.relativePath,
                url: file.url,
                byteCount: file.byteCount,
                sha256: file.sha256
            )
        }
        return try ModelCatalogEntry(
            metadata: entry.metadata,
            manifest: manifest,
            downloadFiles: downloads,
            license: entry.license,
            requirements: entry.requirements,
            validation: entry.validation
        )
    }

    private static func revalidate(_ manifest: ModelManifest) throws -> ModelManifest {
        try ModelManifest(
            formatVersion: manifest.formatVersion,
            modelID: manifest.modelID,
            family: manifest.family,
            name: manifest.name,
            upstreamRevision: manifest.upstreamRevision,
            source: manifest.source,
            license: manifest.license,
            runtime: try revalidate(manifest.runtime),
            files: try manifest.files.map(revalidate),
            capabilities: try manifest.capabilities.map(revalidate),
            deviceProfiles: try manifest.deviceProfiles.map(revalidate)
        )
    }

    private static func revalidate(_ runtime: ModelManifestRuntime) throws
        -> ModelManifestRuntime
    {
        try ModelManifestRuntime(
            runtimeIdentifier: runtime.runtimeIdentifier,
            format: runtime.format,
            quantization: runtime.quantization,
            tensorLayout: runtime.tensorLayout,
            minimumBackendVersion: runtime.minimumBackendVersion
        )
    }

    private static func revalidate(_ file: ModelManifestFile) throws -> ModelManifestFile {
        try ModelManifestFile(
            relativePath: file.relativePath,
            role: file.role,
            byteCount: file.byteCount,
            sha256: file.sha256
        )
    }

    private static func revalidate(_ capability: ModelTaskCapability) throws
        -> ModelTaskCapability
    {
        try ModelTaskCapability(
            task: capability.task,
            contextTokenLimit: capability.contextTokenLimit,
            maximumOutputTokens: capability.maximumOutputTokens,
            maximumInputAssets: capability.maximumInputAssets,
            inputFormats: capability.inputFormats,
            outputFormats: capability.outputFormats,
            languageCodes: capability.languageCodes,
            voiceIDs: capability.voiceIDs
        )
    }

    private static func revalidate(_ profile: ModelDeviceProfile) throws -> ModelDeviceProfile {
        try ModelDeviceProfile(
            deviceClass: profile.deviceClass,
            loadMilliseconds: profile.loadMilliseconds,
            steadyMemoryBytes: profile.steadyMemoryBytes,
            peakMemoryBytes: profile.peakMemoryBytes,
            workingMemoryBytes: profile.workingMemoryBytes
        )
    }
}
