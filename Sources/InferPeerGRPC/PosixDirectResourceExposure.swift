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

    private let endpoint: PeerEndpoint
    private let credentials: GRPCDeviceCredentials
    private let service: DirectResourceGRPCService
    private let advertise: Advertise
    private let maximumMessageBytes: Int
    private var active: ActiveServer?

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
        guard active == nil else { throw InferPeerGRPCError.invalidConfiguration }
        let transport = HTTP2ServerTransport.Posix(
            address: PosixNetworkFactory.socketAddress(for: endpoint),
            transportSecurity: PosixTLSFactory.directServerSecurity(credentials: credentials),
            config: .defaults { config in
                config.rpc.maxRequestPayloadSize = maximumMessageBytes
            }
        )
        let server = GRPCServer(transport: transport, services: [service])
        let task = Self.start(server)
        do {
            _ = try await transport.listeningAddress
            let stopAdvertisement: AdvertisementStop
            if configuration.advertisesOnLocalNetwork {
                stopAdvertisement = try await advertise(endpoint)
            } else {
                stopAdvertisement = {}
            }
            active = ActiveServer(
                server: server,
                task: task,
                stopAdvertisement: stopAdvertisement
            )
            return ExposureHandle(endpoint: endpoint) { [weak self] in
                await self?.stop()
            }
        } catch {
            server.beginGracefulShutdown()
            task.cancel()
            throw DirectRPCErrorMapper.publicError(from: error)
        }
    }

    /// Stops advertising before releasing the listener.
    public func stop() async {
        guard let active else { return }
        self.active = nil
        await active.stopAdvertisement()
        active.server.beginGracefulShutdown()
        active.task.cancel()
    }

    private static func start(
        _ server: GRPCServer<HTTP2ServerTransport.Posix>
    ) -> Task<Void, Never> {
        Task {
            try? await server.serve()
        }
    }
}
