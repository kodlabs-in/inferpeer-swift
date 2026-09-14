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
    private var service: NetService?
    private var continuations: [UUID: AsyncStream<BonjourAdvertisementEvent>.Continuation] = [:]

    /// Creates an advertiser for one already-running coordinator listener.
    public init(serviceName: String, port: UInt16) throws {
        guard !serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PeerDiscoveryError.invalidServiceName
        }
        guard port > 0 else { throw PeerDiscoveryError.invalidAdvertisementPort }
        self.serviceName = serviceName
        self.port = port
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
        guard service == nil else { throw PeerDiscoveryError.advertisementAlreadyActive }
        let service = NetService(
            domain: "local.",
            type: BonjourDiscoveryConfiguration.serviceType,
            name: serviceName,
            port: Int32(port)
        )
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: ["v": Data(protocolVersion.utf8)]))
        self.service = service
        service.publish()
    }

    /// Stops publication and releases the Foundation service object.
    public func stop() {
        service?.stop()
        service = nil
    }

    /// Receives Foundation's successful-publication delegate callback.
    public func netServiceDidPublish(_ sender: NetService) {
        publish(.published)
    }

    /// Receives Foundation's stopped-publication delegate callback.
    public func netServiceDidStop(_ sender: NetService) {
        service = nil
        publish(.stopped)
    }

    /// Receives Foundation's publication-failure delegate callback.
    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        service = nil
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        publish(.failed(errorCode: code))
    }

    private func publish(_ event: BonjourAdvertisementEvent) {
        continuations.values.forEach { $0.yield(event) }
    }
}
