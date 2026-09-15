import Foundation
@testable import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import Testing

@Suite("Coordinator retention")
struct CoordinatorRetentionTests {
    @Test("Expired replay returns the retained successful terminal result")
    func returnsRetainedResult() async throws {
        let fixture = try CoordinatorStoreFixture()
        defer { fixture.remove() }
        let retained = try await seedPrunedCompletion(in: fixture.store)
        let caller = TestCoordinatorCallerSession(peerID: retained.callerID)
        let engine = CoordinatorEngine(
            configuration: try makeCoordinatorConfiguration(),
            store: fixture.store,
            scheduler: DefaultSchedulerPolicy(configuration: .standard)
        )
        try await engine.start(listener: TestCoordinatorListener())
        await engine.acceptCaller(caller)
        let rejected = Task { try await firstCommandRejection(caller.responses()) }

        caller.emit(resumeCommand(requestID: retained.requestID))
        let response = try await rejected.value

        #expect(response.commandRejected.error.code == .replayExpired)
        #expect(response.metadata.attemptID == retained.attemptID.rawValue)
        #expect(response.commandRejected.hasRetainedTerminalResult)
        #expect(
            try GenerationResult(wireValue: response.commandRejected.retainedTerminalResult)
                == retained.result
        )
        await engine.stop()
    }
}

private func resumeCommand(requestID: RequestID) -> InferPeer_V1_ClientSessionRequest {
    InferPeer_V1_ClientSessionRequest.with {
        $0.metadata.requestID = requestID.rawValue
        $0.resume.afterEventCursor = 0
    }
}
