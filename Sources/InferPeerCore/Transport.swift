import InferPeerProtocol

/// Caller responses received from a connected coordinator.
public typealias CallerResponseStream =
    AsyncThrowingStream<InferPeer_V1_ClientSessionResponse, any Error>

/// Caller commands received by a coordinator.
public typealias CallerRequestStream =
    AsyncThrowingStream<InferPeer_V1_ClientSessionRequest, any Error>

/// Worker commands received from a connected coordinator.
public typealias WorkerResponseStream =
    AsyncThrowingStream<InferPeer_V1_WorkerSessionResponse, any Error>

/// Worker events received by a coordinator.
public typealias WorkerRequestStream =
    AsyncThrowingStream<InferPeer_V1_WorkerSessionRequest, any Error>

/// The caller side of one bidirectional coordinator session.
public protocol CallerTransportSession: Sendable {
    /// Sends one caller command in session order.
    func send(_ request: InferPeer_V1_ClientSessionRequest) async throws

    /// Returns a bounded ordered stream of coordinator responses.
    func responses(bufferingLimit: Int) -> CallerResponseStream

    /// Closes the session and releases transport resources.
    func close() async
}

/// The worker side of one bidirectional coordinator session.
public protocol WorkerTransportSession: Sendable {
    /// Sends one worker event in session order.
    func send(_ request: InferPeer_V1_WorkerSessionRequest) async throws

    /// Returns a bounded ordered stream of coordinator commands.
    func responses(bufferingLimit: Int) -> WorkerResponseStream

    /// Closes the session and releases transport resources.
    func close() async
}

/// The coordinator side of one authenticated caller session.
public protocol CoordinatorCallerSession: Sendable {
    /// The identity bound to the authenticated transport connection.
    var authenticatedPeerID: PeerID { get }

    /// Returns a bounded ordered stream of caller commands.
    func requests(bufferingLimit: Int) -> CallerRequestStream

    /// Sends one replayable coordinator response in session order.
    func send(_ response: InferPeer_V1_ClientSessionResponse) async throws

    /// Closes the session and releases transport resources.
    func close() async
}

/// The coordinator side of one authenticated worker session.
public protocol CoordinatorWorkerSession: Sendable {
    /// The identity bound to the authenticated transport connection.
    var authenticatedPeerID: PeerID { get }

    /// Returns a bounded ordered stream of worker events.
    func requests(bufferingLimit: Int) -> WorkerRequestStream

    /// Sends one coordinator command in session order.
    func send(_ response: InferPeer_V1_WorkerSessionResponse) async throws

    /// Closes the session and releases transport resources.
    func close() async
}

/// One authenticated inbound session accepted by a coordinator listener.
public enum InboundPeerSession: Sendable {
    /// A caller session.
    case caller(any CoordinatorCallerSession)

    /// A worker session.
    case worker(any CoordinatorWorkerSession)
}

/// Authenticated sessions accepted by a coordinator transport listener.
public typealias InboundPeerSessionStream = AsyncThrowingStream<InboundPeerSession, any Error>

/// A running coordinator transport listener.
public protocol CoordinatorTransportListener: Sendable {
    /// Returns a bounded stream of authenticated inbound sessions.
    func sessions(bufferingLimit: Int) -> InboundPeerSessionStream

    /// Stops accepting sessions and closes the listener.
    func close() async
}

/// Transport lifecycle and bidirectional session operations implemented by a network adapter.
public protocol PeerTransport: Sendable {
    /// Starts an authenticated coordinator listener at the approved LAN endpoint.
    func listen(at endpoint: PeerEndpoint) async throws -> any CoordinatorTransportListener

    /// Opens an authenticated caller session to a selected coordinator.
    func connectCaller(to endpoint: PeerEndpoint) async throws -> any CallerTransportSession

    /// Opens an authenticated worker session to a selected coordinator.
    func connectWorker(to endpoint: PeerEndpoint) async throws -> any WorkerTransportSession

    /// Closes listeners, sessions, and transport resources owned by this adapter.
    func stop() async
}
