import Foundation
@testable import InferPeer
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import InferPeerTelemetry
import Testing

actor FakeIdentityProvider: IdentityProvider {
    private(set) var consumedInvitationIDs: [InvitationID] = []

    func localIdentity() throws -> LocalPeerIdentity {
        let peerID = try #require(PeerID(rawValue: "local"))
        let fingerprint = try CertificateFingerprint(bytes: Data(repeating: 0xA5, count: 32))
        return LocalPeerIdentity(peerID: peerID, certificateFingerprint: fingerprint)
    }

    func trustDecision(for identity: PresentedPeerIdentity) -> PeerTrustDecision {
        .unknown
    }

    func approve(_ identity: PresentedPeerIdentity) {}

    func consume(_ invitation: PairingInvitation) {
        consumedInvitationIDs.append(invitation.invitationID)
    }

    func revoke(peerID: PeerID) {}
}

actor FakeTransport: PeerTransport {
    nonisolated let callerSession = FakeCallerSession()
    private(set) var listenEndpoints: [PeerEndpoint] = []
    private(set) var callerEndpoints: [PeerEndpoint] = []
    private(set) var workerEndpoints: [PeerEndpoint] = []
    private(set) var stopCount = 0

    func listen(at endpoint: PeerEndpoint) -> any CoordinatorTransportListener {
        listenEndpoints.append(endpoint)
        return FakeListener()
    }

    func connectCaller(to endpoint: PeerEndpoint) -> any CallerTransportSession {
        callerEndpoints.append(endpoint)
        return callerSession
    }

    func connectWorker(to endpoint: PeerEndpoint) -> any WorkerTransportSession {
        workerEndpoints.append(endpoint)
        return FakeWorkerSession()
    }

    func stop() {
        stopCount += 1
    }
}

actor FakeListener: CoordinatorTransportListener {
    nonisolated func sessions(bufferingLimit: Int) -> InboundPeerSessionStream {
        InboundPeerSessionStream { $0.finish() }
    }

    func close() {}
}

final class FakeCallerSession: CallerTransportSession, @unchecked Sendable {
    private let lock = NSLock()
    private let pair = CallerResponseStream.makeStream()
    private var storedRequests: [InferPeer_V1_ClientSessionRequest] = []

    var sentRequests: [InferPeer_V1_ClientSessionRequest] {
        lock.withLock { storedRequests }
    }

    // swiftlint:disable:next async_without_await
    func send(_ request: InferPeer_V1_ClientSessionRequest) async {
        lock.withLock { storedRequests.append(request) }
    }

    func responses(bufferingLimit: Int) -> CallerResponseStream {
        pair.stream
    }

    func emit(_ response: InferPeer_V1_ClientSessionResponse) {
        pair.continuation.yield(response)
    }

    // swiftlint:disable:next async_without_await
    func close() async {
        pair.continuation.finish()
    }
}

actor FakeWorkerSession: WorkerTransportSession {
    func send(_ request: InferPeer_V1_WorkerSessionRequest) {}

    nonisolated func responses(bufferingLimit: Int) -> WorkerResponseStream {
        WorkerResponseStream { $0.finish() }
    }

    func close() {}
}

actor FakeDiscovery: PeerDiscovery {
    func discover(bufferingLimit: Int) -> DiscoveryUpdateStream {
        DiscoveryUpdateStream { $0.finish() }
    }

    func candidate(for endpoint: PeerEndpoint) -> DiscoveredPeer {
        DiscoveredPeer(serviceName: "manual", endpoint: endpoint)
    }

    func stop() {}
}

actor FakeStatusProvider: WorkerStatusControlling {
    private var participation = WorkerParticipationState.unavailable

    func currentStatus() -> LocalWorkerStatus {
        LocalWorkerStatus(
            condition: WorkerCondition(
                participation: participation,
                thermalState: .unknown,
                lowPowerModeEnabled: nil
            ),
            load: WorkerLoad(
                activeGenerations: 0,
                generationCapacity: 1,
                availableAppMemoryBytes: nil
            ),
            models: []
        )
    }

    nonisolated func updates(bufferingLimit: Int) -> WorkerStatusStream {
        WorkerStatusStream { $0.finish() }
    }

    func setParticipation(_ participation: WorkerParticipationState) {
        self.participation = participation
    }

    func setActiveGenerations(_ count: UInt32) throws {}

    func setModels(_ models: [WorkerModelSnapshot]) {}

    func refresh() {}
}

actor FakeAdvertisement: InferPeerAdvertisement {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

actor FakeModelRegistry: InferPeerModelRegistry {
    let artifact: LocalModelArtifact
    private(set) var registrationCount = 0

    init(artifact: LocalModelArtifact) {
        self.artifact = artifact
    }

    func register(_ artifact: LocalModelArtifact) -> ModelRegistrationResult {
        registrationCount += 1
        return .registered(StoredModelRegistration(artifact: artifact, registeredAt: Date()))
    }

    func model(reference: ModelReference) -> StoredModelRegistration? {
        guard artifact.descriptor.reference == reference else { return nil }
        return StoredModelRegistration(artifact: artifact, registeredAt: Date())
    }
}

actor FakeInferenceBackend: InferenceBackend {
    private(set) var loadedReferences: [ModelReference] = []
    private(set) var unloadedReferences: [ModelReference] = []

    func estimateResources(
        for request: TextGenerationRequest,
        using model: ModelDescriptor
    ) throws -> InferenceResourceEstimate {
        try InferenceResourceEstimate()
    }

    func loadModel(_ model: LocalModelArtifact) {
        loadedReferences.append(model.descriptor.reference)
    }

    func unloadModel(_ reference: ModelReference) {
        unloadedReferences.append(reference)
    }

    func generate(_ execution: InferenceExecution) -> GenerationEventStream {
        GenerationEventStream { $0.finish() }
    }

    func cancel(attemptID: AttemptID) {}
}

actor FakeCallerOutbox: InferPeerCallerOutbox {
    private(set) var enqueuedRequestIDs: [RequestID] = []
    private(set) var removedRequestIDs: [RequestID] = []

    func enqueue(_ submission: RequestSubmission) -> OutboxEnqueueResult {
        enqueuedRequestIDs.append(submission.requestID)
        return .enqueued(StoredOutboxRequest(submission: submission, enqueuedAt: Date()))
    }

    func remove(requestID: RequestID, callerID: PeerID) {
        removedRequestIDs.append(requestID)
    }
}
