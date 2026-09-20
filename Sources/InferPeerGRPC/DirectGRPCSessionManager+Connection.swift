import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol

extension DirectGRPCSessionManager {
    func session(for resourceID: ResourceID) async throws -> Session {
        if let session = sessions[resourceID] { return session }
        return try await reconnect(resourceID)
    }

    func reconnect(_ resourceID: ResourceID) async throws -> Session {
        var latestError: (any Error)?
        for attempt in 1...reconnectPolicy.maximumAttempts {
            do {
                return try await connectOnce(resourceID)
            } catch {
                latestError = error
                guard attempt < reconnectPolicy.maximumAttempts else { break }
                try await sleep(beforeAttempt: attempt + 1)
            }
        }
        throw publicError(latestError ?? InferPeerError(code: .connectionLost, isRetryable: true))
    }

    func connectOnce(_ resourceID: ResourceID) async throws -> Session {
        guard let credential = try await credentialStore.credential(for: resourceID) else {
            throw InferPeerError(code: .notPaired, isRetryable: false)
        }
        let session = try await connect(credential)
        sessions[resourceID] = session
        return session
    }

    func connect(_ credential: DirectResourceCredential) async throws -> Session {
        let connection = try await connectionFactory.open(
            endpoint: credential.endpoint,
            certificateFingerprint: credential.certificateFingerprint,
            credential: credential.credential
        )
        do {
            let hello = try await connection.hello(Self.helloRequest())
            guard hello.protocolMajor == 2,
                hello.resourceID == credential.resourceID.rawValue,
                !hello.incarnation.isEmpty
            else {
                throw InferPeerError(code: .protocolMismatch, isRetryable: false)
            }
            return Session(
                id: UUID(),
                credential: credential,
                connection: connection,
                incarnation: hello.incarnation
            )
        } catch {
            await connection.close()
            throw error
        }
    }

    func invalidate(_ resourceID: ResourceID, matching session: Session) {
        guard sessions[resourceID]?.id == session.id else { return }
        sessions[resourceID] = nil
        Task { await session.connection.close() }
    }

    func cancel(requestID: RequestID, resourceID: ResourceID) async {
        do {
            let session = try await session(for: resourceID)
            _ = try await session.connection.cancelRun(
                InferPeer_V2_CancelRunRequest.with { $0.requestID = requestID.rawValue }
            )
        } catch {
            // The reconciled state remains available through GetRun.
        }
    }
}

extension DirectGRPCSessionManager {
    func requireUsable(_ invitation: ResourcePairingInvitation) throws -> InvitationID {
        guard invitation.expiresAt > wallClock.now() else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "Pairing invitation expired",
                isRetryable: false
            )
        }
        guard let invitationID = invitation.invitationID else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "Invitation identity is missing",
                isRetryable: false
            )
        }
        return invitationID
    }

    func validatePairing(
        _ response: InferPeer_V2_PairResponse,
        expected resourceID: ResourceID
    ) throws -> ResourceSnapshot {
        try requireRequestID(response.resourceID, expected: resourceID)
        guard !response.credential.isEmpty, response.hasSnapshot else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
        let snapshot = try DirectWireMapper.resource(response.snapshot)
        guard snapshot.id == resourceID else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
        return snapshot
    }

    func makeCredential(
        _ response: InferPeer_V2_PairResponse,
        invitation: ResourcePairingInvitation
    ) throws -> DirectResourceCredential {
        try DirectResourceCredential(
            resourceID: invitation.resourceID,
            endpoint: invitation.endpoint,
            certificateFingerprint: invitation.certificateFingerprint,
            credential: response.credential
        )
    }

    func admission(
        from response: InferPeer_V2_StartRunResponse,
        requestID: RequestID
    ) throws -> Admission {
        try requireRequestID(response.requestID, expected: requestID)
        guard !response.incarnation.isEmpty else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
        let model = try DirectWireMapper.modelKey(response.admittedModel)
        return Admission(
            status: try DirectWireMapper.runStatus(
                response.state,
                model: model,
                queuePosition: response.hasQueuePosition ? response.queuePosition : nil
            ),
            incarnation: response.incarnation,
            terminalEvent: nil
        )
    }

    func admission(
        from response: InferPeer_V2_GetRunResponse,
        query: InferenceQuery,
        incarnation: String,
        requestID: RequestID
    ) throws -> Admission {
        try requireRequestID(response.requestID, expected: requestID)
        return Admission(
            status: try DirectWireMapper.runStatus(response.state, model: query.exactModel),
            incarnation: incarnation,
            terminalEvent: response.hasTerminalEvent ? response.terminalEvent : nil
        )
    }

    func requireRequestID(_ actual: String, expected: RequestID) throws {
        guard actual == expected.rawValue else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
    }

    func requireRequestID(_ actual: String, expected: ResourceID) throws {
        guard actual == expected.rawValue else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
    }

    func requireIncarnation(_ actual: String, expected: String) throws {
        guard actual == expected else {
            throw InferPeerError(code: .interrupted, isRetryable: false)
        }
    }

    func remaining(_ timeout: Duration, since startedAt: MonotonicInstant) throws -> Duration {
        let elapsed = clock.now().elapsed(since: startedAt)
        guard elapsed < timeout else {
            throw InferPeerError(code: .deadlineExceeded, isRetryable: false)
        }
        return timeout - elapsed
    }

    func requireRequestID(_ options: RunOptions) throws -> RequestID {
        guard let requestID = options.requestID else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "Request identity is required",
                isRetryable: false
            )
        }
        return requestID
    }

    func requireEncoded(
        _ query: InferenceQuery,
        options: RunOptions
    ) throws -> EncodedDirectRunSpecification {
        let encoded = try wireCodec.encode(query, options: options)
        guard !encoded.bytes.isEmpty else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "Run specification is empty",
                isRetryable: false
            )
        }
        return encoded
    }
}

