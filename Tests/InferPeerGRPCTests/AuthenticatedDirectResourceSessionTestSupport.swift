import Foundation
import InferPeerCore
import InferPeerGRPC
import InferPeerInference
import InferPeerProtocol

actor MemoryDirectCredentialStore: DirectResourceCredentialStoring {
    private var credentials: [ResourceID: DirectResourceCredential] = [:]

    func credential(for resourceID: ResourceID) -> DirectResourceCredential? {
        credentials[resourceID]
    }

    func save(_ credential: DirectResourceCredential) {
        credentials[credential.resourceID] = credential
    }

    func removeCredential(for resourceID: ResourceID) {
        credentials[resourceID] = nil
    }

    func resourceIDs() -> [ResourceID] {
        credentials.keys.sorted { $0.rawValue < $1.rawValue }
    }
}

struct FakeConnectionOpening: Sendable {
    let endpoint: PeerEndpoint
    let certificateFingerprint: CertificateFingerprint
    let credential: Data?
}

actor FakeDirectRPCConnectionFactory: AuthenticatedDirectResourceRPCFactory {
    private var connections: [any AuthenticatedDirectResourceRPC] = []
    private var openings: [FakeConnectionOpening] = []

    func enqueue(_ connection: any AuthenticatedDirectResourceRPC) {
        connections.append(connection)
    }

    func open(
        endpoint: PeerEndpoint,
        certificateFingerprint: CertificateFingerprint,
        credential: Data?
    ) throws -> any AuthenticatedDirectResourceRPC {
        openings.append(
            FakeConnectionOpening(
                endpoint: endpoint,
                certificateFingerprint: certificateFingerprint,
                credential: credential
            )
        )
        guard !connections.isEmpty else {
            throw InferPeerError(code: .connectionLost, isRetryable: true)
        }
        return connections.removeFirst()
    }

    func recordedOpenings() -> [FakeConnectionOpening] { openings }
}

actor FakeDirectRPCConnection: AuthenticatedDirectResourceRPC {
    private let pairResponse: InferPeer_V2_PairResponse?
    private let helloResponse: InferPeer_V2_HelloResponse?
    private let startResponse: InferPeer_V2_StartRunResponse?
    private let startError: InferPeerError?
    private let getRunResponse: InferPeer_V2_GetRunResponse?
    private let watchEvents: [InferPeer_V2_RunEvent]
    private let watchError: InferPeerError?
    private var starts: [InferPeer_V2_StartRunRequest] = []
    private var getRuns: [String] = []
    private var cursors: [UInt64] = []
    private var acknowledgementsValue: [UInt64] = []

    init(
        pairResponse: InferPeer_V2_PairResponse? = nil,
        helloResponse: InferPeer_V2_HelloResponse? = nil,
        startResponse: InferPeer_V2_StartRunResponse? = nil,
        startError: InferPeerError? = nil,
        getRunResponse: InferPeer_V2_GetRunResponse? = nil,
        watchEvents: [InferPeer_V2_RunEvent] = [],
        watchError: InferPeerError? = nil
    ) {
        self.pairResponse = pairResponse
        self.helloResponse = helloResponse
        self.startResponse = startResponse
        self.startError = startError
        self.getRunResponse = getRunResponse
        self.watchEvents = watchEvents
        self.watchError = watchError
    }

    func pair(_: InferPeer_V2_PairRequest) throws -> InferPeer_V2_PairResponse {
        guard let pairResponse else { throw InferPeerError(code: .internal, isRetryable: false) }
        return pairResponse
    }

    func hello(_: InferPeer_V2_HelloRequest) throws -> InferPeer_V2_HelloResponse {
        guard let helloResponse else {
            throw InferPeerError(code: .connectionLost, isRetryable: true)
        }
        return helloResponse
    }

    func prepareModel(
        _: InferPeer_V2_PrepareModelRequest,
        onUpdate: @escaping @Sendable (InferPeer_V2_PrepareModelResponse) async throws -> Void
    ) async throws {
        try await onUpdate(
            InferPeer_V2_PrepareModelResponse.with { $0.readiness = .ready }
        )
    }

    func startRun(
        _ request: InferPeer_V2_StartRunRequest
    ) throws -> InferPeer_V2_StartRunResponse {
        starts.append(request)
        if let startError { throw startError }
        guard let startResponse else {
            throw InferPeerError(code: .internal, isRetryable: false)
        }
        return startResponse
    }

    func getRun(_ request: InferPeer_V2_GetRunRequest) throws -> InferPeer_V2_GetRunResponse {
        getRuns.append(request.requestID)
        guard let getRunResponse else {
            throw InferPeerError(code: .outcomeUnknown, isRetryable: true)
        }
        return getRunResponse
    }

    func watchRun(
        requestID _: RequestID,
        resumeAfterSequence: UInt64,
        onEvent: @escaping @Sendable (InferPeer_V2_RunEvent) async throws -> UInt64
    ) async throws {
        cursors.append(resumeAfterSequence)
        for event in watchEvents {
            acknowledgementsValue.append(try await onEvent(event))
        }
        if let watchError { throw watchError }
    }

    func cancelRun(_: InferPeer_V2_CancelRunRequest) -> InferPeer_V2_CancelRunResponse {
        InferPeer_V2_CancelRunResponse.with { $0.state = .cancelRequested }
    }

    func close() {}

    func startRequests() -> [InferPeer_V2_StartRunRequest] { starts }
    func getRunRequests() -> [String] { getRuns }
    func watchCursors() -> [UInt64] { cursors }
    func acknowledgements() -> [UInt64] { acknowledgementsValue }
}

actor RecordingDirectSessionSleeper: DirectSessionSleeping {
    private let clock: SessionTestClock
    private var delays: [Duration] = []

    init(clock: SessionTestClock) {
        self.clock = clock
    }

    func sleep(for duration: Duration) {
        delays.append(duration)
        clock.advance(by: duration)
    }

    func recordedDelays() -> [Duration] { delays }
}

final class SessionTestClock: CoreClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = MonotonicInstant(nanoseconds: 1_000_000_000)

    func now() -> MonotonicInstant {
        lock.withLock { instant }
    }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

struct FixedSessionWallClock: CoreWallClock {
    let date: Date

    func now() -> Date { date }
}

struct FixtureDirectRunWireCodec: DirectRunWireCoding {
    let model: ModelKey

    func encode(
        _: InferenceQuery,
        options _: RunOptions
    ) -> EncodedDirectRunSpecification {
        EncodedDirectRunSpecification(bytes: Data("fixed-specification".utf8))
    }

    func decode(_ event: InferPeer_V2_RunEvent) throws -> RunEvent {
        guard let text = String(data: event.boundedPayload, encoding: .utf8) else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
        switch event.eventType {
        case "text":
            return .textDelta(text)
        case "completed":
            return .completed(
                RunResult(
                    text: text,
                    model: model,
                    finishReason: .stop,
                    usage: TokenUsage(promptTokens: 1, outputTokens: 1)
                )
            )
        default:
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
    }
}
