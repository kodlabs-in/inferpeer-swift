import Foundation
import InferPeerCore
import Network

actor NetworkBonjourResourceBrowseSource: BonjourResourceBrowseSource {
    private let configuration: BonjourDiscoveryConfiguration
    private let queue = DispatchQueue(label: "com.kodlabs.inferpeer.direct-discovery")
    private var browser: NWBrowser?
    private var continuation: BonjourBrowseEventStream.Continuation?
    private var entries: [BonjourObservationKey: NetworkBrowseEntry] = [:]
    private var resolutionTasks: [BonjourObservationKey: Task<Void, Never>] = [:]

    init(configuration: BonjourDiscoveryConfiguration) {
        self.configuration = configuration
    }

    func start(bufferingLimit: Int) throws -> BonjourBrowseEventStream {
        guard browser == nil else { throw PeerDiscoveryError.discoveryAlreadyActive }
        let pair = BonjourBrowseEventStream.makeStream(
            bufferingPolicy: .bufferingNewest(bufferingLimit)
        )
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }

        let browser = makeBrowser()
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.receive(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { await self?.receive(state) }
        }
        browser.start(queue: queue)
        return pair.stream
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolutionTasks.values.forEach { $0.cancel() }
        resolutionTasks.removeAll()
        entries.removeAll()
        continuation?.finish()
        continuation = nil
    }

    private func makeBrowser() -> NWBrowser {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        parameters.includePeerToPeer = configuration.includesPeerToPeer
        parameters.preferNoProxies = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: BonjourDiscoveryConfiguration.serviceType,
            domain: configuration.domain
        )
        return NWBrowser(for: descriptor, using: parameters)
    }

    private func receive(_ state: NWBrowser.State) {
        switch state {
        case .waiting:
            yield(.permissionRequired)
        case .failed(let error):
            if Self.permissionDenied(error) {
                yield(.permissionDenied)
            } else {
                yield(.discoveryUnavailable)
            }
            finish()
        default:
            break
        }
    }

    private func receive(_ results: Set<NWBrowser.Result>) {
        let updated = Dictionary(
            results.flatMap(Self.entries(for:)),
            uniquingKeysWith: { first, _ in first }
        )
        let removedKeys = entries.keys.filter { updated[$0] == nil }
        let changedEntries = updated.filter { entries[$0.key] != $0.value }
        entries = updated

        for key in removedKeys {
            resolutionTasks.removeValue(forKey: key)?.cancel()
            yield(.removed(key))
        }
        for (key, entry) in changedEntries {
            resolutionTasks.removeValue(forKey: key)?.cancel()
            startResolution(entry, key: key)
        }
    }

    private func startResolution(_ entry: NetworkBrowseEntry, key: BonjourObservationKey) {
        resolutionTasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await ResolutionAttemptRunner.run(
                    policy: configuration.resolutionPolicy
                ) { _ in
                    try await NWEndpointResolver.resolve(entry.endpoint, queue: self.queue)
                }
                guard case .hostPort(let host, let port) = resolved else {
                    throw PeerDiscoveryError.resolutionFailed
                }
                let endpoint = try PeerEndpoint(
                    host: host.debugDescription,
                    port: port.rawValue
                )
                await finishResolution(entry, key: key, endpoint: endpoint)
            } catch is CancellationError {
                return
            } catch {
                await discardResolution(key)
            }
        }
    }

    private func finishResolution(
        _ entry: NetworkBrowseEntry,
        key: BonjourObservationKey,
        endpoint: PeerEndpoint
    ) {
        resolutionTasks[key] = nil
        guard entries[key] == entry else { return }
        yield(
            .upsert(
                BonjourServiceObservation(
                    key: key,
                    serviceName: entry.serviceName,
                    serviceType: entry.serviceType,
                    endpoint: endpoint,
                    txtRecord: entry.txtRecord
                )
            )
        )
    }

    private func discardResolution(_ key: BonjourObservationKey) {
        resolutionTasks[key] = nil
        yield(.removed(key))
    }

    private func yield(_ event: BonjourBrowseEvent) {
        guard case .dropped = continuation?.yield(event) else { return }
        finish(throwing: PeerDiscoveryError.streamOverflow)
    }

    private func finish(throwing error: (any Error)? = nil) {
        browser?.cancel()
        browser = nil
        resolutionTasks.values.forEach { $0.cancel() }
        resolutionTasks.removeAll()
        entries.removeAll()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
    }

    private static func entries(
        for result: NWBrowser.Result
    ) -> [(BonjourObservationKey, NetworkBrowseEntry)] {
        guard
            case .service(let name, let type, let domain, let endpointInterface) =
                result.endpoint
        else {
            return []
        }
        let interfaces =
            result.interfaces.isEmpty
            ? [endpointInterface].compactMap { $0 }
            : result.interfaces
        let effectiveInterfaces: [NWInterface?] = interfaces.isEmpty ? [nil] : interfaces
        let txtRecord = txtDictionary(from: result.metadata)

        return effectiveInterfaces.map { interface in
            let key = BonjourObservationKey(
                serviceName: name,
                domain: domain,
                interfaceIndex: interface?.index ?? 0
            )
            let endpoint = NWEndpoint.service(
                name: name,
                type: type,
                domain: domain,
                interface: interface
            )
            return (
                key,
                NetworkBrowseEntry(
                    serviceName: name,
                    serviceType: type,
                    endpoint: endpoint,
                    txtRecord: txtRecord
                )
            )
        }
    }

    private static func txtDictionary(
        from metadata: NWBrowser.Result.Metadata
    ) -> [String: Data] {
        guard case .bonjour(let txtRecord) = metadata else { return [:] }
        return NetService.dictionary(fromTXTRecord: txtRecord.data)
    }

    private static func permissionDenied(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return code == .EACCES || code == .EPERM
    }
}

private struct NetworkBrowseEntry: Equatable, Sendable {
    let serviceName: String
    let serviceType: String
    let endpoint: NWEndpoint
    let txtRecord: [String: Data]
}
