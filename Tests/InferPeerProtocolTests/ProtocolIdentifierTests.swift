import Foundation
import InferPeerProtocol
import Testing

@Suite("Protocol identifiers")
struct ProtocolIdentifierTests {
    @Test("Accepts a printable ASCII identifier")
    func acceptsValidIdentifier() throws {
        let identifier = try #require(RequestID(rawValue: "request-018f.test:1"))

        #expect(identifier.rawValue == "request-018f.test:1")
        #expect(identifier.description == identifier.rawValue)
    }

    @Test("Rejects invalid wire representations")
    func rejectsInvalidIdentifiers() {
        #expect(RequestID(rawValue: "") == nil)
        #expect(RequestID(rawValue: "contains space") == nil)
        #expect(RequestID(rawValue: "contains\nnewline") == nil)
        #expect(RequestID(rawValue: "café") == nil)
        #expect(RequestID(rawValue: String(repeating: "a", count: 129)) == nil)
    }

    @Test("Encodes as a single JSON string")
    func codableRoundTrip() throws {
        let identifier = try #require(PeerID(rawValue: "peer-1"))
        let encoded = try JSONEncoder().encode(identifier)
        let decoded = try JSONDecoder().decode(PeerID.self, from: encoded)
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(json == "\"peer-1\"")
        #expect(decoded == identifier)
    }

    @Test("Rejects invalid decoded values")
    func rejectsInvalidDecodedIdentifier() {
        let encoded = Data("\"contains space\"".utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RequestID.self, from: encoded)
        }
    }
}
