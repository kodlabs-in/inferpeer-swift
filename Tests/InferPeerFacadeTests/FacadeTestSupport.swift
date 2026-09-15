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
    private(set) var callerInvitationIDs: [InvitationID] = []
    private(set) var workerInvitationIDs: [InvitationID] = []
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

    func connectCaller(
        to endpoint: PeerEndpoint,
        invitation: PairingInvitation
    ) -> any CallerTransportSession {
        callerInvitationIDs.append(invitation.invitationID)
        return connectCaller(to: endpoint)
    }

    func connectWorker(
        to endpoint: PeerEndpoint,
        invitation: PairingInvitation
    ) -> any WorkerTransportSession {
        workerInvitationIDs.append(invitation.invitationID)
        return connectWorker(to: endpoint)
    }

    func stop() {
        stopCount += 1
    }
}

actor SuspendedListenTransport: PeerTransport {
    private var listenStartedContinuation: CheckedContinuation<Void, Never>?
    private var listenResumeContinuation: CheckedContinuation<Void, Never>?
    private(set) var listenCount = 0
    private(set) var stopCount = 0

    func listen(at endpoint: PeerEndpoint) async -> any CoordinatorTransportListener {
        listenCount += 1
        listenStartedContinuation?.resume()
        listenStartedContinuation = nil
        await withCheckedContinuation { continuation in
            listenResumeContinuation = continuation
        }
        return FakeListener()
    }

    func waitUntilListenStarts() async {
        guard listenCount == 0 else { return }
        await withCheckedContinuation { continuation in
            listenStartedContinuation = continuation
        }
    }

    func resumeListen() {
        listenResumeContinuation?.resume()
        listenResumeContinuation = nil
    }

    func connectCaller(to endpoint: PeerEndpoint) -> any CallerTransportSession {
        FakeCallerSession()
    }

    func connectWorker(to endpoint: PeerEndpoint) -> any WorkerTransportSession {
        FakeWorkerSession()
    }

    func stop() {
        stopCount += 1
    }
}

actor SuspendedJoinTransport: PeerTransport {
    nonisolated let callerSession = CloseTrackingCallerSession()
    private var joinStartedContinuation: CheckedContinuation<Void, Never>?
    private var joinResumeContinuation: CheckedContinuation<Void, Never>?
    private(set) var joinCount = 0

    func listen(at endpoint: PeerEndpoint) -> any CoordinatorTransportListener {
        FakeListener()
    }

    func connectCaller(to endpoint: PeerEndpoint) -> any CallerTransportSession {
        callerSession
    }

    func connectCaller(
        to endpoint: PeerEndpoint,
        invitation: PairingInvitation
    ) async -> any CallerTransportSession {
        joinCount += 1
        joinStartedContinuation?.resume()
        joinStartedContinuation = nil
        await withCheckedContinuation { continuation in
            joinResumeContinuation = continuation
        }
        return callerSession
    }

    func waitUntilJoinStarts() async {
        guard joinCount == 0 else { return }
        await withCheckedContinuation { continuation in
            joinStartedContinuation = continuation
        }
    }

    func resumeJoin() {
        joinResumeContinuation?.resume()
        joinResumeContinuation = nil
    }

    func connectWorker(to endpoint: PeerEndpoint) -> any WorkerTransportSession {
        FakeWorkerSession()
    }

    func stop() {}
}

actor CloseTrackingCallerSession: CallerTransportSession {
    private(set) var closeCount = 0

    func send(_ request: InferPeer_V1_ClientSessionRequest) {}

    nonisolated func responses(bufferingLimit: Int) -> CallerResponseStream {
        CallerResponseStream { $0.finish() }
    }

    func close() {
        closeCount += 1
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

actor FakeCoordinatorService: CoordinatorServing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var revokedPeerIDs: [PeerID] = []

    func start(listener: any CoordinatorTransportListener) {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func revoke(peerID: PeerID) {
        revokedPeerIDs.append(peerID)
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
    private var pendingRequests: [StoredOutboxRequest]
    private var replayStates: [RequestID: CallerReplayState] = [:]

    init(pendingRequests: [StoredOutboxRequest] = []) {
        self.pendingRequests = pendingRequests
    }

    func enqueue(_ submission: RequestSubmission) -> OutboxEnqueueResult {
        enqueuedRequestIDs.append(submission.requestID)
        let stored = StoredOutboxRequest(submission: submission, enqueuedAt: Date())
        pendingRequests.append(stored)
        return .enqueued(stored)
    }

    func pending(callerID: PeerID, limit: Int) -> [StoredOutboxRequest] {
        Array(pendingRequests.filter { $0.submission.callerID == callerID }.prefix(limit))
    }

    func remove(requestID: RequestID, callerID: PeerID) {
        removedRequestIDs.append(requestID)
        pendingRequests.removeAll { $0.submission.requestID == requestID }
    }

    func replayState(requestID: RequestID, callerID: PeerID) -> CallerReplayState? {
        replayStates[requestID]
    }

    func recordReceived(requestID: RequestID, callerID: PeerID, cursor: UInt64) {
        let previous = replayStates[requestID]
        replayStates[requestID] = CallerReplayState(
            latestCursor: max(previous?.latestCursor ?? 0, cursor),
            acknowledgedCursor: previous?.acknowledgedCursor
        )
    }

    func recordAcknowledged(requestID: RequestID, callerID: PeerID, cursor: UInt64) {
        let previous = replayStates[requestID]
        replayStates[requestID] = CallerReplayState(
            latestCursor: max(previous?.latestCursor ?? 0, cursor),
            acknowledgedCursor: max(previous?.acknowledgedCursor ?? 0, cursor)
        )
    }
}
