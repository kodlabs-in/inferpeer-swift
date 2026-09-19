import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol

/// Authenticated, fixed-destination v2 session owner with bounded same-endpoint recovery.
public actor DirectGRPCSessionManager: ResourceSessionManaging {
    struct Session: Sendable {
        let credential: DirectResourceCredential
        let connection: any AuthenticatedDirectResourceRPC
        let incarnation: String
    }

    struct Admission: Sendable {
        let status: RunStatus
        let incarnation: String
        let terminalEvent: InferPeer_V2_RunEvent?
    }

    struct WatchContext: Sendable {
        let requestID: RequestID
        let resourceID: ResourceID
        let expectedIncarnation: String
        let terminalEvent: InferPeer_V2_RunEvent?
        let grace: Duration
        let state: DirectRemoteRunState
        let attachmentReceipts: [String]
    }

    let credentialStore: any DirectResourceCredentialStoring
    let connectionFactory: any AuthenticatedDirectResourceRPCFactory
    let wireCodec: any DirectRunWireCoding
    let reconnectPolicy: DirectSessionReconnectPolicy
    let delayProvider: any DirectReconnectDelayProviding
    let sleeper: any DirectSessionSleeping
    let clock: any CoreClock
    let wallClock: any CoreWallClock
    let eventBufferLimit: Int
    var sessions: [ResourceID: Session] = [:]

    /// Creates a manager whose factory must enforce TLS pinning and credential metadata.
    public init(
        credentialStore: any DirectResourceCredentialStoring,
        connectionFactory: any AuthenticatedDirectResourceRPCFactory,
        wireCodec: any DirectRunWireCoding,
        reconnectPolicy: DirectSessionReconnectPolicy = .standard,
        delayProvider: any DirectReconnectDelayProviding = FixedDirectReconnectDelayProvider(
            delay: .milliseconds(100)
        ),
        sleeper: any DirectSessionSleeping = SystemDirectSessionSleeper(),
        clock: any CoreClock = SystemCoreClock(),
        wallClock: any CoreWallClock = SystemCoreWallClock(),
        eventBufferLimit: Int = 32
    ) {
        self.credentialStore = credentialStore
        self.connectionFactory = connectionFactory
        self.wireCodec = wireCodec
        self.reconnectPolicy = reconnectPolicy
        self.delayProvider = delayProvider
        self.sleeper = sleeper
        self.clock = clock
        self.wallClock = wallClock
        self.eventBufferLimit = max(1, eventBufferLimit)
    }

    /// Consumes an invitation only over its pinned endpoint and verifies the paired session.
    public func pair(_ invitation: ResourcePairingInvitation) async throws -> ResourceSnapshot {
        let invitationID = try requireUsable(invitation)
        let pairingConnection = try await connectionFactory.open(
            endpoint: invitation.endpoint,
            certificateFingerprint: invitation.certificateFingerprint,
            credential: nil
        )
        let response: InferPeer_V2_PairResponse
        do {
            response = try await pairingConnection.pair(
                Self.pairRequest(invitation, invitationID: invitationID)
            )
        } catch {
            await pairingConnection.close()
            throw error
        }
        await pairingConnection.close()
        let snapshot = try validatePairing(response, expected: invitation.resourceID)
        let credential = try makeCredential(response, invitation: invitation)
        try await credentialStore.save(credential)
        sessions[invitation.resourceID] = try await connect(credential)
        return snapshot
    }

    /// Reopens every durable pairing and fetches a fresh authenticated resource snapshot.
    public func reconnectPairedResources() async -> [ResourceSnapshot] {
        guard let resourceIDs = try? await credentialStore.resourceIDs() else { return [] }
        var snapshots: [ResourceSnapshot] = []
        for resourceID in resourceIDs {
            do {
                let session = try await session(for: resourceID)
                if let snapshot = try await session.connection.resourceSnapshot(knownRevision: 0),
                    snapshot.id == resourceID
                {
                    snapshots.append(snapshot)
                }
            } catch {
                sessions[resourceID] = nil
            }
        }
        return snapshots
    }

    /// Closes one exact resource session without changing its pairing.
    public func disconnect(_ resourceID: ResourceID) async {
        guard let session = sessions.removeValue(forKey: resourceID) else { return }
        await session.connection.close()
    }

    /// Closes and removes one exact resource pairing.
    public func forget(_ resourceID: ResourceID) async throws {
        await disconnect(resourceID)
        try await credentialStore.removeCredential(for: resourceID)
    }

    /// Prepares one exact model on one exact authenticated resource.
    public func prepareModel(_ model: ModelKey, on resourceID: ResourceID) async throws {
        let session = try await session(for: resourceID)
        let observer = ModelPreparationObserver()
        try await session.connection.prepareModel(
            InferPeer_V2_PrepareModelRequest.with {
                $0.model = DirectWireMapper.wireModelKey(model)
                $0.remainingTimeoutMilliseconds = 120_000
            }
        ) { update in
            try await observer.observe(update)
        }
        try await observer.requireReady()
    }

    /// Starts or reconciles one immutable request only on its selected resource.
    public func run(
        _ query: InferenceQuery,
        resourceID: ResourceID,
        options: RunOptions
    ) async throws -> RemoteRunExecution {
        let requestID = try requireRequestID(options)
        let preparedQuery = try await prepareAssets(in: query, resourceID: resourceID)
        let encoded = try requireEncoded(preparedQuery, options: options)
        let admission = try await admit(
            requestID: requestID,
            query: preparedQuery,
            encoded: encoded,
            resourceID: resourceID,
            options: options
        )
        return makeExecution(
            requestID: requestID,
            resourceID: resourceID,
            admission: admission,
            disconnectPolicy: options.disconnectPolicy,
            attachmentReceipts: encoded.attachmentReceipts
        )
    }

    /// Closes every active authenticated channel.
    public func stop() async {
        let active = Array(sessions.values)
        sessions.removeAll()
        for session in active { await session.connection.close() }
    }
}
