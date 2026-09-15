import GRPCCore
import Foundation
import InferPeerCore
import InferPeerProtocol

actor ValidatedMessageSender<Message: Sendable> {
    private var metadataValidator: OrderedMetadataValidator
    private let pipe: BoundedMessagePipe<Message>
    private let metadata: @Sendable (Message) -> InferPeer_V1_MessageMetadata
    private let payloadIsValid: @Sendable (Message) -> Bool

    init(
        metadataValidator: OrderedMetadataValidator,
        pipe: BoundedMessagePipe<Message>,
        metadata: @escaping @Sendable (Message) -> InferPeer_V1_MessageMetadata,
        payloadIsValid: @escaping @Sendable (Message) -> Bool
    ) {
        self.metadataValidator = metadataValidator
        self.pipe = pipe
        self.metadata = metadata
        self.payloadIsValid = payloadIsValid
    }

    func send(_ message: Message) async throws {
        guard payloadIsValid(message) else { throw InferPeerGRPCError.invalidMessage }
        try metadataValidator.validate(metadata(message))
        try await pipe.send(message)
    }
}

final class CoordinatorCallerSessionAdapter: CoordinatorCallerSession, @unchecked Sendable {
    let authenticatedPeerID: PeerID
    let inbound: BoundedMessagePipe<InferPeer_V1_ClientSessionRequest>
    let outbound: BoundedMessagePipe<InferPeer_V1_ClientSessionResponse>
    private let sender: ValidatedMessageSender<InferPeer_V1_ClientSessionResponse>

    init(
        authenticatedPeerID: PeerID,
        clusterID: ClusterID,
        coordinatorID: PeerID,
        negotiatedProtocol: InferPeer_V1_NegotiatedProtocol,
        capacity: Int
    ) {
        self.authenticatedPeerID = authenticatedPeerID
        inbound = BoundedMessagePipe(capacity: capacity, isControl: MessagePriority.clientRequest)
        outbound = BoundedMessagePipe(
            capacity: capacity,
            isControl: MessagePriority.clientResponse
        )
        sender = ValidatedMessageSender(
            metadataValidator: OrderedMetadataValidator(
                clusterID: clusterID,
                senderID: coordinatorID,
                protocolVersion: negotiatedProtocol.version,
                nextSequence: 2
            ),
            pipe: outbound,
            metadata: \InferPeer_V1_ClientSessionResponse.metadata,
            payloadIsValid: Self.isApplicationResponse
        )
    }

    func requests(bufferingLimit: Int) -> CallerRequestStream {
        inbound.claimedStream(bufferingLimit: bufferingLimit)
    }

    func send(_ response: InferPeer_V1_ClientSessionResponse) async throws {
        try await sender.send(response)
    }

    func close() async {
        await Task.yield()
        finish()
    }

    func finish() {
        inbound.finish()
        outbound.finish()
    }

    func fail(_ error: any Error) {
        inbound.fail(error)
        outbound.fail(error)
    }

    private static func isApplicationResponse(
        _ response: InferPeer_V1_ClientSessionResponse
    ) -> Bool {
        switch response.payload {
        case .requestAccepted, .requestStateChanged, .generationEvent, .cancellationUpdated,
            .requestFailed, .commandRejected:
            true
        default:
            false
        }
    }
}

final class CoordinatorWorkerSessionAdapter: CoordinatorWorkerSession, @unchecked Sendable {
    let authenticatedPeerID: PeerID
    let inbound: BoundedMessagePipe<InferPeer_V1_WorkerSessionRequest>
    let outbound: BoundedMessagePipe<InferPeer_V1_WorkerSessionResponse>
    private let sender: ValidatedMessageSender<InferPeer_V1_WorkerSessionResponse>

    init(
        authenticatedPeerID: PeerID,
        clusterID: ClusterID,
        coordinatorID: PeerID,
        negotiatedProtocol: InferPeer_V1_NegotiatedProtocol,
        capacity: Int
    ) {
        self.authenticatedPeerID = authenticatedPeerID
        inbound = BoundedMessagePipe(capacity: capacity, isControl: MessagePriority.workerRequest)
        outbound = BoundedMessagePipe(
            capacity: capacity,
            isControl: MessagePriority.workerResponse
        )
        sender = ValidatedMessageSender(
            metadataValidator: OrderedMetadataValidator(
                clusterID: clusterID,
                senderID: coordinatorID,
                protocolVersion: negotiatedProtocol.version,
                nextSequence: 2
            ),
            pipe: outbound,
            metadata: \InferPeer_V1_WorkerSessionResponse.metadata,
            payloadIsValid: Self.isApplicationResponse
        )
    }

    func requests(bufferingLimit: Int) -> WorkerRequestStream {
        inbound.claimedStream(bufferingLimit: bufferingLimit)
    }

    func send(_ response: InferPeer_V1_WorkerSessionResponse) async throws {
        try await sender.send(response)
    }