extension DirectGRPCSessionManager {
    func sleep(beforeAttempt attempt: Int) async throws {
        let delay = delayProvider.delay(beforeAttempt: attempt)
        guard delay > .zero else { return }
        try await sleeper.sleep(for: delay)
    }

    func isConnectionLoss(_ error: any Error) -> Bool {
        guard let error = error as? InferPeerError else { return false }
        return error.code == .connectionLost || error.code == .resourceUnavailable
    }

    func publicError(_ error: any Error) -> InferPeerError {
        if let error = error as? InferPeerError { return error }
        if error is CancellationError {
            return InferPeerError(code: .cancelled, isRetryable: false)
        }
        return InferPeerError(code: .internal, isRetryable: false)
    }

    func startRequest(
        requestID: RequestID,
        encoded: EncodedDirectRunSpecification,
        remaining: Duration
    ) -> InferPeer_V2_StartRunRequest {
        InferPeer_V2_StartRunRequest.with {
            $0.requestID = requestID.rawValue
            $0.specificationBytes = encoded.bytes
            $0.remainingTimeoutMilliseconds = DirectWireMapper.durationMilliseconds(remaining)
            $0.attachmentReceipts = encoded.attachmentReceipts
        }
    }

    static func pairRequest(
        _ invitation: ResourcePairingInvitation,
        invitationID: InvitationID
    ) -> InferPeer_V2_PairRequest {
        InferPeer_V2_PairRequest.with {
            $0.protocolMajor = UInt32(invitation.protocolMajor)
            $0.invitationID = invitationID.rawValue
            $0.invitationSecret = invitation.secret
            $0.expectedResourceID = invitation.resourceID.rawValue
        }
    }

    static func helloRequest() -> InferPeer_V2_HelloRequest {
        InferPeer_V2_HelloRequest.with {
            $0.protocolMajor = 2
            $0.minimumMinor = 0
            $0.maximumMinor = 0
            $0.optionalFeatures = ["watch-run-ack", "same-process-replay"]
        }
    }
}

actor ModelPreparationObserver {
    private var readiness: ModelReadiness?
    private var failure: InferPeerError?

    func observe(_ update: InferPeer_V2_PrepareModelResponse) throws {
        if update.hasError { failure = DirectWireMapper.error(update.error) }
        readiness = try DirectWireMapper.readiness(update.readiness)
    }

    func requireReady() throws {
        if let failure { throw failure }
        guard readiness == .ready else {
            throw InferPeerError(code: .modelLoadFailed, isRetryable: true)
        }
    }
}

extension RunDisconnectPolicy {
    var grace: Duration {
        switch self {
        case .cancelAfter(let duration): duration
        }
    }
}

extension RunStatus {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .expired, .interrupted: true
        default: false
        }
    }
}

extension InferenceQuery {
    var exactModel: ModelKey? {
        guard case .exact(let model) = modelSelection else { return nil }
        return model
    }
}
