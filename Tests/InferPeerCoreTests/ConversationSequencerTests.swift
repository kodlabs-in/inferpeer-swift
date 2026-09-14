import InferPeerCore
import InferPeerProtocol
import Testing

@Suite("Conversation sequencing")
struct ConversationSequencerTests {
    @Test("Runs one revision at a time in increasing order")
    func sequencesConversationRevisions() throws {
        var sequencer = ConversationSequencer()
        let key = try makeKey(caller: "caller-1")
        let first = try makeRequestID("request-1")
        let second = try makeRequestID("request-2")

        try sequencer.enqueue(requestID: first, conversation: key, revision: 1)
        try sequencer.enqueue(requestID: second, conversation: key, revision: 2)

        let firstTurn = sequencer.beginNext(in: key)
        let blockedTurn = sequencer.beginNext(in: key)
        #expect(firstTurn == ConversationTurn(requestID: first, revision: 1))
        #expect(blockedTurn == nil)
        try sequencer.finish(requestID: first, in: key)
        let secondTurn = sequencer.beginNext(in: key)
        #expect(secondTurn == ConversationTurn(requestID: second, revision: 2))
    }

    @Test("Isolates the same conversation identifier between callers")
    func isolatesCallerContexts() throws {
        var sequencer = ConversationSequencer()
        let firstKey = try makeKey(caller: "caller-1")
        let secondKey = try makeKey(caller: "caller-2")
        let firstRequest = try makeRequestID("request-1")
        let secondRequest = try makeRequestID("request-2")

        try sequencer.enqueue(requestID: firstRequest, conversation: firstKey, revision: 1)
        try sequencer.enqueue(requestID: secondRequest, conversation: secondKey, revision: 1)

        let firstTurn = sequencer.beginNext(in: firstKey)
        let secondTurn = sequencer.beginNext(in: secondKey)
        #expect(firstTurn?.requestID == firstRequest)
        #expect(secondTurn?.requestID == secondRequest)
    }

    @Test("Rejects duplicate or regressing revisions")
    func rejectsInvalidRevisionOrder() throws {
        var sequencer = ConversationSequencer()
        let key = try makeKey(caller: "caller-1")

        try sequencer.enqueue(
            requestID: makeRequestID("request-1"),
            conversation: key,
            revision: 2
        )

        #expect(throws: ConversationSequenceError.revisionNotIncreasing) {
            try sequencer.enqueue(
                requestID: try makeRequestID("request-2"),
                conversation: key,
                revision: 2
            )
        }
        #expect(throws: ConversationSequenceError.duplicateRequest) {
            try sequencer.enqueue(
                requestID: try makeRequestID("request-1"),
                conversation: key,
                revision: 3
            )
        }
    }

    private func makeKey(caller: String) throws -> ConversationKey {
        let callerID = try #require(PeerID(rawValue: caller))
        let conversationID = try #require(ConversationID(rawValue: "conversation-1"))
        return ConversationKey(callerID: callerID, conversationID: conversationID)
    }

    private func makeRequestID(_ value: String) throws -> RequestID {
        try #require(RequestID(rawValue: value))
    }
}
