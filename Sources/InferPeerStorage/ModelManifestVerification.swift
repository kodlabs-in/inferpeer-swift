import Crypto
import Darwin
import Foundation
import InferPeerInference

/// A manifest whose complete local file tree passed size and SHA-256 verification.
public struct VerifiedModelManifest: Hashable, Sendable {
    /// Exact artifact key derived from the versioned canonical manifest.
    public let key: ModelKey

    /// SHA-256 of the canonical manifest, including every declared content hash.
    public let manifestDigest: ModelContentDigest

    /// Validated manifest in canonical array order.
    public let manifest: ModelManifest

    /// Verified local artifact directory.
    public let directoryURL: URL

}

/// Local-only verifier for a complete staged model artifact.
public struct ModelManifestVerifier: Sendable {
    /// Creates an engine-neutral verifier. It performs no network access.
    public init() {}

    /// Verifies the directory shape, every declared file, and the canonical manifest identity.
    public func verify(
        _ manifest: ModelManifest,
        in directoryURL: URL
    ) throws -> VerifiedModelManifest {
        let root = try Self.validatedRoot(directoryURL)
        let declaredPaths = Set(manifest.files.map(\.relativePath))
        try Self.validateCompleteTree(root: root, declaredPaths: declaredPaths)
        for file in manifest.files {
            try Self.verify(file, root: root)
        }
        let manifestData = try ModelManifestCodec.encode(manifest)
        let digest = try ModelContentDigest(bytes: Data(SHA256.hash(data: manifestData)))
        let revision = "manifest-v\(manifest.formatVersion)-\(Self.hex(digest.bytes))"
        let key = try ModelReference(modelID: manifest.modelID, revision: revision)
        return VerifiedModelManifest(
            key: key,
            manifestDigest: digest,
            manifest: manifest,
            directoryURL: root
        )
    }

    private static func validatedRoot(_ directoryURL: URL) throws -> URL {
        guard directoryURL.isFileURL else {
            throw ModelManifestRegistrationError.localFileURLRequired
        }
        let standardizedRoot = directoryURL.standardizedFileURL
        let values: URLResourceValues
        do {
            values = try standardizedRoot.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
        } catch CocoaError.fileReadNoSuchFile {
            throw ModelManifestRegistrationError.stagingDirectoryMissing
        } catch {
            throw ModelManifestRegistrationError.fileSystemFailure
        }
        guard values.isSymbolicLink != true else {
            throw ModelManifestRegistrationError.symbolicLinkForbidden("")
        }
        guard values.isDirectory == true else {
            throw ModelManifestRegistrationError.stagingDirectoryMissing
        }
        return try canonicalURL(standardizedRoot)
    }

