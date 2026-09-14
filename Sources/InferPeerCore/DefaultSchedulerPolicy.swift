import InferPeerInference

/// Eligibility-first scheduler using deterministic estimated-completion scoring.
public struct DefaultSchedulerPolicy: SchedulerPolicy, Sendable {
    private let configuration: SchedulerConfiguration

    /// Creates a scheduler with explicit timing and fallback policy.
    public init(configuration: SchedulerConfiguration) {
        self.configuration = configuration
    }

    /// Selects the best eligible candidate with a bounded warm-model preference.
    public func selectWorker(
        for request: TextGenerationRequest,
        from candidates: [SchedulingCandidate],
        at now: MonotonicInstant
    ) -> ScheduledWorker? {
        let ranked =
            candidates
            .filter { isEligible($0, for: request, at: now) }
            .map { ScoredCandidate(candidate: $0, duration: score($0, for: request)) }
            .sorted(by: Self.isOrderedBefore)
        guard let best = ranked.first else { return nil }
        let selected = preferredWarmCandidate(in: ranked, comparedWith: best) ?? best
        return ScheduledWorker(
            peerID: selected.candidate.worker.peerID,
            model: selected.candidate.model,
            estimatedCompletionDuration: selected.duration
        )
    }

    private func isEligible(
        _ candidate: SchedulingCandidate,
        for request: TextGenerationRequest,
        at now: MonotonicInstant
    ) -> Bool {
        isIdentityEligible(candidate.worker, for: request)
            && isModelEligible(candidate.model, for: request)
            && isWorkerAvailable(candidate.worker)
            && hasFreshHeartbeat(candidate.worker, at: now)
            && hasSufficientMemory(candidate)
    }

    private func isIdentityEligible(
        _ worker: WorkerSnapshot,
        for request: TextGenerationRequest
    ) -> Bool {
        guard worker.isAuthorized else { return false }
        let allowedWorkerIDs = request.allowedWorkerIDs
        return allowedWorkerIDs.isEmpty || allowedWorkerIDs.contains(worker.peerID)
    }

    private func isModelEligible(
        _ model: ModelReference,
        for request: TextGenerationRequest
    ) -> Bool {
        switch request.options.modelRequirement.selection {
        case .exact(let required):
            model == required
        case .permittedModels(let permitted):
            permitted.contains(model)
        }
    }

    private func isWorkerAvailable(_ worker: WorkerSnapshot) -> Bool {
        worker.condition.participation == .available
            && worker.condition.thermalState.permitsAdmission
            && worker.load.hasAvailableSlot
    }

    private func hasFreshHeartbeat(
        _ worker: WorkerSnapshot,
        at now: MonotonicInstant
    ) -> Bool {
        now.elapsed(since: worker.lastHeartbeat) <= configuration.heartbeatTimeout
    }

    private func hasSufficientMemory(_ candidate: SchedulingCandidate) -> Bool {
        guard let required = candidate.estimate.peakMemoryBytes else { return true }
        guard let available = candidate.worker.load.availableAppMemoryBytes else { return true }
        return required <= available
    }

    private func score(
        _ candidate: SchedulingCandidate,
        for request: TextGenerationRequest
    ) -> Duration {
        let loadDuration =
            candidate.isModelLoaded
            ? .zero
            : candidate.estimate.modelLoadDuration ?? configuration.fallbacks.modelLoadDuration
        let transferDuration =
            candidate.timings.inputTransferDuration
            ?? configuration.fallbacks.inputTransferDuration
        let promptDuration =
            candidate.estimate.promptProcessingDuration
            ?? configuration.fallbacks.promptProcessingDuration
        let generationRate =
            candidate.estimate.generationTokensPerSecond
            ?? configuration.fallbacks.generationTokensPerSecond
        let generationDuration = Duration.seconds(
            Double(request.options.maximumOutputTokens) / generationRate
        )
        let powerPenalty =
            candidate.worker.condition.lowPowerModeEnabled == true
            ? configuration.lowPowerModePenalty
            : .zero
        return candidate.timings.queueDelay
            + loadDuration
            + transferDuration
            + promptDuration
            + generationDuration
            + powerPenalty
    }

    private func preferredWarmCandidate(
        in ranked: [ScoredCandidate],
        comparedWith best: ScoredCandidate
    ) -> ScoredCandidate? {
        let latestPreferredDuration =
            best.duration
            + configuration.warmModelPreferenceTolerance
        return ranked.first {
            $0.candidate.isModelLoaded && $0.duration <= latestPreferredDuration
        }
    }

    private static func isOrderedBefore(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate) -> Bool {
        if lhs.duration != rhs.duration {
            return lhs.duration < rhs.duration
        }
        let lhsPeerID = lhs.candidate.worker.peerID.rawValue
        let rhsPeerID = rhs.candidate.worker.peerID.rawValue
        if lhsPeerID != rhsPeerID {
            return lhsPeerID < rhsPeerID
        }
        let lhsModelID = lhs.candidate.model.modelID.rawValue
        let rhsModelID = rhs.candidate.model.modelID.rawValue
        if lhsModelID != rhsModelID {
            return lhsModelID < rhsModelID
        }
        return lhs.candidate.model.revision < rhs.candidate.model.revision
    }
}

private struct ScoredCandidate: Sendable {
    let candidate: SchedulingCandidate
    let duration: Duration
}
