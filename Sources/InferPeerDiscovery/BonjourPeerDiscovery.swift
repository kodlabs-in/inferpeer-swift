import Foundation
import InferPeerCore
import Network

/// Network.framework Bonjour browser with an explicit numeric-LAN fallback.
public actor BonjourPeerDiscovery: PeerDiscovery {
    private let configuration: BonjourDiscoveryConfiguration
    private let queue: DispatchQueue
    private var browser: NWBrowser?
    private var continuation: DiscoveryUpdateStream.Continuation?
    private var currentEndpoints: Set<NWEndpoint> = []
    private var resolvedPeers: [NWEndpoint: DiscoveredPeer] = [:]
    private var resolutionTasks: [NWEndpoint: Task<Void, Never>] = [:]

    /// Creates a stopped discovery service. No browsing starts during initialization.
    public init(configuration: BonjourDiscoveryConfiguration = .init()) {
        self.configuration = configuration
        queue = DispatchQueue(label: "com.kodlabs.inferpeer.discovery")
    }

    // swiftlint:disable async_without_await
    /// Starts one Wi-Fi-scoped Bonjour browse and returns its bounded update stream.
    public func discover(bufferingLimit: Int) async throws -> DiscoveryUpdateStream {
        guard bufferingLimit > 0 else { throw PeerDiscoveryError.invalidBufferingLimit }
        guard browser == nil else { throw PeerDiscoveryError.discoveryAlreadyActive }

        let pair = DiscoveryUpdateStream.makeStream(
            bufferingPolicy: .bufferingNewest(bufferingLimit)
        )
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
        let browser = makeBrowser()
        self.browser = browser
        installHandlers(on: browser)
        browser.start(queue: queue)
        return pair.stream
    }

    /// Validates an explicit numeric endpoint as an untrusted LAN candidate.
    public func candidate(for endpoint: PeerEndpoint) async throws -> DiscoveredPeer {
        let validator = LANEndpointValidator(permitsLoopback: configuration.permitsLoopback)
        let validated = try validator.validate(endpoint)
        return DiscoveredPeer(serviceName: "manual", endpoint: validated)
    }

    /// Stops browsing, resolution work, and the current stream.
    public func stop() async {
        browser?.cancel()
        browser = nil
        resolutionTasks.values.forEach { $0.cancel() }
        resolutionTasks.removeAll()
        currentEndpoints.removeAll()
        resolvedPeers.removeAll()
        continuation?.finish()
        continuation = nil
    }
    // swiftlint:enable async_without_await

    private func makeBrowser() -> NWBrowser {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        parameters.includePeerToPeer = configuration.includesPeerToPeer
        parameters.preferNoProxies = true
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: BonjourDiscoveryConfiguration.serviceType,
            domain: configuration.domain
        )
        return NWBrowser(for: descriptor, using: parameters)
    }

    private func installHandlers(on browser: NWBrowser) {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.receive(results: results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { await self?.receive(state: state) }
        }
    }

    private func receive(state: NWBrowser.State) {
        guard case .failed = state else { return }
        finish(throwing: PeerDiscoveryError.browsingFailed)
    }

    private func receive(results: Set<NWBrowser.Result>) {
        let endpoints = Set(results.map(\.endpoint))
        let removed = currentEndpoints.subtracting(endpoints)
        let added = endpoints.subtracting(currentEndpoints)
        currentEndpoints = endpoints
        removed.forEach(remove)
        added.forEach(startResolution)
    }

    private func startResolution(_ endpoint: NWEndpoint) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let peer = try await self.resolve(endpoint)
                await self.finishResolution(peer, for: endpoint)
            } catch is CancellationError {
                return
            } catch {
                await self.discardResolution(for: endpoint)
            }
        }
        resolutionTasks[endpoint] = task
    }

    private func finishResolution(_ peer: DiscoveredPeer, for endpoint: NWEndpoint) {
        resolutionTasks[endpoint] = nil
        guard currentEndpoints.contains(endpoint) else { return }
        resolvedPeers[endpoint] = peer
        yield(.found(peer))
    }

    private func discardResolution(for endpoint: NWEndpoint) {
        resolutionTasks[endpoint] = nil
    }

    private func remove(_ endpoint: NWEndpoint) {
        resolutionTasks.removeValue(forKey: endpoint)?.cancel()
        guard let peer = resolvedPeers.removeValue(forKey: endpoint) else { return }
        yield(.lost(peer))
    }

    private func resolve(_ endpoint: NWEndpoint) async throws -> DiscoveredPeer {
        let resolved = try await ResolutionAttemptRunner.run(
            policy: configuration.resolutionPolicy
        ) { _ in
            try await NWEndpointResolver.resolve(endpoint, queue: self.queue)
        }
        guard case .hostPort(let host, let port) = resolved else {
            throw PeerDiscoveryError.resolutionFailed
        }
        let candidate = try PeerEndpoint(host: host.debugDescription, port: port.rawValue)
        let validator = LANEndpointValidator(permitsLoopback: configuration.permitsLoopback)
        let validated = try validator.validate(candidate)
        return DiscoveredPeer(serviceName: serviceName(for: endpoint), endpoint: validated)
    }

    private func serviceName(for endpoint: NWEndpoint) -> String {
        guard case .service(let name, _, _, _) = endpoint else { return "bonjour" }
        return name
    }

    private func yield(_ update: DiscoveryUpdate) {
        guard case .dropped = continuation?.yield(update) else { return }
        finish(throwing: PeerDiscoveryError.streamOverflow)
    }

    private func finish(throwing error: any Error) {
        browser?.cancel()
        browser = nil
        resolutionTasks.values.forEach { $0.cancel() }
        resolutionTasks.removeAll()
        currentEndpoints.removeAll()
        resolvedPeers.removeAll()
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

enum ResolutionAttemptRunner {
    static func run<Value: Sendable>(
        policy: BonjourResolutionPolicy,
        operation: @escaping @Sendable (Int) async throws -> Value
    ) async throws -> Value {
        for attempt in 1...policy.maximumAttempts {
            do {
                return try await withTimeout(policy.timeout) {
                    try await operation(attempt)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < policy.maximumAttempts else {
                    throw PeerDiscoveryError.resolutionFailed
                }
                try await Task.sleep(for: .seconds(policy.retryDelay))
            }
        }
        throw PeerDiscoveryError.resolutionFailed
    }

    private static func withTimeout<Value: Sendable>(
        _ timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw PeerDiscoveryError.resolutionFailed
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw PeerDiscoveryError.resolutionFailed
            }
            return value
        }
    }
}