    private static func validateCompleteTree(
        root: URL,
        declaredPaths: Set<String>
    ) throws {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: []
            )
        else {
            throw ModelManifestRegistrationError.fileSystemFailure
        }
        while let entry = enumerator.nextObject() as? URL {
            let relativePath = try relativePath(of: entry, under: root)
            let values = try resourceValues(for: entry, keys: Set(keys))
            if values.isSymbolicLink == true {
                throw ModelManifestRegistrationError.symbolicLinkForbidden(relativePath)
            }
            if values.isRegularFile == true, !declaredPaths.contains(relativePath) {
                throw ModelManifestRegistrationError.undeclaredFile(relativePath)
            }
            if values.isDirectory != true, values.isRegularFile != true {
                throw ModelManifestRegistrationError.unsupportedFile(relativePath)
            }
        }
    }

    private static func verify(_ file: ModelManifestFile, root: URL) throws {
        let fileURL = root.appendingPathComponent(file.relativePath, isDirectory: false)
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
        } catch CocoaError.fileReadNoSuchFile {
            throw ModelManifestRegistrationError.declaredFileMissing(file.relativePath)
        } catch {
            throw ModelManifestRegistrationError.fileSystemFailure
        }
        guard values.isSymbolicLink != true else {
            throw ModelManifestRegistrationError.symbolicLinkForbidden(file.relativePath)
        }
        guard values.isRegularFile == true, let size = values.fileSize,
            let actualByteCount = UInt64(exactly: size)
        else {
            throw ModelManifestRegistrationError.declaredFileMissing(file.relativePath)
        }
        guard actualByteCount == file.byteCount else {
            throw ModelManifestRegistrationError.fileSizeMismatch(file.relativePath)
        }
        let digest = try hash(fileURL)
        guard digest == file.sha256.bytes else {
            throw ModelManifestRegistrationError.fileHashMismatch(file.relativePath)
        }
    }

    private static func hash(_ fileURL: URL) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw ModelManifestRegistrationError.fileSystemFailure
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw ModelManifestRegistrationError.fileSystemFailure
        }
        return Data(hasher.finalize())
    }

    private static func relativePath(of entry: URL, under root: URL) throws -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard entry.path.hasPrefix(rootPath) else {
            throw ModelManifestRegistrationError.pathEscapedRoot
        }
        return String(entry.path.dropFirst(rootPath.count))
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw ModelManifestRegistrationError.fileSystemFailure
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func resourceValues(
        for url: URL,
        keys: Set<URLResourceKey>
    ) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: keys)
        } catch {
            throw ModelManifestRegistrationError.fileSystemFailure
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

enum ModelManifestCodec {
    static func encode(_ manifest: ModelManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(manifest)
        } catch {
            throw ModelManifestRegistrationError.corruptManifest
        }
    }

    static func decode(_ data: Data) throws -> ModelManifest {
        do {
            let decoded = try JSONDecoder().decode(ModelManifest.self, from: data)
            return try revalidated(decoded)
        } catch {
            throw ModelManifestRegistrationError.corruptManifest
        }
    }

    private static func revalidated(_ decoded: ModelManifest) throws -> ModelManifest {
        try ModelManifest(
            formatVersion: decoded.formatVersion,
            modelID: decoded.modelID,
            family: decoded.family,
            name: decoded.name,
            upstreamRevision: decoded.upstreamRevision,
            source: decoded.source,
            license: decoded.license,
            runtime: validatedRuntime(decoded.runtime),
            files: decoded.files.map(validatedFile),
            capabilities: decoded.capabilities.map(validatedCapability),
            deviceProfiles: decoded.deviceProfiles.map(validatedProfile)
        )
    }

    private static func validatedRuntime(
        _ runtime: ModelManifestRuntime
    ) throws -> ModelManifestRuntime {
        try ModelManifestRuntime(
            runtimeIdentifier: runtime.runtimeIdentifier,
            format: runtime.format,
            quantization: runtime.quantization,
            tensorLayout: runtime.tensorLayout,
            minimumBackendVersion: runtime.minimumBackendVersion
        )
    }

    private static func validatedFile(_ file: ModelManifestFile) throws -> ModelManifestFile {
        try ModelManifestFile(
            relativePath: file.relativePath,
            role: file.role,
            byteCount: file.byteCount,
            sha256: file.sha256
        )
    }

    private static func validatedCapability(
        _ capability: ModelTaskCapability
    ) throws -> ModelTaskCapability {
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

    private static func validatedProfile(
        _ profile: ModelDeviceProfile
    ) throws -> ModelDeviceProfile {
        try ModelDeviceProfile(
            deviceClass: profile.deviceClass,
            loadMilliseconds: profile.loadMilliseconds,
            steadyMemoryBytes: profile.steadyMemoryBytes,
            peakMemoryBytes: profile.peakMemoryBytes,
            workingMemoryBytes: profile.workingMemoryBytes
        )
    }
}

/// Safe failures from local manifest verification and atomic registration.
public enum ModelManifestRegistrationError: Error, Equatable, Sendable {
    case localFileURLRequired
    case stagingDirectoryMissing
    case stagingMustBeInsideInstallRoot
    case pathEscapedRoot
    case symbolicLinkForbidden(String)
    case declaredFileMissing(String)
    case undeclaredFile(String)
    case unsupportedFile(String)
    case fileSizeMismatch(String)
    case fileHashMismatch(String)
    case destinationAlreadyExists
    case registrationConflict
    case corruptManifest
    case fileSystemFailure
    case databaseFailure
}
