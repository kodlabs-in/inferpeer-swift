import Foundation
import InferPeerProtocol

/// Semantic roles for files declared by a versioned model manifest.
public enum ModelManifestFileRole: String, Codable, CaseIterable, Hashable, Sendable {
    case weights
    case tokenizer
    case chatTemplate
    case projector
    case processorConfiguration
    case audioModel
    case voiceAsset
    case runtimeConfiguration
    case otherData
}

/// One immutable file expected in a staged model artifact.
public struct ModelManifestFile: Codable, Hashable, Sendable {
    /// Relative path below the artifact root.
    public let relativePath: String

    /// Purpose of the file.
    public let role: ModelManifestFileRole

    /// Exact expected byte count.
    public let byteCount: UInt64

    /// Exact expected SHA-256 digest.
    public let sha256: ModelContentDigest

    /// Creates a bounded relative file declaration.
    public init(
        relativePath: String,
        role: ModelManifestFileRole,
        byteCount: UInt64,
        sha256: ModelContentDigest
    ) throws {
        guard Self.valid(relativePath: relativePath) else {
            throw ModelManifestValidationError.invalidRelativePath(relativePath)
        }
        guard byteCount > 0 else {
            throw ModelManifestValidationError.invalidFileSize(relativePath)
        }
        self.relativePath = relativePath
        self.role = role
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    private static func valid(relativePath: String) -> Bool {
        guard !relativePath.isEmpty, relativePath.utf8.count <= 512 else { return false }
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("\\") else {
            return false
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
                && !component.contains("\\") && !component.contains("\0")
        }
    }
}

/// Runtime and file-format compatibility declared independently of an engine package.
public struct ModelManifestRuntime: Codable, Hashable, Sendable {
    /// Engine family expected to load the artifact.
    public let runtimeIdentifier: String

    /// On-disk representation such as GGUF, MLX, or Core ML.
    public let format: String

    /// Exact quantization description.
    public let quantization: String

    /// Tensor-layout identifier when the runtime requires one.
    public let tensorLayout: String?

    /// Oldest compatible backend adapter version.
    public let minimumBackendVersion: String

    /// Creates bounded engine-neutral runtime requirements.
    public init(
        runtimeIdentifier: String,
        format: String,
        quantization: String,
        tensorLayout: String? = nil,
        minimumBackendVersion: String
    ) throws {
        try Self.validate(runtimeIdentifier, field: "runtimeIdentifier")
        try Self.validate(format, field: "format")
        try Self.validate(quantization, field: "quantization")
        if let tensorLayout {
            try Self.validate(tensorLayout, field: "tensorLayout")
        }
        try Self.validate(minimumBackendVersion, field: "minimumBackendVersion")
        self.runtimeIdentifier = runtimeIdentifier
        self.format = format
        self.quantization = quantization
        self.tensorLayout = tensorLayout
        self.minimumBackendVersion = minimumBackendVersion
    }

    private static func validate(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.utf8.count <= 256
        else {
            throw ModelManifestValidationError.invalidTextField(field)
        }
    }
}

/// Limits and media options for one task supported by an artifact.
public struct ModelTaskCapability: Codable, Hashable, Sendable {
    /// Supported inference operation.
    public let task: InferenceTask

    /// Combined text context limit when relevant.
    public let contextTokenLimit: UInt32?

    /// Generated token limit when relevant.
    public let maximumOutputTokens: UInt32?

    /// Media attachment count limit when relevant.
    public let maximumInputAssets: UInt32?

    /// Accepted media or text format identifiers.
    public let inputFormats: [String]

    /// Produced media or text format identifiers.
    public let outputFormats: [String]

    /// Explicit supported language codes, if constrained.
    public let languageCodes: [String]

    /// Exact installed voice identities, if applicable.
    public let voiceIDs: [String]

