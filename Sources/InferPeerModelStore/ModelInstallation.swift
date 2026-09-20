import Foundation
import InferPeerCore
import InferPeerInference

/// Explicit resource and license authorization for one download.
public struct ModelDownloadAuthorization: Sendable {
    /// Resource on which the model will be installed.
    public let resourceID: ResourceID
    /// Host-recorded user approval for a remote resource.
    public let remoteApprovalGranted: Bool
    /// License identifiers explicitly accepted by the user.
    public let acceptedLicenseIdentifiers: Set<String>

    /// Creates authorization evidence for one install request.
    public init(
        resourceID: ResourceID,
        remoteApprovalGranted: Bool = false,
        acceptedLicenseIdentifiers: Set<String> = []
    ) {
        self.resourceID = resourceID
        self.remoteApprovalGranted = remoteApprovalGranted
        self.acceptedLicenseIdentifiers = acceptedLicenseIdentifiers
    }
}

/// Byte and file progress for one installation.
public struct ModelInstallationProgress: Hashable, Sendable {
    /// One-based current file index.
    public let fileIndex: Int
    /// Total number of files.
    public let fileCount: Int
    /// Current manifest-relative file path.
    public let filePath: String
    /// Bytes completed for the current file.
    public let fileCompletedBytes: UInt64
    /// Expected bytes for the current file.
    public let fileTotalBytes: UInt64
    /// Bytes completed across the model package.
    public let totalCompletedBytes: UInt64
    /// Expected bytes across the model package.
    public let totalBytes: UInt64

    /// Creates public progress from file and package counters.
    public init(file: FileProgress, total: TotalProgress) {
        fileIndex = file.index
        fileCount = file.count
        filePath = file.path
        fileCompletedBytes = file.completedBytes
        fileTotalBytes = file.totalBytes
        totalCompletedBytes = total.completedBytes
        totalBytes = total.totalBytes
    }

    /// Current-file counters grouped to keep APIs bounded.
    public struct FileProgress: Hashable, Sendable {
        /// One-based current file index.
        public let index: Int
        /// Total package file count.
        public let count: Int
        /// Manifest-relative file path.
        public let path: String
        /// Current file bytes downloaded.
        public let completedBytes: UInt64
        /// Expected current file bytes.
        public let totalBytes: UInt64

        /// Creates current-file progress.
        public init(
            index: Int,
            count: Int,
            path: String,
            completedBytes: UInt64,
            totalBytes: UInt64
        ) {
            self.index = index
            self.count = count
            self.path = path
            self.completedBytes = completedBytes
            self.totalBytes = totalBytes
        }
    }

    /// Package-wide byte counters.
    public struct TotalProgress: Hashable, Sendable {
        /// Bytes completed across files.
        public let completedBytes: UInt64
        /// Expected bytes across files.
        public let totalBytes: UInt64

        /// Creates package-wide progress.
        public init(completedBytes: UInt64, totalBytes: UInt64) {
            self.completedBytes = completedBytes
            self.totalBytes = totalBytes
        }
    }
}

/// State, progress, and terminal installation output.
public enum ModelInstallationEvent: Sendable {
    case state(ModelInstallationState)
    case progress(ModelInstallationProgress)
    case installed(InstalledModel)
}

/// Handle for observing and pausing one package-owned installation.
public struct ModelInstallation: Sendable {
    /// Durable job identity.
    public let jobID: UUID
    /// Bounded stream ending in one installed model or an error.
    public let events: AsyncThrowingStream<ModelInstallationEvent, any Error>

    /// Creates an installation handle.
    public init(
        jobID: UUID,
        events: AsyncThrowingStream<ModelInstallationEvent, any Error>
    ) {
        self.jobID = jobID
        self.events = events
    }
}

/// Caller-selected behavior when a model is loaded.
public enum ModelRemovalPolicy: Hashable, Sendable {
    case refuseIfLoaded
    case unloadAndRemove
}

/// Registry and in-memory lifecycle facts for one exact installed model.
public struct InstalledModelStatus: Hashable, Sendable {
    /// Exact manifest-derived model identity.
    public let key: ModelKey
    /// Durable registry state.
    public let state: ModelInstallationState
    /// Whether this process currently owns a loaded session.
    public let isLoaded: Bool
    /// Whether default removal can proceed without unloading a session.
    public let isSafeToRemove: Bool

    /// Creates a model lifecycle summary.
    public init(
        key: ModelKey,
        state: ModelInstallationState,
        isLoaded: Bool,
        isSafeToRemove: Bool
    ) {
        self.key = key
        self.state = state
        self.isLoaded = isLoaded
        self.isSafeToRemove = isSafeToRemove
    }
}

/// Safe public failures from model-store workflows.
public enum InferPeerModelStoreError: Error, Equatable, Sendable {
    case catalogEntryNotFound(ModelCatalogKey)
    case modelNotInstalled(ModelKey)
    case modelAlreadyLoaded(ModelKey)
    case modelNotLoaded(ModelKey)
    case modelInUse(ModelKey)
    case adapterReturnedWrongModel(expected: ModelKey, actual: ModelKey)
    case requestModelMismatch
    case taskUnsupportedForLoadedSession(InferenceTask)
    case remoteApprovalRequired(ResourceID)
    case licenseAcceptanceRequired(String)
    case incompatible(ModelSupport)
    case downloadAlreadyRunning(ModelCatalogKey)
    case unsafeImportLocation
    case archiveImporterRequired
    case fileSystemFailure
}
