import Foundation
import InferPeerCore
import InferPeerInference

/// A catalog entry paired with resource-specific support details and deterministic rank.
public struct ModelCandidate: Sendable {
    /// Exact candidate entry.
    public let entry: ModelCatalogEntry
    /// Resource against which support was evaluated.
    public let resourceID: ResourceID
    /// Supported, experimental, or unsupported with reasons.
    public let support: ModelSupport
    /// Deterministic lower-is-better recommendation rank.
    public let rank: Int

    /// Creates an explained resource-specific candidate.
    public init(
        entry: ModelCatalogEntry,
        resourceID: ResourceID,
        support: ModelSupport,
        rank: Int
    ) {
        self.entry = entry
        self.resourceID = resourceID
        self.support = support
        self.rank = rank
    }
}

/// Evaluates actual resource facts and registered adapter support independently.
struct ModelCompatibilityEvaluator: Sendable {
    private let adapters: RuntimeAdapterRegistry

    init(adapters: RuntimeAdapterRegistry) {
        self.adapters = adapters
    }

    func support(
        for entry: ModelCatalogEntry,
        task: InferenceTask,
        on device: ModelStoreDeviceProfile
    ) async -> ModelSupport {
        let runtimeID = RuntimeID(rawValue: entry.manifest.runtime.runtimeIdentifier)
        var unsupported = structuralReasons(for: entry, task: task, device: device)
        guard let adapter = await adapters.adapter(for: runtimeID) else {
            unsupported.append(.adapterUnavailable(runtimeID))
            return .unsupported(reasons: unsupported)
        }
        if Self.version(
            adapter.runtimeVersion, isOlderThan: entry.manifest.runtime.minimumBackendVersion)
        {
            unsupported.append(
                .adapterVersionTooOld(
                    required: entry.manifest.runtime.minimumBackendVersion,
                    installed: adapter.runtimeVersion
                )
            )
        }
        let adapterSupport = await adapter.support(for: entry.manifest, on: device)
        return Self.combine(
            unsupported: unsupported,
            experimental: experimentalReasons(for: entry, device: device),
            adapterSupport: adapterSupport
        )
    }

    private func structuralReasons(
        for entry: ModelCatalogEntry,
        task: InferenceTask,
        device: ModelStoreDeviceProfile
    ) -> [ModelCompatibilityReason] {
        var reasons: [ModelCompatibilityReason] = []
        if entry.metadata.status == .blocked { reasons.append(.catalogBlocked) }
        if !entry.manifest.capabilities.contains(where: { $0.task == task }) {
            reasons.append(.taskUnsupported(task))
        }
        reasons.append(contentsOf: Self.operatingSystemReasons(entry, device: device))
        reasons.append(contentsOf: Self.hardwareReasons(entry, device: device))
        reasons.append(contentsOf: Self.resourceReasons(entry, device: device))
        return reasons
    }

    private func experimentalReasons(
        for entry: ModelCatalogEntry,
        device: ModelStoreDeviceProfile
    ) -> [ModelCompatibilityReason] {
        var reasons: [ModelCompatibilityReason] = []
        if entry.metadata.status != .stable, entry.metadata.status != .blocked {
            reasons.append(.catalogNotStable(entry.metadata.status))
        }
        let hardware = device.platform.hardwareIdentifier
        if hardware == nil
            || !entry.validation.contains(where: { $0.hardwareIdentifier == hardware })
        {
            reasons.append(.notValidatedOnDevice(hardware))
        }
        return reasons
    }

    private static func operatingSystemReasons(
        _ entry: ModelCatalogEntry,
        device: ModelStoreDeviceProfile
    ) -> [ModelCompatibilityReason] {
        let operatingSystem = catalogOperatingSystem(device.platform.operatingSystem)
        guard
            let requirement = entry.requirements.minimumOperatingSystems.first(where: {
                $0.operatingSystem == operatingSystem
            })
        else {
            return [.operatingSystemUnsupported(device.platform.operatingSystem)]
        }
        guard version(device.platform.operatingSystemVersion, isOlderThan: requirement.version)
        else {
            return []
        }
        return [
            .operatingSystemTooOld(
                required: requirement.version,
                installed: device.platform.operatingSystemVersion
            )
        ]
    }

    private static func hardwareReasons(
        _ entry: ModelCatalogEntry,
        device: ModelStoreDeviceProfile
    ) -> [ModelCompatibilityReason] {
        var reasons: [ModelCompatibilityReason] = []
        let families = entry.requirements.supportedDeviceFamilies
        if !families.isEmpty {
            let identifier = device.platform.hardwareIdentifier ?? "unknown"
            if !families.contains(where: identifier.hasPrefix) {
                reasons.append(.deviceFamilyUnsupported(identifier))
            }
        }
        let missingFeatures = Set(entry.requirements.requiredChipFeatures)
            .subtracting(device.chipFeatures)
            .sorted()
        reasons.append(contentsOf: missingFeatures.map(ModelCompatibilityReason.chipFeatureMissing))
        return reasons
    }

