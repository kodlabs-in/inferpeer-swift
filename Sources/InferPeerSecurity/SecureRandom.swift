import Foundation
import Security

enum SecureRandom {
    static func data(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw InferPeerSecurityError.keychainFailure(status: status)
        }
        return Data(bytes)
    }

    static func identifier(prefix: String) throws -> String {
        let bytes = try data(count: 16)
        let suffix = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(prefix)\(suffix)"
    }
}
