import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Core service contracts")
struct CoreContractTests {
    @Test("Validates persistence and peer identity boundary values")
    func validatesBoundaryValues() throws {
        #expect(
            throws: RequestPersistenceError.invalidDigestLength(actual: 31)
        ) {
            try RequestContentDigest(bytes: Data(repeating: 0, count: 31))
        }
        #expect(throws: PeerServiceValidationError.invalidEndpoint) {
            try PeerEndpoint(host: " ", port: 50051)
        }
        #expect(throws: PeerServiceValidationError.invalidCertificateFingerprint) {
            try CertificateFingerprint(bytes: Data(repeating: 0, count: 31))
        }
        #expect(throws: PeerServiceValidationError.negativeModelLoadDuration) {
            try WorkerModelSnapshot(
                model: makeModelReference(),
                isLoaded: false,
                measuredMemoryBytes: nil,
                estimatedLoadDuration: .milliseconds(-1)
            )
        }
    }

    @Test("Uses the abstract peer transport without a networking dependency")
    func usesMockPeerTransport() async throws {
        let recorder = TransportRecorder()
        let callerSession = MockCallerSession(recorder: recorder)
        let transport: any PeerTransport = MockPeerTransport(
            recorder: recorder,
            callerSession: callerSession
        )
        let endpoint = try PeerEndpoint(host: "coordinator.local", port: 50051)
        let request = InferPeer_V1_ClientSessionRequest()

        let session = try await transport.connectCaller(to: endpoint)
        try await session.send(request)
        await session.close()
        await transport.stop()

        #expect(await recorder.connectedEndpoint() == endpoint)
        #expect(await recorder.sentCallerRequestCount() == 1)
        #expect(await recorder.isCallerClosed())
        #expect(await recorder.isTransportStopped())
    }

    private func makeModelReference() throws -> ModelReference {
        let modelID = try #require(ModelID(rawValue: "model-1"))
        return try ModelReference(modelID: modelID, revision: "revision-1")
    }
}

private actor TransportRecorder {
    private var endpoint: PeerEndpoint?
    private var callerRequestCount = 0
    private var callerClosed = false
    private var transportStopped = false

    func recordConnection(to endpoint: PeerEndpoint) {
        self.endpoint = endpoint
    }

    func recordCallerRequest() {
        callerRequestCount += 1
    }

    func recordCallerClose() {
        callerClosed = true
    }

    func recordTransportStop() {
        transportStopped = true
    }

    func connectedEndpoint() -> PeerEndpoint? {
        endpoint
    }

    func sentCallerRequestCount() -> Int {
        callerRequestCount
    }

    func isCallerClosed() -> Bool {
        callerClosed
    }

    func isTransportStopped() -> Bool {
        transportStopped
    }
}

private struct MockCallerSession: CallerTransportSession {
    let recorder: TransportRecorder

    func send(_ request: InferPeer_V1_ClientSessionRequest) async throws {
        await recorder.recordCallerRequest()
    }

    func responses(bufferingLimit: Int) -> CallerResponseStream {
        CallerResponseStream { continuation in
            continuation.finish()
        }
    }

    func close() async {
        await recorder.recordCallerClose()
    }
}

private struct MockWorkerSession: WorkerTransportSession {
    // Protocol witnesses remain async because real transports may suspend.
    // swiftlint:disable:next async_without_await
    func send(_ request: InferPeer_V1_WorkerSessionRequest) async throws {}

    func responses(bufferingLimit: Int) -> WorkerResponseStream {
        WorkerResponseStream { continuation in
            continuation.finish()
        }
    }

    // swiftlint:disable:next async_without_await
    func close() async {}
}

private struct MockCoordinatorListener: CoordinatorTransportListener {
    func sessions(bufferingLimit: Int) -> InboundPeerSessionStream {
        InboundPeerSessionStream { continuation in
            continuation.finish()
        }
    }

    // Protocol witnesses remain async because real transports may suspend.
    // swiftlint:disable:next async_without_await
    func close() async {}
}

private actor MockPeerTransport: PeerTransport {
    let recorder: TransportRecorder
    let callerSession: MockCallerSession

    init(recorder: TransportRecorder, callerSession: MockCallerSession) {
        self.recorder = recorder
        self.callerSession = callerSession
    }

    // Protocol witnesses remain async because real transports may suspend.
    // swiftlint:disable:next async_without_await
    func listen(at endpoint: PeerEndpoint) async throws -> any CoordinatorTransportListener {
        MockCoordinatorListener()
    }

    func connectCaller(to endpoint: PeerEndpoint) async throws -> any CallerTransportSession {
        await recorder.recordConnection(to: endpoint)
        return callerSession
    }

    // swiftlint:disable:next async_without_await
    func connectWorker(to endpoint: PeerEndpoint) async throws -> any WorkerTransportSession {
        MockWorkerSession()
    }

    func stop() async {
        await recorder.recordTransportStop()
    }
}
