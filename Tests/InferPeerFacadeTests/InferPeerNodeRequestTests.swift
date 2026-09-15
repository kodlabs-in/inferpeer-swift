import Foundation
@testable import InferPeer
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import InferPeerTelemetry
import Testing

extension InferPeerNodeTests {
    @Test("Joining restores and resends durable caller outbox entries")
    func restoresPendingOutbox() async throws {
        let requestID = try #require(RequestID(rawValue: "request-restored"))
        let callerID = try #require(PeerID(rawValue: "local"))
        let submission = RequestSubmission(
            requestID: requestID,
            callerID: callerID,
            request: try makeRequest(),
            contentDigest: try RequestContentDigest(bytes: Data(repeating: 0x44, count: 32))
        )
        let outbox = FakeCallerOutbox(
            pendingRequests: [StoredOutboxRequest(submission: submission, enqueuedAt: Date())]
        )
        let transport = FakeTransport()
        let node = try makeNode(
            roles: [.caller],
            transport: transport,
            optional: .init(callerOutbox: outbox)
        )
        try await node.start()

        _ = try await node.join(makeInvitation())

        let sent = transport.callerSession.sentRequests
        #expect(sent.count == 1)
        let recovered = try #require(sent.first)
        #expect(recovered.metadata.requestID == requestID.rawValue)
        if case .submit = recovered.payload {
            // Expected recovered submission.
        } else {
            Issue.record("Expected a recovered submission")
        }
        #expect(try await node.requestStatus(requestID).phase == .awaitingAcceptance)
        await node.stop()
    }

    @Test("Request events replay with attempt boundaries and explicit acknowledgement")
    func replaysAndAcknowledgesEvents() async throws {
        let outbox = FakeCallerOutbox()
        let transport = FakeTransport()
        let node = try makeNode(
            roles: [.caller],
            transport: transport,
            optional: .init(callerOutbox: outbox)
        )
        try await node.start()
        _ = try await node.join(makeInvitation())
        let requestID = try #require(RequestID(rawValue: "request-1"))
        _ = try await node.submit(makeRequest(), requestID: requestID)
        let events = try await node.events(requestID: requestID, after: nil)
        let task = Task { try await #require(events.first(where: { _ in true })) }
        await Task.yield()

        transport.callerSession.emit(acceptedResponse(requestID: requestID, cursor: 1))
        let event = try await task.value
        try await node.acknowledge(requestID: requestID, through: event.cursor)

        #expect(event.requestID == requestID)
        #expect(event.cursor == 1)
        #expect(event.payload == .accepted(.queued))
        #expect(await outbox.removedRequestIDs == [requestID])
        let status = try await node.requestStatus(requestID)
        #expect(status.phase == .accepted(.queued))
        #expect(status.acknowledgedEventCursor == 1)
    }

    @Test("A restarted caller resumes from its durable acknowledgement")
    func resumesAfterRestart() async throws {
        let outbox = FakeCallerOutbox()
        let firstTransport = FakeTransport()
        let firstNode = try makeNode(
            roles: [.caller],
            transport: firstTransport,
            optional: .init(callerOutbox: outbox)
        )
        try await firstNode.start()
        _ = try await firstNode.join(makeInvitation())
        let requestID = try #require(RequestID(rawValue: "request-restart"))
        _ = try await firstNode.submit(makeRequest(), requestID: requestID)
        let firstEvents = try await firstNode.events(requestID: requestID)
        let firstEvent = Task { try await #require(firstEvents.first(where: { _ in true })) }
        firstTransport.callerSession.emit(acceptedResponse(requestID: requestID, cursor: 1))
        _ = try await firstEvent.value
        try await firstNode.acknowledge(requestID: requestID, through: 1)
        await firstNode.stop()

        let secondTransport = FakeTransport()
        let secondNode = try makeNode(
            roles: [.caller],
            transport: secondTransport,
            optional: .init(callerOutbox: outbox)
        )
        try await secondNode.start()
        _ = try await secondNode.join(makeInvitation())
        let resumedEvents = try await secondNode.events(requestID: requestID)
        let resumedEvent = Task { try await #require(resumedEvents.first(where: { _ in true })) }
        let resume = try #require(secondTransport.callerSession.sentRequests.last)

        #expect(resume.resume.afterEventCursor == 1)
        secondTransport.callerSession.emit(
            stateResponse(requestID: requestID, cursor: 2, state: .running)
        )
        let event = try await resumedEvent.value
        #expect(event.cursor == 2)
        #expect(try await secondNode.requestStatus(requestID).phase == .accepted(.running))
        await secondNode.stop()
    }

    @Test("A typed command rejection keeps undurable work in the caller outbox")
    func preservesRejectedSubmission() async throws {
        let outbox = FakeCallerOutbox()
        let transport = FakeTransport()
        let node = try makeNode(
            roles: [.caller],
            transport: transport,
            optional: .init(callerOutbox: outbox)
        )
        try await node.start()
        _ = try await node.join(makeInvitation())
        let requestID = try #require(RequestID(rawValue: "request-rejected"))
        _ = try await node.submit(makeRequest(), requestID: requestID)
        let events = try await node.events(requestID: requestID)
        let failure = Task {
            for try await _ in events {}
        }

        transport.callerSession.emit(
            InferPeer_V1_ClientSessionResponse.with {
                $0.metadata.requestID = requestID.rawValue
                $0.commandRejected.error =
                    InferPeerError(
                        code: .resourceExhausted,
                        isRetryable: true
                    ).wireValue
            })

        await #expect(throws: InferPeerCommandRejection.self) {
            try await failure.value
        }
        #expect(try await node.requestStatus(requestID).phase == .pendingOutbox)
        #expect(await outbox.removedRequestIDs.isEmpty)
        await node.stop()
    }

    @Test("Role-specific operations fail before touching adapters")
    func enforcesRoles() async throws {
        let node = try makeNode(roles: [.caller])
        try await node.start()

        await #expect(throws: InferPeerNodeError.roleNotEnabled(.worker)) {
            try await node.setParticipation(.available)
        }
    }

    @Test("Configuration requires a coordinator endpoint")
    func requiresCoordinatorEndpoint() {
        #expect(throws: InferPeerNodeError.coordinatorEndpointRequired) {
            _ = try InferPeerNodeConfiguration(roles: [.coordinator])
        }
    }

}
