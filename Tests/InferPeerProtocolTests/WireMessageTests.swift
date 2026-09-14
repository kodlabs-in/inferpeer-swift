import Foundation
import InferPeerProtocol
import SwiftProtobuf
import Testing

@Suite("Protocol wire messages")
struct WireMessageTests {
    @Test("Round-trips a complete submit command")
    func submitCommandRoundTrip() throws {
        let command = makeSubmitCommand()

        let encoded = try command.serializedData()
        let decoded = try InferPeer_V1_ClientSessionRequest(serializedBytes: encoded)

        #expect(decoded == command)
        #expect(decoded.metadata.requestID == "request-1")
        #expect(decoded.submit.request.messages.map(\.role) == [.system, .user])
        #expect(decoded.submit.request.allowedWorkerIds == ["peer-worker-1"])
    }

    @Test("Preserves unknown enum values")
    func unknownErrorCodeRoundTrip() throws {
        let unknown = try #require(InferPeer_V1_ErrorCode(rawValue: 999))
        let error = InferPeer_V1_ProtocolError.with {
            $0.code = unknown
            $0.message = "future error"
        }

        let encoded = try error.serializedData()
        let decoded = try InferPeer_V1_ProtocolError(serializedBytes: encoded)

        #expect(decoded.code.rawValue == 999)
    }

    @Test("Preserves fields added by a future protocol revision")
    func unknownFieldRoundTrip() throws {
        let unknownField = Data([0x98, 0x06, 0x07])
        var encoded = try InferPeer_V1_ProtocolError.with {
            $0.code = .internal
        }.serializedData()
        encoded.append(unknownField)

        let decoded = try InferPeer_V1_ProtocolError(serializedBytes: encoded)
        let reencoded = try decoded.serializedData()

        #expect(reencoded.suffix(unknownField.count) == unknownField)
    }

    @Test("Rejects a truncated wire message")
    func rejectsMalformedWireBytes() {
        let truncatedLengthDelimitedField = Data([0x0A, 0x05, 0x01])

        #expect(throws: (any Error).self) {
            try InferPeer_V1_ClientSessionRequest(serializedBytes: truncatedLengthDelimitedField)
        }
    }

    @Test("A command envelope contains only its latest oneof payload")
    func commandOneOfSemantics() {
        var command = makeSubmitCommand()
        #expect(command.payload == .submit(command.submit))

        command.cancel = InferPeer_V1_CancelCommand.with {
            $0.reason = "user requested"
        }

        #expect(command.payload == .cancel(command.cancel))
    }

    @Test("Current support negotiates its declared protocol version")
    func currentVersionIsSelfCompatible() throws {
        let negotiated = try ProtocolNegotiator.negotiate(
            local: InferPeerProtocolVersion.supported,
            remote: InferPeerProtocolVersion.supported
        )

        #expect(negotiated.version == InferPeerProtocolVersion.current)
        #expect(negotiated.capabilities == InferPeerProtocolVersion.supported.capabilities)
    }

    private func makeSubmitCommand() -> InferPeer_V1_ClientSessionRequest {
        InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = makeMetadata()
            $0.submit = InferPeer_V1_SubmitCommand.with {
                $0.immutableInputSha256 = Data(repeating: 0xA5, count: 32)
                $0.request = makeTextRequest()
            }
        }
    }

    private func makeMetadata() -> InferPeer_V1_MessageMetadata {
        InferPeer_V1_MessageMetadata.with {
            $0.protocolVersion = InferPeerProtocolVersion.current
            $0.clusterID = "cluster-1"
            $0.authenticatedSenderID = "peer-caller-1"
            $0.messageID = "message-1"
            $0.requestID = "request-1"
            $0.sequence = 1
        }
    }

    private func makeTextRequest() -> InferPeer_V1_TextRequest {
        InferPeer_V1_TextRequest.with {
            $0.conversationID = "conversation-1"
            $0.contextRevision = 2
            $0.messages = [
                .with {
                    $0.role = .system
                    $0.text = "Answer concisely."
                },
                .with {
                    $0.role = .user
                    $0.text = "Hello"
                },
            ]
            $0.modelRequirement.exactModel = .with {
                $0.modelID = "model-1"
                $0.revision = "revision-1"
            }
            $0.maximumOutputTokens = 128
            $0.sampling.temperature = 0.2
            $0.allowedWorkerIds = ["peer-worker-1"]
        }
    }
}