    func close() async {
        await Task.yield()
        finish()
    }

    func finish() {
        inbound.finish()
        outbound.finish()
    }

    func fail(_ error: any Error) {
        inbound.fail(error)
        outbound.fail(error)
    }

    private static func isApplicationResponse(
        _ response: InferPeer_V1_WorkerSessionResponse
    ) -> Bool {
        switch response.payload {
        case .assignment, .cancelAttempt, .leaseExtended:
            true
        default:
            false
        }
    }
}

final class SessionTerminator: @unchecked Sendable {
    private let lock = NSLock()
    let id = UUID()
    private var operation: (@Sendable () -> Void)?
    private var onTermination: (@Sendable (UUID) -> Void)?

    init(_ operation: @escaping @Sendable () -> Void) {
        self.operation = operation
    }

    func notifyOnTermination(_ callback: @escaping @Sendable (UUID) -> Void) {
        let terminatedID = lock.withLock { () -> UUID? in
            guard operation != nil else { return id }
            onTermination = callback
            return nil
        }
        if let terminatedID { callback(terminatedID) }
    }

    func terminate() {
        let actions = lock.withLock {
            let actions = (operation, onTermination)
            operation = nil
            onTermination = nil
            return actions
        }
        guard let operation = actions.0 else { return }
        operation()
        actions.1?(id)
    }
}

final class CallerSessionAdapter: CallerTransportSession, @unchecked Sendable {
    private let inbound: BoundedMessagePipe<InferPeer_V1_ClientSessionResponse>
    private let sender: ValidatedMessageSender<InferPeer_V1_ClientSessionRequest>
    private let terminator: SessionTerminator

    init(
        inbound: BoundedMessagePipe<InferPeer_V1_ClientSessionResponse>,
        outbound: BoundedMessagePipe<InferPeer_V1_ClientSessionRequest>,
        configuration: GRPCTransportConfiguration,
        negotiatedProtocol: InferPeer_V1_NegotiatedProtocol,
        terminator: SessionTerminator
    ) {
        self.inbound = inbound
        self.terminator = terminator
        sender = ValidatedMessageSender(
            metadataValidator: OrderedMetadataValidator(
                clusterID: configuration.clusterID,
                senderID: configuration.credentials.identity.peerID,
                protocolVersion: negotiatedProtocol.version,
                nextSequence: 2
            ),
            pipe: outbound,
            metadata: \InferPeer_V1_ClientSessionRequest.metadata,
            payloadIsValid: Self.isApplicationRequest
        )
    }

    func send(_ request: InferPeer_V1_ClientSessionRequest) async throws {
        try await sender.send(request)
    }

    func responses(bufferingLimit: Int) -> CallerResponseStream {
        inbound.claimedStream(bufferingLimit: bufferingLimit)
    }

    func close() async {
        await Task.yield()
        terminator.terminate()
    }

    private static func isApplicationRequest(
        _ request: InferPeer_V1_ClientSessionRequest
    ) -> Bool {
        switch request.payload {
        case .submit, .cancel, .resume, .acknowledgeEvents:
            true
        default:
            false
        }
    }
}

final class WorkerSessionAdapter: WorkerTransportSession, @unchecked Sendable {
    private let inbound: BoundedMessagePipe<InferPeer_V1_WorkerSessionResponse>
    private let sender: ValidatedMessageSender<InferPeer_V1_WorkerSessionRequest>
    private let terminator: SessionTerminator

    init(
        inbound: BoundedMessagePipe<InferPeer_V1_WorkerSessionResponse>,
        outbound: BoundedMessagePipe<InferPeer_V1_WorkerSessionRequest>,
        configuration: GRPCTransportConfiguration,
        negotiatedProtocol: InferPeer_V1_NegotiatedProtocol,
        terminator: SessionTerminator
    ) {
        self.inbound = inbound
        self.terminator = terminator
        sender = ValidatedMessageSender(
            metadataValidator: OrderedMetadataValidator(
                clusterID: configuration.clusterID,
                senderID: configuration.credentials.identity.peerID,
                protocolVersion: negotiatedProtocol.version,
                nextSequence: 2
            ),
            pipe: outbound,
            metadata: \InferPeer_V1_WorkerSessionRequest.metadata,
            payloadIsValid: Self.isApplicationRequest
        )
    }

    func send(_ request: InferPeer_V1_WorkerSessionRequest) async throws {
        try await sender.send(request)
    }

    func responses(bufferingLimit: Int) -> WorkerResponseStream {
        inbound.claimedStream(bufferingLimit: bufferingLimit)
    }

    func close() async {
        await Task.yield()
        terminator.terminate()
    }

    private static func isApplicationRequest(
        _ request: InferPeer_V1_WorkerSessionRequest
    ) -> Bool {
        switch request.payload {
        case .status, .attemptAccepted, .attemptRejected, .leaseRenewal, .generationEvent:
            true
        default:
            false
        }
    }
}
