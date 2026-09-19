import Foundation
import InferPeerProtocol
import SwiftProtobuf
import Testing

@Suite("InferPeer v2 direct protocol")
struct DirectV2ProtocolTests {
    @Test("StartRun preserves immutable bytes and the original remaining budget")
    func startRunRoundTrip() throws {
        let original = InferPeer_V2_StartRunRequest.with {
            $0.requestID = "request-1"
            $0.specificationBytes = Data([0x08, 0x01, 0x12, 0x02, 0xCA, 0xFE])
            $0.remainingTimeoutMilliseconds = 42_000
            $0.attachmentReceipts = ["receipt-1"]
        }

        let bytes: Data = try original.serializedBytes()
        let decoded = try InferPeer_V2_StartRunRequest(serializedBytes: bytes)

        #expect(decoded == original)
        #expect(decoded.specificationBytes == original.specificationBytes)
        #expect(decoded.remainingTimeoutMilliseconds == 42_000)
    }

    @Test("Resource deltas carry an explicit revision base")
    func resourceDeltaRevisionContract() throws {
        let delta = InferPeer_V2_ResourceDelta.with {
            $0.resourceID = "resource-1"
            $0.incarnation = "incarnation-1"
            $0.baseRevision = 7
            $0.revision = 8
        }

        let bytes: Data = try delta.serializedBytes()
        let decoded = try InferPeer_V2_ResourceDelta(serializedBytes: bytes)
        #expect(decoded.baseRevision == 7)
        #expect(decoded.revision == 8)
    }
}
