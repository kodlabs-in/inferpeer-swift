import Foundation
@testable import InferPeerGRPC
import InferPeerCore
import Testing

@Suite("gRPC configuration")
struct GRPCConfigurationTests {
    @Test("network policy permits only an explicit numeric endpoint")
    func networkPolicyAllowlist() throws {
        let allowed = try PeerEndpoint(host: "127.0.0.1", port: 50_051)
        let blocked = try PeerEndpoint(host: "127.0.0.1", port: 50_052)
        let policy = try GRPCNetworkPolicy(interfaceName: "lo0", allowedEndpoints: [allowed])

        #expect(throws: Never.self) { try policy.validate(allowed) }
        #expect(throws: InferPeerGRPCError.endpointNotAllowed) {
            try policy.validate(blocked)
        }
    }

    @Test("network policy rejects wildcard and DNS endpoints")
    func networkPolicyRejectsUnsafeHosts() throws {
        let wildcard = try PeerEndpoint(host: "0.0.0.0", port: 50_051)
        let dns = try PeerEndpoint(host: "coordinator.local", port: 50_051)

        #expect(throws: InferPeerGRPCError.invalidConfiguration) {
            try GRPCNetworkPolicy(interfaceName: "lo0", allowedEndpoints: [wildcard])
        }
        #expect(throws: InferPeerGRPCError.invalidConfiguration) {
            try GRPCNetworkPolicy(interfaceName: "lo0", allowedEndpoints: [dns])
        }
    }

    @Test("bounded pipe terminates instead of silently dropping")
    func boundedPipeFailsOnOverflow() throws {
        let pipe = BoundedMessagePipe<Int>(capacity: 1)

        try pipe.send(1)
        #expect(throws: InferPeerGRPCError.bufferExhausted) {
            try pipe.send(2)
        }
    }

    @Test("bounded stream is single consumer")
    func boundedStreamIsSingleConsumer() async throws {
        let pipe = BoundedMessagePipe<Int>(capacity: 2)
        _ = pipe.claimedStream(bufferingLimit: 2)
        let duplicate = pipe.claimedStream(bufferingLimit: 2)

        await #expect(throws: InferPeerGRPCError.streamAlreadyConsumed) {
            for try await _ in duplicate {}
        }
    }
}
