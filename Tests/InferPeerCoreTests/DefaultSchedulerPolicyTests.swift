import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Default scheduler policy")
struct DefaultSchedulerPolicyTests {
    @Test("Filters ineligible workers before comparing scores")
    func filtersIneligibleWorkers() throws {
        let model = try makeModelReference("model-1")
        let request = try makeRequest(model: model)
        let policy = try makePolicy()
        let now = MonotonicInstant(nanoseconds: 20_000_000_000)
        let candidates = try makeEligibilityCandidates(model: model)

        let selected = policy.selectWorker(for: request, from: candidates, at: now)

        #expect(selected?.peerID.rawValue == "eligible")
    }

    @Test("Minimizes predicted completion time")
    func minimizesCompletionTime() throws {
        let model = try makeModelReference("model-1")
        let request = try makeRequest(model: model)
        let candidates = [
            try makeCandidate(
                peer: "slow",
                model: model,
                options: CandidateOptions(scoreSeconds: 8)
            ),
            try makeCandidate(
                peer: "fast",
                model: model,
                options: CandidateOptions(scoreSeconds: 2)
            ),
        ]

        let selected = try makePolicy().selectWorker(
            for: request,
            from: candidates,
            at: MonotonicInstant(nanoseconds: 20_000_000_000)
        )

        #expect(selected?.peerID.rawValue == "fast")
    }

    @Test("Prefers a warm model only when its estimate is close")
    func appliesWarmPreferenceTolerance() throws {
        let model = try makeModelReference("model-1")
        let request = try makeRequest(model: model)
        let cold = try makeCandidate(
            peer: "cold",
            model: model,
            options: CandidateOptions(scoreSeconds: 2)
        )
        let closeWarm = try makeCandidate(
            peer: "warm",
            model: model,
            options: CandidateOptions(loaded: true, scoreSeconds: 2.2)
        )
        let slowWarm = try makeCandidate(
            peer: "warm",
            model: model,
            options: CandidateOptions(loaded: true, scoreSeconds: 4)
        )
        let policy = try makePolicy()
        let now = MonotonicInstant(nanoseconds: 20_000_000_000)

        let closeSelection = policy.selectWorker(
            for: request,
            from: [cold, closeWarm],
            at: now
        )
        let slowSelection = policy.selectWorker(
            for: request,
            from: [cold, slowWarm],
            at: now
        )

        #expect(closeSelection?.peerID.rawValue == "warm")
        #expect(slowSelection?.peerID.rawValue == "cold")
    }

    @Test("Honors model and allowed-worker restrictions")
    func honorsRequestRestrictions() throws {
        let requiredModel = try makeModelReference("model-1")
        let otherModel = try makeModelReference("model-2")
        let allowedPeer = try #require(PeerID(rawValue: "allowed"))
        let request = try makeRequest(model: requiredModel, allowedWorkerIDs: [allowedPeer])
        let candidates = [
            try makeCandidate(
                peer: "other-worker",
                model: requiredModel,
                options: CandidateOptions(scoreSeconds: 1)
            ),
            try makeCandidate(
                peer: "allowed",
                model: otherModel,
                options: CandidateOptions(scoreSeconds: 1)
            ),
            try makeCandidate(
                peer: "allowed",
                model: requiredModel,
                options: CandidateOptions(scoreSeconds: 4)
            ),
        ]

        let selected = try makePolicy().selectWorker(
            for: request,
            from: candidates,
            at: MonotonicInstant(nanoseconds: 20_000_000_000)
        )

        #expect(selected?.peerID == allowedPeer)
        #expect(selected?.model == requiredModel)
    }

    private func makePolicy() throws -> DefaultSchedulerPolicy {
        let fallbacks = try SchedulingFallbacks(
            modelLoadDuration: .seconds(5),
            promptProcessingDuration: .seconds(1),
            inputTransferDuration: .milliseconds(100),
            generationTokensPerSecond: 10
        )
        let configuration = try SchedulerConfiguration(
            heartbeatTimeout: .seconds(15),
            warmModelPreferenceTolerance: .milliseconds(500),
            lowPowerModePenalty: .seconds(5),
            fallbacks: fallbacks
        )
        return DefaultSchedulerPolicy(configuration: configuration)
    }

    private func makeEligibilityCandidates(
        model: ModelReference
    ) throws -> [SchedulingCandidate] {
        let stale = MonotonicInstant(nanoseconds: 0)
        let options = [
            ("unauthorized", CandidateOptions(authorized: false, scoreSeconds: 1)),
            ("too-hot", CandidateOptions(thermalState: .serious, scoreSeconds: 1)),
            ("stale", CandidateOptions(lastHeartbeat: stale, scoreSeconds: 1)),
            ("draining", CandidateOptions(participation: .draining, scoreSeconds: 1)),
            ("full", CandidateOptions(activeGenerations: 1, scoreSeconds: 1)),
            ("low-memory", CandidateOptions(availableMemoryBytes: 1_000, scoreSeconds: 1)),
            ("eligible", CandidateOptions(scoreSeconds: 3)),
        ]
        return try options.map { peer, options in
            try makeCandidate(peer: peer, model: model, options: options)
        }
    }

    private func makeCandidate(
        peer: String,
        model: ModelReference,
        options: CandidateOptions
    ) throws -> SchedulingCandidate {
        let peerID = try #require(PeerID(rawValue: peer))
        let condition = WorkerCondition(
            participation: options.participation,
            thermalState: options.thermalState,
            lowPowerModeEnabled: false
        )
        let load = WorkerLoad(
            activeGenerations: options.activeGenerations,
            generationCapacity: 1,
            availableAppMemoryBytes: options.availableMemoryBytes
        )
        let worker = WorkerSnapshot(
            peerID: peerID,
            isAuthorized: options.authorized,
            lastHeartbeat: options.lastHeartbeat,
            condition: condition,
            load: load
        )
        let estimate = try InferenceResourceEstimate(
            peakMemoryBytes: 2_000_000_000,
            modelLoadDuration: .zero,
            promptProcessingDuration: .zero,
            generationTokensPerSecond: 1_000_000
        )
        return SchedulingCandidate(
            worker: worker,
            model: model,
            isModelLoaded: options.loaded,
            estimate: estimate,
            timings: SchedulingTimings(
                queueDelay: .seconds(options.scoreSeconds),
                inputTransferDuration: .zero
            )
        )
    }

    private func makeRequest(
        model: ModelReference,
        allowedWorkerIDs: Set<PeerID> = []
    ) throws -> TextGenerationRequest {
        let conversationID = try #require(ConversationID(rawValue: "conversation-1"))
        let context = try ConversationContext(
            conversationID: conversationID,
            revision: 1,
            messages: [try TextMessage(role: .user, text: "Hello")]
        )
        let options = try GenerationOptions(
            modelRequirement: .exact(model),
            maximumOutputTokens: 64
        )
        return TextGenerationRequest(
            context: context,
            options: options,
            allowedWorkerIDs: allowedWorkerIDs
        )
    }

    private func makeModelReference(_ id: String) throws -> ModelReference {
        let modelID = try #require(ModelID(rawValue: id))
        return try ModelReference(modelID: modelID, revision: "revision-1")
    }
}

private struct CandidateOptions {
    var authorized = true
    var thermalState = WorkerThermalState.nominal
    var lastHeartbeat = MonotonicInstant(nanoseconds: 19_000_000_000)
    var loaded = false
    var participation = WorkerParticipationState.available
    var activeGenerations: UInt32 = 0
    var availableMemoryBytes: UInt64? = 4_000_000_000
    var scoreSeconds: Double
}
