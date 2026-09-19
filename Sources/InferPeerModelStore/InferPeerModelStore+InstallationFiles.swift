import Foundation
import InferPeerInference
import InferPeerStorage

extension InferPeerModelStore {
    func register(
        _ entry: ModelCatalogEntry,
        staging: URL,
        installRoot: URL
    ) async throws -> InstalledModel {
        let result = try await manifestStore.register(
            entry.manifest,
            stagingDirectory: staging,
            installRoot: installRoot
        )
        let verified: VerifiedModelManifest
        switch result {
        case .registered(let stored):
            verified = stored.verified
        case .duplicate(let stored):
            verified = try await resolveDuplicate(
                stored.verified,
                entry: entry,
                staging: staging,
                installRoot: installRoot
            )
        }
        return InstalledModel(
            key: verified.key,
            manifest: verified.manifest,
            directoryURL: verified.directoryURL,
            installedByteCount: entry.manifest.files.reduce(0) { $0 + $1.byteCount }
        )
    }

    private func resolveDuplicate(
        _ existing: VerifiedModelManifest,
        entry: ModelCatalogEntry,
        staging: URL,
        installRoot: URL
    ) async throws -> VerifiedModelManifest {
        if let verified = try? ModelManifestVerifier().verify(
            existing.manifest,
            in: existing.directoryURL
        ), verified.key == existing.key {
            try? FileManager.default.removeItem(at: staging)
            return existing
        }
        try Self.removeCorruptInstallation(existing.directoryURL, inside: installRoot)
        try await manifestStore.remove(key: existing.key)
        let replacement = try await manifestStore.register(
            entry.manifest,
            stagingDirectory: staging,
            installRoot: installRoot
        )
        guard case .registered(let stored) = replacement else {
            throw ModelManifestRegistrationError.registrationConflict
        }
        return stored.verified
    }

    private static func removeCorruptInstallation(_ url: URL, inside root: URL) throws {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path + "/"
        guard path.hasPrefix(rootPath), path != root.standardizedFileURL.path else {
            throw InferPeerModelStoreError.fileSystemFailure
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw InferPeerModelStoreError.fileSystemFailure
        }
    }

    func prepareVersionRoot(for key: ModelCatalogKey) throws -> URL {
        let root = try layout.versionRoot(for: key)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        } catch {
            throw InferPeerModelStoreError.fileSystemFailure
        }
    }

    func authorize(
        _ entry: ModelCatalogEntry,
        device: ModelStoreDeviceProfile,
        authorization: ModelDownloadAuthorization
    ) throws {
        guard authorization.resourceID == device.resourceID else {
            throw InferPeerModelStoreError.remoteApprovalRequired(device.resourceID)
        }
        if device.resourceID != .local, !authorization.remoteApprovalGranted {
            throw InferPeerModelStoreError.remoteApprovalRequired(device.resourceID)
        }
        if entry.license.acceptanceRequired,
            !authorization.acceptedLicenseIdentifiers.contains(entry.license.identifier)
        {
            throw InferPeerModelStoreError.licenseAcceptanceRequired(entry.license.identifier)
        }
    }

    static func completedInstallation(_ installed: InstalledModel) -> ModelInstallation {
        let pair = AsyncThrowingStream<ModelInstallationEvent, any Error>.makeStream()
        pair.continuation.yield(.installed(installed))
        pair.continuation.finish()
        return ModelInstallation(jobID: UUID(), events: pair.stream)
    }

    func download(
        _ entry: ModelCatalogEntry,
        to staging: URL,
        jobID: UUID,
        continuation: ModelInstallationContinuation
    ) async throws {
        var precedingBytes: UInt64 = 0
        for (index, file) in entry.downloadFiles.enumerated() {
            try Task.checkCancellation()
            let context = DownloadFileContext(
                file: file,
                index: index,
                fileCount: entry.downloadFiles.count,
                precedingBytes: precedingBytes,
                totalBytes: entry.approximateDownloadBytes
            )
            try await download(context, to: staging, continuation: continuation)
            precedingBytes += file.byteCount
            try await transition(
                .downloading,
                jobID: jobID,
                entry: entry,
                completed: precedingBytes
            )
        }
    }

    private func download(
        _ context: DownloadFileContext,
        to staging: URL,
        continuation: ModelInstallationContinuation
    ) async throws {
        let finalURL = staging.appendingPathComponent(context.file.relativePath)
        if try validExistingFile(finalURL, file: context.file) {
            continuation.yield(.progress(Self.progress(context, fileBytes: context.file.byteCount)))
            return
        }
        let partialURL = finalURL.appendingPathExtension("partial")
        _ = try await downloader.download(context.file, to: partialURL) { completed in
            continuation.yield(.progress(Self.progress(context, fileBytes: completed)))
        }
        guard try ModelFileIntegrity.matches(partialURL, file: context.file) else {
            try? FileManager.default.removeItem(at: partialURL)
            throw ModelManifestRegistrationError.fileHashMismatch(context.file.relativePath)
        }
        try Self.finalize(partialURL: partialURL, finalURL: finalURL)
    }

    func prepareDownloadStaging(_ staging: URL) throws {
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw InferPeerModelStoreError.fileSystemFailure
        }
    }

    private func validExistingFile(_ url: URL, file: ModelDownloadFile) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if try ModelFileIntegrity.matches(url, file: file) { return true }
        try FileManager.default.removeItem(at: url)
        return false
    }

    private static func progress(
        _ context: DownloadFileContext,
        fileBytes: UInt64
    ) -> ModelInstallationProgress {
        ModelInstallationProgress(
            file: .init(
                index: context.index + 1,
                count: context.fileCount,
                path: context.file.relativePath,
                completedBytes: fileBytes,
                totalBytes: context.file.byteCount
            ),
            total: .init(
                completedBytes: context.precedingBytes + fileBytes,
                totalBytes: context.totalBytes
            )
        )
    }

    private static func finalize(partialURL: URL, finalURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
        } catch {
            throw InferPeerModelStoreError.fileSystemFailure
        }
    }
}

private struct DownloadFileContext: Sendable {
    let file: ModelDownloadFile
    let index: Int
    let fileCount: Int
    let precedingBytes: UInt64
    let totalBytes: UInt64
}
