import Foundation

/// Bounded non-sensitive metadata advertised by one direct-resource endpoint.
public struct DirectBonjourAdvertisementMetadata: Equatable, Sendable {
    /// The direct-resource protocol major supported by this package.
    public static let protocolMajor: UInt32 = 2

    /// Opaque per-installation hint. It is a location hint, never an identity credential.
    public let installationHint: Data

    /// Small revision hint used to decide whether capabilities should be refreshed.
    public let capabilityVersion: UInt32

    /// Creates validated Bonjour metadata without publishing it.
    public init(installationHint: Data, capabilityVersion: UInt32) throws {
        try DirectBonjourTXTRecord.validateInstallationHint(installationHint)
        self.installationHint = installationHint
        self.capabilityVersion = capabilityVersion
    }
}

struct DirectBonjourTXTRecord: Equatable, Sendable {
    static let protocolKey = "v"
    static let installationKey = "i"
    static let capabilityKey = "c"
    static let maximumEncodedBytes = 256
    static let maximumInstallationHintBytes = 64

    let protocolMajor: UInt32
    let installationHint: Data
    let capabilityVersion: UInt32

    init(metadata: DirectBonjourAdvertisementMetadata) {
        protocolMajor = DirectBonjourAdvertisementMetadata.protocolMajor
        installationHint = metadata.installationHint
        capabilityVersion = metadata.capabilityVersion
    }

    init(dictionary: [String: Data]) throws {
        let allowedKeys = Set([Self.protocolKey, Self.installationKey, Self.capabilityKey])
        guard Set(dictionary.keys).isSubset(of: allowedKeys),
            NetService.data(fromTXTRecord: dictionary).count <= Self.maximumEncodedBytes,
            let protocolData = dictionary[Self.protocolKey],
            let protocolMajor = Self.parseInteger(protocolData),
            protocolMajor == DirectBonjourAdvertisementMetadata.protocolMajor,
            let installationHint = dictionary[Self.installationKey],
            let capabilityData = dictionary[Self.capabilityKey],
            let capabilityVersion = Self.parseInteger(capabilityData)
        else {
            throw PeerDiscoveryError.invalidTXTRecord
        }
        try Self.validateInstallationHint(installationHint)
        self.protocolMajor = protocolMajor
        self.installationHint = installationHint
        self.capabilityVersion = capabilityVersion
    }

    var dictionary: [String: Data] {
        [
            Self.protocolKey: Data(String(protocolMajor).utf8),
            Self.installationKey: installationHint,
            Self.capabilityKey: Data(String(capabilityVersion).utf8),
        ]
    }

    static func validateInstallationHint(_ hint: Data) throws {
        guard !hint.isEmpty, hint.count <= maximumInstallationHintBytes else {
            throw PeerDiscoveryError.invalidTXTRecord
        }
    }

    private static func parseInteger(_ data: Data) -> UInt32? {
        guard !data.isEmpty, data.count <= 10,
            data.allSatisfy({ (48...57).contains($0) }),
            let string = String(data: data, encoding: .utf8),
            let value = UInt32(string)
        else {
            return nil
        }
        return value
    }
}
