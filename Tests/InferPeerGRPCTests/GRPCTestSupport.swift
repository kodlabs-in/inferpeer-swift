import Darwin
import Foundation
import InferPeerCore
import InferPeerGRPC
import InferPeerProtocol
import InferPeerSecurity
import Testing

final class GRPCMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    func setData(_ data: Data, forKey key: String) throws {
        lock.withLock { values[key] = data }
    }

    func removeData(forKey key: String) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }
}

struct GRPCTestIdentity: Sendable {
    let credentials: DeviceCredentials
    let transportCredentials: GRPCDeviceCredentials
}

func makeGRPCTestIdentity() async throws -> GRPCTestIdentity {
    let manager = DeviceIdentityManager(secretStore: GRPCMemorySecretStore())
    let credentials = try await manager.credentials()
    return GRPCTestIdentity(
        credentials: credentials,
        transportCredentials: try GRPCDeviceCredentials(
            identity: credentials.identity,
            certificateDER: credentials.certificateDER,
            privateKeyDER: credentials.privateKeyDER
        )
    )
}

func makeCertificateVerifier() -> GRPCCertificateVerifier {
    GRPCCertificateVerifier { certificateDER, expectedFingerprint in
        try CertificateIdentityVerifier().verify(
            certificateDER: certificateDER,
            expectedFingerprint: expectedFingerprint
        )
    }
}

func makeAuthorizer(allowing peerID: PeerID?) -> GRPCSessionAuthorizer {
    GRPCSessionAuthorizer { identity, _, _ in
        guard identity.peerID == peerID else {
            throw InferPeerGRPCError.permissionDenied
        }
    }
}

func makeGRPCEndpoint() throws -> PeerEndpoint {
    try PeerEndpoint(host: "127.0.0.1", port: availableLoopbackPort())
}

func makeNetworkPolicy(endpoint: PeerEndpoint) throws -> GRPCNetworkPolicy {
    try GRPCNetworkPolicy(interfaceName: "lo0", allowedEndpoints: [endpoint])
}

func makeMetadata(
    clusterID: ClusterID,
    senderID: PeerID,
    sequence: UInt64
) -> InferPeer_V1_MessageMetadata {
    InferPeer_V1_MessageMetadata.with {
        $0.protocolVersion = InferPeerProtocolVersion.current
        $0.clusterID = clusterID.rawValue
        $0.authenticatedSenderID = senderID.rawValue
        $0.messageID = "message-\(sequence)"
        $0.sequence = sequence
    }
}

func first<Element: Sendable>(
    in stream: AsyncThrowingStream<Element, any Error>
) async throws -> Element {
    var iterator = stream.makeAsyncIterator()
    return try #require(try await iterator.next())
}

func firstTask<Element: Sendable>(
    in stream: AsyncThrowingStream<Element, any Error>
) -> Task<Element, any Error> {
    Task { try await first(in: stream) }
}

private func availableLoopbackPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw InferPeerGRPCError.unavailable }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw InferPeerGRPCError.unavailable }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard nameResult == 0 else { throw InferPeerGRPCError.unavailable }
    return UInt16(bigEndian: address.sin_port)
}
