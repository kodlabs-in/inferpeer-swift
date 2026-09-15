import Crypto
import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import SwiftProtobuf

extension CallerRequestService {
    func sendSubmit(_ submission: RequestSubmission) async throws {
        let metadata = try makeMetadata(requestID: submission.requestID)
        let request = InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = metadata
            $0.submit.request = submission.request.wireValue
            $0.submit.immutableInputSha256 = submission.contentDigest.bytes
        }
        try await enqueue(request)
    }

    func sendResume(requestID: RequestID, after cursor: UInt64?) async throws {
        let metadata = try makeMetadata(requestID: requestID)
        let request = InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = metadata
            $0.resume.afterEventCursor = cursor ?? 0
        }
        try await enqueue(request)
    }

    func sendAcknowledgement(requestID: RequestID, through cursor: UInt64) async throws {
        let metadata = try makeMetadata(requestID: requestID)
        let request = InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = metadata
            $0.acknowledgeEvents.throughEventCursor = cursor
        }
        try await enqueue(request)
    }

    func sendCancellation(requestID: RequestID) async throws {
        let metadata = try makeMetadata(requestID: requestID)
        let request = InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = metadata
            $0.cancel = InferPeer_V1_CancelCommand()
        }
        try await enqueue(request)
    }

    func enqueue(_ request: InferPeer_V1_ClientSessionRequest) async throws {
        let previous = sendTail
        let session = session
        let task = Task {
            if let previous { try await previous.value }
            try await session.send(request)
        }
        sendTail = task
        try await task.value
    }

    func makeMetadata(requestID: RequestID) throws -> InferPeer_V1_MessageMetadata {
        guard nextSequence < .max else { throw InferPeerNodeError.sequenceExhausted }
        let sequence = nextSequence
        nextSequence += 1
        return InferPeer_V1_MessageMetadata.with {
            $0.protocolVersion = InferPeerProtocolVersion.current
            $0.clusterID = clusterID.rawValue
            $0.authenticatedSenderID = callerID.rawValue
            $0.messageID = UUID().uuidString.lowercased()
            $0.requestID = requestID.rawValue
            $0.sequence = sequence
        }
    }

    func removeSubscription(requestID: RequestID, subscriptionID: UUID) {
        guard subscriptions[requestID]?.id == subscriptionID else { return }
        subscriptions[requestID] = nil
    }

    func prepareLifecycleForReplay(_ requestID: RequestID) throws {
        guard lifecycles[requestID] == nil else { return }
        var lifecycle = CallerRequestLifecycle(requestID: requestID)
        try lifecycle.markSubmitted()
        lifecycles[requestID] = lifecycle
    }

    func failSubscriptions(with error: any Error) {
        subscriptions.values.forEach { $0.continuation.finish(throwing: error) }
        subscriptions.removeAll()
    }

    static func makeRequestID() throws -> RequestID {
        guard let requestID = RequestID(rawValue: UUID().uuidString.lowercased()) else {
            throw InferPeerNodeError.invalidCoordinatorResponse
        }
        return requestID
    }

    static func submission(
        requestID: RequestID,
        callerID: PeerID,
        request: TextGenerationRequest
    ) throws -> RequestSubmission {
        var options = BinaryEncodingOptions()
        options.useDeterministicOrdering = true
        let bytes = try request.wireValue.serializedData(options: options)
        guard InferPeerProtocolLimits.permits(request.wireValue) else {
            throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        let digest = try RequestContentDigest(bytes: Data(SHA256.hash(data: bytes)))
        return RequestSubmission(
            requestID: requestID,
            callerID: callerID,
            request: request,
            contentDigest: digest
        )
    }
}
