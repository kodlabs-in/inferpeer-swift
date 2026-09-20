import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import InferPeerCore

/// Starts advertising after a pinned-TLS direct resource listener is bound.
public actor PosixDirectResourceExposure: ResourceExposure {
    /// Stops a previously published Bonjour advertisement.
    public typealias AdvertisementStop = @Sendable () async -> Void
    /// Publishes the endpoint after the TLS listener has bound successfully.
    public typealias Advertise = @Sendable (PeerEndpoint) async throws -> AdvertisementStop

    private struct ActiveServer {
        let server: GRPCServer<HTTP2ServerTransport.Posix>
        let task: Task<Void, Never>
        let stopAdvertisement: AdvertisementStop
    }

    private enum State {
        case stopped
        case starting(
            id: UUID,
            server: GRPCServer<HTTP2ServerTransport.Posix>,
            task: Task<Void, Never>
        )
        case active(id: UUID, server: ActiveServer)
        case stopping(id: UUID)

        var runningID: UUID? {
            switch self {
            case .starting(let id, _, _), .active(let id, _): id
            case .stopped, .stopping: nil
            }
        }
    }

    private let endpoint: PeerEndpoint
    private let credentials: GRPCDeviceCredentials
    private let service: DirectResourceGRPCService
    private let advertise: Advertise
    private let maximumMessageBytes: Int
    private var state: State = .stopped

    /// Creates a stopped exposure for an explicit local interface address and port.
    public init(
        endpoint: PeerEndpoint,
        credentials: GRPCDeviceCredentials,
        service: DirectResourceGRPCService,
        maximumMessageBytes: Int = 4 * 1_024 * 1_024,
        advertise: @escaping Advertise
    ) throws {
        guard maximumMessageBytes > 0 else {
            throw InferPeerGRPCError.invalidConfiguration
        }
        self.endpoint = endpoint
        self.credentials = credentials
        self.service = service
        self.maximumMessageBytes = maximumMessageBytes
        self.advertise = advertise
    }

    /// Binds TLS first, then publishes the exact reachable endpoint.
    public func start(configuration: ExposureConfiguration) async throws -> ExposureHandle {
        guard case .stopped = state else { throw InferPeerGRPCError.invalidConfiguration }
        let transport = makeTransport()
        let server = GRPCServer(transport: transport, services: [service])
        let id = UUID()
        let task = start(server, id: id)
        state = .starting(id: id, server: server, task: task)
        do {
            _ = try await transport.listeningAddress
            let stopAdvertisement = try await advertisementStop(
                enabled: configuration.advertisesOnLocalNetwork
            )
            guard case .starting(let currentID, _, _) = state, currentID == id else {
                await stopAdvertisement()
                throw CancellationError()
            }
            state = .active(
                id: id,
                server: ActiveServer(
                    server: server,
                    task: task,
                    stopAdvertisement: stopAdvertisement
                )
            )
            return exposureHandle(id: id)
        } catch {
            if case .starting(let currentID, _, _) = state, currentID == id {
                state = .stopping(id: id)
            }
            server.beginGracefulShutdown()
            task.cancel()
            await service.suspend()
            if case .stopping(let currentID) = state, currentID == id {
                state = .stopped
            }
            throw DirectRPCErrorMapper.publicError(from: error)
        }
    }

    /// Stops advertising before releasing the listener.
    public func stop() async {
        await stop(id: nil)
    }

    private func exposureHandle(id: UUID) -> ExposureHandle {
        ExposureHandle(
            endpoint: endpoint,
            stop: { [weak self] in await self?.stop(id: id) },
            isActive: { [weak self] in await self?.isActive(id: id) == true }
        )
    }

    private func advertisementStop(enabled: Bool) async throws -> AdvertisementStop {
        if enabled { return try await advertise(endpoint) }
        return {}
    }

    private func stop(id expectedID: UUID?) async {
        guard let current = runningState(ownedBy: expectedID) else { return }
        let stopID = UUID()
        state = .stopping(id: stopID)
        await shutDown(current)
        await service.suspend()
        if case .stopping(let currentID) = state, currentID == stopID {
            state = .stopped
        }
    }

    private func runningState(ownedBy expectedID: UUID?) -> State? {
        let current = state
        guard let runningID = current.runningID,
            expectedID == nil || expectedID == runningID
        else { return nil }
        return current
    }

    private func shutDown(_ current: State) async {
        switch current {
        case .starting(_, let server, let task):
            server.beginGracefulShutdown()
            task.cancel()
        case .active(_, let active):
            await active.stopAdvertisement()
            active.server.beginGracefulShutdown()
            active.task.cancel()
        case .stopped, .stopping:
            return
        }
    }

    private func isActive(id: UUID) -> Bool {
        guard case .active(let currentID, _) = state else { return false }
        return currentID == id
    }

    private func serverStopped(id: UUID) async {
        switch state {
        case .starting(let currentID, _, _) where currentID == id:
            state = .stopping(id: id)
            await service.suspend()
        case .active(let currentID, let active) where currentID == id:
            state = .stopping(id: id)
            await active.stopAdvertisement()
            await service.suspend()
        default:
            return
        }
        if case .stopping(let currentID) = state, currentID == id {
            state = .stopped
        }
    }

    nonisolated private func start(
        _ server: GRPCServer<HTTP2ServerTransport.Posix>,
        id: UUID
    ) -> Task<Void, Never> {
        Task { [weak self] in
            try? await server.serve()
            await self?.serverStopped(id: id)
        }
    }

    private func makeTransport() -> HTTP2ServerTransport.Posix {
        HTTP2ServerTransport.Posix(
            address: PosixNetworkFactory.socketAddress(for: endpoint),
            transportSecurity: PosixTLSFactory.directServerSecurity(credentials: credentials),
            config: .defaults { config in
                config.rpc.maxRequestPayloadSize = maximumMessageBytes
            }
        )
    }
}