    /// Creates and validates one task-specific capability declaration.
    public init(
        task: InferenceTask,
        contextTokenLimit: UInt32? = nil,
        maximumOutputTokens: UInt32? = nil,
        maximumInputAssets: UInt32? = nil,
        inputFormats: [String] = [],
        outputFormats: [String] = [],
        languageCodes: [String] = [],
        voiceIDs: [String] = []
    ) throws {
        let inputFormats = try Self.normalized(inputFormats, field: "inputFormats")
        let outputFormats = try Self.normalized(outputFormats, field: "outputFormats")
        let languageCodes = try Self.normalized(languageCodes, field: "languageCodes")
        let voiceIDs = try Self.normalized(voiceIDs, field: "voiceIDs")
        try Self.validateLimits(
            ValidationInput(
                task: task,
                contextTokenLimit: contextTokenLimit,
                maximumOutputTokens: maximumOutputTokens,
                maximumInputAssets: maximumInputAssets,
                inputFormats: inputFormats,
                outputFormats: outputFormats,
                voiceIDs: voiceIDs
            )
        )
        self.task = task
        self.contextTokenLimit = contextTokenLimit
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumInputAssets = maximumInputAssets
        self.inputFormats = inputFormats
        self.outputFormats = outputFormats
        self.languageCodes = languageCodes
        self.voiceIDs = voiceIDs
    }

    private static func normalized(_ values: [String], field: String) throws -> [String] {
        guard
            values.allSatisfy({ value in
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && value.utf8.count <= 128
            })
        else {
            throw ModelManifestValidationError.invalidTextField(field)
        }
        return Array(Set(values)).sorted()
    }

    private static func validateLimits(_ input: ValidationInput) throws {
        switch input.task {
        case .textGeneration:
            try requireTextLimits(input)
        case .imageUnderstanding:
            try requireTextLimits(input)
            guard input.maximumInputAssets ?? 0 > 0, !input.inputFormats.isEmpty else {
                throw ModelManifestValidationError.invalidTaskLimits(input.task)
            }
        case .transcribe:
            guard !input.inputFormats.isEmpty else {
                throw ModelManifestValidationError.invalidTaskLimits(input.task)
            }
        case .synthesizeSpeech:
            guard !input.outputFormats.isEmpty, !input.voiceIDs.isEmpty else {
                throw ModelManifestValidationError.invalidTaskLimits(input.task)
            }
        }
    }

    private static func requireTextLimits(_ input: ValidationInput) throws {
        guard let contextTokenLimit = input.contextTokenLimit, contextTokenLimit > 0,
            let maximumOutputTokens = input.maximumOutputTokens, maximumOutputTokens > 0,
            maximumOutputTokens <= contextTokenLimit
        else {
            throw ModelManifestValidationError.invalidTaskLimits(input.task)
        }
    }

    private struct ValidationInput {
        let task: InferenceTask
        let contextTokenLimit: UInt32?
        let maximumOutputTokens: UInt32?
        let maximumInputAssets: UInt32?
        let inputFormats: [String]
        let outputFormats: [String]
        let voiceIDs: [String]
    }
}

/// Optional measured memory and load profile for one device class.
public struct ModelDeviceProfile: Codable, Hashable, Sendable {
    /// Hardware or host-defined device class.
    public let deviceClass: String

    /// Measured cold-load duration.
    public let loadMilliseconds: UInt64

    /// Measured resident footprint after loading.
    public let steadyMemoryBytes: UInt64

    /// Measured peak process footprint.
    public let peakMemoryBytes: UInt64

    /// Estimated additional per-run working memory.
    public let workingMemoryBytes: UInt64

    /// Creates a nonzero measured profile.
    public init(
        deviceClass: String,
        loadMilliseconds: UInt64,
        steadyMemoryBytes: UInt64,
        peakMemoryBytes: UInt64,
        workingMemoryBytes: UInt64
    ) throws {
        guard !deviceClass.isEmpty, deviceClass.utf8.count <= 128,
            loadMilliseconds > 0, steadyMemoryBytes > 0,
            peakMemoryBytes >= steadyMemoryBytes, workingMemoryBytes > 0
        else {
            throw ModelManifestValidationError.invalidDeviceProfile
        }
        self.deviceClass = deviceClass
        self.loadMilliseconds = loadMilliseconds
        self.steadyMemoryBytes = steadyMemoryBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.workingMemoryBytes = workingMemoryBytes
    }
}

/// Complete immutable metadata whose canonical bytes define an artifact revision.
public struct ModelManifest: Codable, Hashable, Sendable {
    /// Only schema version currently accepted for registration.
    public static let currentFormatVersion: UInt32 = 1

