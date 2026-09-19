import Foundation
import InferPeerCore

/// Bonjour adapter for untrusted v2 direct-resource candidates.
public actor BonjourResourceDiscovery: ResourceDiscovery {
    private let configuration: BonjourDiscoveryConfiguration
    private let source: any BonjourResourceBrowseSource
    private let makeCandidateID: @Sendable () -> CandidateID
    private var continuation: DiscoveryEventStream.Continuation?
    private var consumeTask: Task<Void, Never>?
    private var candidateIDs: [BonjourObservationKey: CandidateID] = [:]
    private var active = false

    /// Creates a stopped direct-resource browser. Initialization performs no network work.
    public init(configuration: BonjourDiscoveryConfiguration = .init()) {
        self.configuration = configuration
        source = NetworkBonjourResourceBrowseSource(configuration: configuration)
        makeCandidateID = { CandidateID(rawValue: UUID().uuidString) }
    }

    init(
        configuration: BonjourDiscoveryConfiguration = .init(),
        source: any BonjourResourceBrowseSource,
        makeCandidateID: @escaping @Sendable () -> CandidateID
    ) {
        self.configuration = configuration
        self.source = source
        self.makeCandidateID = makeCandidateID
    }

    /// Starts one bounded browse subscription.
    public func start(options: DiscoveryOptions) async throws -> DiscoveryEventStream {
        guard options.eventBufferLimit > 0 else {
            throw PeerDiscoveryError.invalidBufferingLimit
        }
        guard !active else { throw PeerDiscoveryError.discoveryAlreadyActive }
        active = true

        do {
            let sourceEvents = try await source.start(
                bufferingLimit: options.eventBufferLimit
            )
            let pair = DiscoveryEventStream.makeStream(
                bufferingPolicy: .bufferingNewest(options.eventBufferLimit)
            )
            continuation = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
            consumeTask = Task { [weak self] in
                await self?.consume(sourceEvents)
            }
            return pair.stream
        } catch {
            active = false
            throw error
        }
    }

    /// Stops the browser and releases all ephemeral candidate state.
    public func stop() async {
        guard active else { return }
        active = false
        consumeTask?.cancel()
        consumeTask = nil
        await source.stop()
        candidateIDs.removeAll()
        continuation?.finish()
        continuation = nil
    }

    private func consume(_ events: BonjourBrowseEventStream) async {
        do {
            for try await event in events {
                try Task.checkCancellation()
                receive(event)
            }
            finish()
        } catch is CancellationError {
            finish()
        } catch {
            finish(throwing: error)
        }
    }

    private func receive(_ event: BonjourBrowseEvent) {
        switch event {
        case .upsert(let observation):
            upsert(observation)
        case .removed(let key):
            remove(key)
        case .permissionRequired:
            yield(.permissionRequired)
        case .permissionDenied:
            yield(.permissionDenied)
        case .discoveryUnavailable:
            yield(.discoveryUnavailable)
        }
    }

    private func upsert(_ observation: BonjourServiceObservation) {
        do {
            let record = try DirectBonjourTXTRecord(dictionary: observation.txtRecord)
            let endpoint = try LANEndpointValidator(
                permitsLoopback: configuration.permitsLoopback
            ).validate(observation.endpoint)
            guard Self.validServiceType(observation.serviceType),
                Self.validServiceName(observation.serviceName)
            else {
                remove(observation.key)
                return
            }
            let candidateID = candidateIDs[observation.key] ?? makeCandidateID()
            candidateIDs[observation.key] = candidateID
            yield(
                .candidateFound(
                    DiscoveryCandidate(
                        id: candidateID,
                        serviceName: observation.serviceName,
                        endpoint: endpoint,
                        protocolMajor: record.protocolMajor,
                        installationHint: record.installationHint,
                        capabilityVersion: record.capabilityVersion
                    )
                )
            )
        } catch {
            remove(observation.key)
        }
    }

    private func remove(_ key: BonjourObservationKey) {
        guard let candidateID = candidateIDs.removeValue(forKey: key) else { return }
        yield(.candidateRemoved(candidateID))
    }

    private func yield(_ event: DiscoveryEvent) {
        guard case .dropped = continuation?.yield(event) else { return }
        finish(throwing: PeerDiscoveryError.streamOverflow)
        Task { await source.stop() }
    }

    private func finish(throwing error: (any Error)? = nil) {
        active = false
        consumeTask = nil
        candidateIDs.removeAll()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
    }

    private static func validServiceType(_ serviceType: String) -> Bool {
        serviceType.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            == BonjourDiscoveryConfiguration.serviceType.trimmingCharacters(
                in: CharacterSet(charactersIn: ".")
            )
    }

    private static func validServiceName(_ serviceName: String) -> Bool {
        !serviceName.isEmpty && serviceName.utf8.count <= 63
    }
}

typealias BonjourBrowseEventStream = AsyncThrowingStream<BonjourBrowseEvent, any Error>

protocol BonjourResourceBrowseSource: Sendable {
    func start(bufferingLimit: Int) async throws -> BonjourBrowseEventStream
    func stop() async
}

struct BonjourObservationKey: Hashable, Sendable {
    let serviceName: String
    let domain: String
    let interfaceIndex: Int
}

struct BonjourServiceObservation: Sendable {
    let key: BonjourObservationKey
    let serviceName: String
    let serviceType: String
    let endpoint: PeerEndpoint
    let txtRecord: [String: Data]
}

enum BonjourBrowseEvent: Sendable {
    case upsert(BonjourServiceObservation)
    case removed(BonjourObservationKey)
    case permissionRequired
    case permissionDenied
    case discoveryUnavailable
}