private enum NWEndpointResolver {
    static func resolve(_ endpoint: NWEndpoint, queue: DispatchQueue) async throws -> NWEndpoint {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let waiter = ConnectionStateWaiter()
        connection.stateUpdateHandler = { state in
            receive(state, from: connection, waiter: waiter)
        }
        connection.start(queue: queue)
        return try await withTaskCancellationHandler {
            defer { connection.cancel() }
            return try await waiter.wait()
        } onCancel: {
            connection.cancel()
            Task { await waiter.complete(.failure(CancellationError())) }
        }
    }

    private static func receive(
        _ state: NWConnection.State,
        from connection: NWConnection,
        waiter: ConnectionStateWaiter
    ) {
        switch state {
        case .ready:
            let result =
                connection.currentPath?.remoteEndpoint
                .map(Result<NWEndpoint, any Error>.success)
                ?? .failure(PeerDiscoveryError.resolutionFailed)
            Task { await waiter.complete(result) }
        case .failed:
            Task { await waiter.complete(.failure(PeerDiscoveryError.resolutionFailed)) }
        case .cancelled:
            Task { await waiter.complete(.failure(CancellationError())) }
        default:
            break
        }
    }
}

private actor ConnectionStateWaiter {
    private var result: Result<NWEndpoint, any Error>?
    private var continuation: CheckedContinuation<NWEndpoint, any Error>?

    func wait() async throws -> NWEndpoint {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete(_ result: Result<NWEndpoint, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
