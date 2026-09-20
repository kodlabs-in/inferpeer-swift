@preconcurrency import Foundation

/// Lifecycle events emitted by a Bonjour coordinator advertisement.
public enum BonjourAdvertisementEvent: Equatable, Sendable {
    /// The operating system published the service.
    case published

    /// The advertisement stopped.
    case stopped

    /// Foundation rejected publication with its numeric NetService error code.
    case failed(errorCode: Int)
}

/// Advertises an existing coordinator TCP port without owning its listening socket.
@MainActor
public final class BonjourServiceAdvertiser: NSObject, @preconcurrency NetServiceDelegate {
    private let serviceName: String
    private let port: UInt16
    private let publishService: (NetService) -> Void
    private let stopService: (NetService) -> Void
    private var service: NetService?
    private var continuations: [UUID: AsyncStream<BonjourAdvertisementEvent>.Continuation] = [:]

    /// Creates an advertiser for one already-running coordinator listener.
    public convenience init(serviceName: String, port: UInt16) throws {
        try self.init(
            serviceName: serviceName,
            port: port,
            publishService: { $0.publish() },
            stopService: { $0.stop() }
        )
    }

    init(
        serviceName: String,
        port: UInt16,
        publishService: @escaping (NetService) -> Void,
        stopService: @escaping (NetService) -> Void
    ) throws {
        guard !serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PeerDiscoveryError.invalidServiceName
        }
        guard port > 0 else { throw PeerDiscoveryError.invalidAdvertisementPort }
        self.serviceName = serviceName
        self.port = port
        self.publishService = publishService
        self.stopService = stopService
    }

    /// Returns a bounded stream of subsequent publication lifecycle events.
    public func events(bufferingLimit: Int) throws -> AsyncStream<BonjourAdvertisementEvent> {
        guard bufferingLimit > 0 else { throw PeerDiscoveryError.invalidBufferingLimit }
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferingLimit)) { continuation in
            continuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[identifier] = nil }
            }
        }
    }

    /// Publishes only the protocol version as non-sensitive TXT metadata.
    public func start(protocolVersion: String = "1") throws {
        try start(txtRecord: ["v": Data(protocolVersion.utf8)])
    }

    /// Publishes the bounded v2 direct-resource discovery hints.
    public func startDirect(metadata: DirectBonjourAdvertisementMetadata) throws {
        let record = DirectBonjourTXTRecord(metadata: metadata)
        try start(txtRecord: record.dictionary)
    }

    private func start(txtRecord: [String: Data]) throws {
        guard service == nil else { throw PeerDiscoveryError.advertisementAlreadyActive }
        let service = NetService(
            domain: "local.",
            type: BonjourDiscoveryConfiguration.serviceType,
            name: serviceName,
            port: Int32(port)
        )
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: txtRecord))
        self.service = service
        publishService(service)
    }

    /// Stops publication and releases the Foundation service object.
    public func stop() {
        guard let service else { return }
        self.service = nil
        service.delegate = nil
        stopService(service)
        publish(.stopped)
    }

    /// Receives Foundation's successful-publication delegate callback.
    public func netServiceDidPublish(_ sender: NetService) {
        guard sender === service else { return }
        publish(.published)
    }

    /// Receives Foundation's stopped-publication delegate callback.
    public func netServiceDidStop(_ sender: NetService) {
        guard sender === service else { return }
        service = nil
        publish(.stopped)
    }

    /// Receives Foundation's publication-failure delegate callback.
    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        service = nil
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        publish(.failed(errorCode: code))
    }

    private func publish(_ event: BonjourAdvertisementEvent) {
        continuations.values.forEach { $0.yield(event) }
    }
}