    /// Version controlling canonical manifest interpretation.
    public let formatVersion: UInt32

    /// Stable logical model family identifier.
    public let modelID: ModelID

    /// Human-readable upstream family.
    public let family: String

    /// Human-readable artifact name.
    public let name: String

    /// Immutable upstream source revision.
    public let upstreamRevision: String

    /// Auditable source metadata; registration never fetches it.
    public let source: String

    /// Model license identifier or expression.
    public let license: String

    /// Runtime compatibility requirements.
    public let runtime: ModelManifestRuntime

    /// Complete declared file tree.
    public let files: [ModelManifestFile]

    /// Task-specific formats and limits.
    public let capabilities: [ModelTaskCapability]

    /// Optional measured device profiles.
    public let deviceProfiles: [ModelDeviceProfile]

    /// Creates a canonical-order manifest after structural and role validation.
    public init(
        formatVersion: UInt32 = Self.currentFormatVersion,
        modelID: ModelID,
        family: String,
        name: String,
        upstreamRevision: String,
        source: String,
        license: String,
        runtime: ModelManifestRuntime,
        files: [ModelManifestFile],
        capabilities: [ModelTaskCapability],
        deviceProfiles: [ModelDeviceProfile] = []
    ) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw ModelManifestValidationError.unsupportedFormatVersion(formatVersion)
        }
        try Self.validateText(family, field: "family")
        try Self.validateText(name, field: "name")
        try Self.validateText(upstreamRevision, field: "upstreamRevision")
        try Self.validateText(source, field: "source")
        try Self.validateText(license, field: "license")
        try Self.validateUnique(files: files, capabilities: capabilities)
        try Self.validateRequiredRoles(files: files, capabilities: capabilities, runtime: runtime)
        self.formatVersion = formatVersion
        self.modelID = modelID
        self.family = family
        self.name = name
        self.upstreamRevision = upstreamRevision
        self.source = source
        self.license = license
        self.runtime = runtime
        self.files = files.sorted { $0.relativePath < $1.relativePath }
        self.capabilities = capabilities.sorted { $0.task.rawValue < $1.task.rawValue }
        self.deviceProfiles = deviceProfiles.sorted { $0.deviceClass < $1.deviceClass }
    }

    private static func validateText(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.utf8.count <= 512
        else {
            throw ModelManifestValidationError.invalidTextField(field)
        }
    }

    private static func validateUnique(
        files: [ModelManifestFile],
        capabilities: [ModelTaskCapability]
    ) throws {
        guard !files.isEmpty, Set(files.map(\.relativePath)).count == files.count else {
            throw ModelManifestValidationError.duplicateFilePath
        }
        guard !capabilities.isEmpty,
            Set(capabilities.map(\.task)).count == capabilities.count
        else {
            throw ModelManifestValidationError.duplicateTaskCapability
        }
    }

    private static func validateRequiredRoles(
        files: [ModelManifestFile],
        capabilities: [ModelTaskCapability],
        runtime: ModelManifestRuntime
    ) throws {
        let roles = Set(files.map(\.role))
        guard roles.contains(.weights) else {
            throw ModelManifestValidationError.missingFileRole(.weights)
        }
        let tasks = Set(capabilities.map(\.task))
        let isGGUF = runtime.format.caseInsensitiveCompare("GGUF") == .orderedSame
        if !isGGUF, !tasks.isDisjoint(with: [.textGeneration, .imageUnderstanding]) {
            try require([.tokenizer, .chatTemplate], in: roles)
        }
        if tasks.contains(.imageUnderstanding) {
            try require(isGGUF ? [.projector] : [.projector, .processorConfiguration], in: roles)
        }
        if tasks.contains(.transcribe) {
            try require([.audioModel], in: roles)
        }
        if tasks.contains(.synthesizeSpeech) {
            try require([.voiceAsset], in: roles)
        }
    }

    private static func require(
        _ required: [ModelManifestFileRole],
        in roles: Set<ModelManifestFileRole>
    ) throws {
        for role in required where !roles.contains(role) {
            throw ModelManifestValidationError.missingFileRole(role)
        }
    }
}