    private static func resourceReasons(
        _ entry: ModelCatalogEntry,
        device: ModelStoreDeviceProfile
    ) -> [ModelCompatibilityReason] {
        let requirements = entry.requirements.resources
        var reasons: [ModelCompatibilityReason] = []
        if let required = requirements.minimumPhysicalMemoryBytes {
            reasons.append(contentsOf: physicalMemoryReason(required, device: device))
        }
        if let required = requirements.minimumAvailableMemoryBytes {
            reasons.append(contentsOf: availableMemoryReason(required, device: device))
        }
        reasons.append(
            contentsOf: storageReason(requirements.minimumFreeStorageBytes, device: device))
        return reasons
    }

    private static func physicalMemoryReason(
        _ required: UInt64,
        device: ModelStoreDeviceProfile
    ) -> [ModelCompatibilityReason] {
        guard let actual = device.physicalMemoryBytes else {
            return [.physicalMemoryUnknown(required: required)]
        }
        return actual >= required
            ? []
            : [.physicalMemoryInsufficient(required: required, available: actual)]
    }

    private static func availableMemoryReason(
        _ required: UInt64,
        device: ModelStoreDeviceProfile
    ) -> [ModelCompatibilityReason] {
        guard let actual = device.availableMemoryBytes else {
            return [.availableMemoryUnknown(required: required)]
        }
        return actual >= required
            ? []
            : [.availableMemoryInsufficient(required: required, available: actual)]
    }

    private static func storageReason(
        _ required: UInt64,
        device: ModelStoreDeviceProfile
    ) -> [ModelCompatibilityReason] {
        guard let actual = device.freeStorageBytes else {
            return [.storageUnknown(required: required)]
        }
        return actual >= required
            ? []
            : [.storageInsufficient(required: required, available: actual)]
    }

    private static func combine(
        unsupported: [ModelCompatibilityReason],
        experimental: [ModelCompatibilityReason],
        adapterSupport: ModelSupport
    ) -> ModelSupport {
        var unsupported = unsupported
        var experimental = experimental
        switch adapterSupport {
        case .supported:
            break
        case .experimental(let reasons):
            experimental.append(contentsOf: reasons)
        case .unsupported(let reasons):
            unsupported.append(contentsOf: reasons)
        }
        if !unsupported.isEmpty { return .unsupported(reasons: unsupported) }
        if !experimental.isEmpty { return .experimental(reasons: experimental) }
        return .supported
    }

    private static func catalogOperatingSystem(
        _ operatingSystem: PlatformDescriptor.OperatingSystem
    ) -> CatalogOperatingSystem {
        switch operatingSystem {
        case .iOS:
            .iOS
        case .iPadOS:
            .iPadOS
        case .macOS:
            .macOS
        }
    }

    private static func version(_ installed: String, isOlderThan required: String) -> Bool {
        let lhs = installed.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = required.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// Ranks compatible candidates for each caller-selected resource without fallback.
struct ModelRecommendationEngine: Sendable {
    private let evaluator: ModelCompatibilityEvaluator

    init(evaluator: ModelCompatibilityEvaluator) {
        self.evaluator = evaluator
    }

    func candidates(
        in catalog: ModelCatalog,
        task: InferenceTask,
        device: ModelStoreDeviceProfile
    ) async -> [ModelCandidate] {
        var candidates: [ModelCandidate] = []
        for entry in catalog.entries {
            let support = await evaluator.support(for: entry, task: task, on: device)
            let rank = Self.rank(entry: entry, support: support, device: device)
            candidates.append(
                ModelCandidate(
                    entry: entry,
                    resourceID: device.resourceID,
                    support: support,
                    rank: rank
                )
            )
        }
        return candidates.sorted(by: Self.precedes)
    }

    func recommended(
        in catalog: ModelCatalog,
        task: InferenceTask,
        device: ModelStoreDeviceProfile
    ) async -> ModelCandidate? {
        await candidates(in: catalog, task: task, device: device)
            .first(where: { $0.support.isInstallable })
    }

    private static func rank(
        entry: ModelCatalogEntry,
        support: ModelSupport,
        device: ModelStoreDeviceProfile
    ) -> Int {
        let supportScore: Int
        switch support {
        case .supported:
            supportScore = 0
        case .experimental:
            supportScore = 1_000
        case .unsupported:
            supportScore = 10_000
        }
        let tierScore = entry.metadata.recommendedTier == device.tier ? 0 : 100
        let sizeScore = Int(min(entry.approximateDownloadBytes / 1_000_000, 999))
        return supportScore + tierScore + sizeScore
    }

    private static func precedes(_ lhs: ModelCandidate, _ rhs: ModelCandidate) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return lhs.entry.metadata.key.modelID.rawValue
            < rhs.entry.metadata.key.modelID.rawValue
    }
}
