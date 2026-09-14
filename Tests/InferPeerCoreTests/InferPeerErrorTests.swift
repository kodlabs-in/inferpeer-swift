import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Core errors")
struct InferPeerErrorTests {
    @Test("Preserves unknown future protocol error codes")
    func preservesUnknownCode() throws {
        let unknownCode = try #require(InferPeer_V1_ErrorCode(rawValue: 999))
        let wireValue = InferPeer_V1_ProtocolError.with {
            $0.code = unknownCode
            $0.message = "future failure"
            $0.retryable = true
        }

        let error = InferPeerError(wireValue: wireValue)

        #expect(error.code == .unrecognized(999))
        #expect(error.isRetryable)
        #expect(error.wireValue.code.rawValue == 999)
    }

    @Test("Maps backend failures to stable public errors")
    func mapsBackendFailures() throws {
        let modelID = try #require(ModelID(rawValue: "model-1"))
        let model = try ModelReference(modelID: modelID, revision: "revision-1")

        #expect(
            InferPeerError(backendError: .contextTooLarge(limit: 4_096)).code == .contextTooLarge)
        #expect(InferPeerError(backendError: .modelUnavailable(model)).code == .modelUnavailable)
        #expect(InferPeerError(backendError: .cancelled).code == .cancelled)
        #expect(InferPeerError(backendError: .executionFailed(retryable: true)).isRetryable)
    }
}
