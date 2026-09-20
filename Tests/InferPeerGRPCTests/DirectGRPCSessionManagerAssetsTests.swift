import InferPeerCore
@testable import InferPeerGRPC
import InferPeerProtocol
import Testing

@Suite("Direct session asset responses")
struct DirectGRPCSessionManagerAssetsTests {
    @Test("Duplicate upload ticket identities are rejected as a protocol mismatch")
    func rejectsDuplicateUploadTicketIdentities() {
        let response = InferPeer_V2_PrepareAssetsResponse.with {
            $0.tickets = [
                ticket(id: "image-one", value: "ticket-one"),
                ticket(id: "image-one", value: "ticket-two"),
            ]
        }

        do {
            _ = try DirectGRPCSessionManager.validatedUploadTickets(
                response,
                expectedClientIDs: ["image-one"]
            )
            Issue.record("Expected duplicate ticket identities to be rejected")
        } catch let error as InferPeerError {
            #expect(error.code == .protocolMismatch)
        } catch {
            Issue.record("Expected InferPeerError, received \(error)")
        }
    }

    @Test("Missing and unexpected upload tickets are rejected")
    func rejectsMismatchedUploadTicketSet() {
        let response = InferPeer_V2_PrepareAssetsResponse.with {
            $0.tickets = [ticket(id: "unexpected", value: "ticket-one")]
        }

        #expect(throws: InferPeerError.self) {
            _ = try DirectGRPCSessionManager.validatedUploadTickets(
                response,
                expectedClientIDs: ["image-one"]
            )
        }
    }
}

private func ticket(id: String, value: String) -> InferPeer_V2_UploadTicket {
    InferPeer_V2_UploadTicket.with {
        $0.clientAssetID = id
        $0.ticket = value
    }
}
