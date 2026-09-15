import InferPeerProtocol

/// A single-consumer asynchronous transport stream.
///
/// Transport adapters use the custom `next` initializer to expose true bounded
/// backpressure. Test doubles can use the `AsyncThrowingStream`-compatible
/// initializer and `makeStream` factory.
public struct TransportMessageStream<Element: Sendable>: AsyncSequence, Sendable {
    /// The iterator returned by a transport message stream.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var base: AsyncThrowingStream<Element, any Error>.AsyncIterator?
        private let nextValue: (@Sendable () async throws -> Element?)?

        fileprivate init(base: AsyncThrowingStream<Element, any Error>.AsyncIterator) {
            self.base = base
            nextValue = nil
        }

        fileprivate init(nextValue: @escaping @Sendable () async throws -> Element?) {
            base = nil
            self.nextValue = nextValue
        }

        /// Suspends until the next message arrives or the stream terminates.
        public mutating func next() async throws -> Element? {
            if var base {
                let value = try await base.next()
                self.base = base
                return value
            }
            return try await nextValue?()
        }
    }

    /// Continuation used by test doubles and in-process adapters.
    public typealias Continuation = AsyncThrowingStream<Element, any Error>.Continuation

    private enum Storage: Sendable {
        case stream(AsyncThrowingStream<Element, any Error>)
        case next(@Sendable () async throws -> Element?)
    }

    private let storage: Storage

    /// Creates a stream backed by an `AsyncThrowingStream` producer.
    public init(_ build: (Continuation) -> Void) {
        let stream = AsyncThrowingStream<Element, any Error> { continuation in
            build(continuation)
        }
        storage = .stream(stream)
    }

    /// Creates a stream backed by a demand-aware receive operation.
    public init(next: @escaping @Sendable () async throws -> Element?) {
        storage = .next(next)
    }

    /// Creates a stream and continuation pair for in-process producers.
    public static func makeStream(
        bufferingPolicy: Continuation.BufferingPolicy = .unbounded
    ) -> (stream: Self, continuation: Continuation) {
        let pair = AsyncThrowingStream<Element, any Error>.makeStream(
            bufferingPolicy: bufferingPolicy
        )
        return (Self(storage: .stream(pair.stream)), pair.continuation)
    }

    /// Creates the stream's single-pass iterator.
    public func makeAsyncIterator() -> AsyncIterator {
        switch storage {
        case .stream(let stream):
            AsyncIterator(base: stream.makeAsyncIterator())
        case .next(let operation):
            AsyncIterator(nextValue: operation)
        }
    }

    private init(storage: Storage) {
        self.storage = storage
    }
}

/// Caller responses received from a connected coordinator.
public typealias CallerResponseStream =
    TransportMessageStream<InferPeer_V1_ClientSessionResponse>

/// Caller commands received by a coordinator.
public typealias CallerRequestStream =
    TransportMessageStream<InferPeer_V1_ClientSessionRequest>

/// Worker commands received from a connected coordinator.
public typealias WorkerResponseStream =
    TransportMessageStream<InferPeer_V1_WorkerSessionResponse>

/// Worker events received by a coordinator.
public typealias WorkerRequestStream =
    TransportMessageStream<InferPeer_V1_WorkerSessionRequest>

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
public typealias InboundPeerSessionStream = TransportMessageStream<InboundPeerSession>

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

    /// Opens a caller session using invitation credentials selected at join time.
    func connectCaller(
        to endpoint: PeerEndpoint,
        invitation: PairingInvitation
    ) async throws -> any CallerTransportSession

    /// Opens a worker session using invitation credentials selected at join time.
    func connectWorker(
        to endpoint: PeerEndpoint,
        invitation: PairingInvitation
    ) async throws -> any WorkerTransportSession

    /// Closes listeners, sessions, and transport resources owned by this adapter.
    func stop() async
}

/// A transport that has not implemented invitation-bound joining fails closed.
public enum PeerTransportJoinError: Error, Equatable, Sendable {
    case invitationUnsupported
}

public extension PeerTransport {
    func connectCaller(
        to endpoint: PeerEndpoint,
        invitation: PairingInvitation
    ) throws -> any CallerTransportSession {
        throw PeerTransportJoinError.invitationUnsupported
    }

    func connectWorker(
        to endpoint: PeerEndpoint,
        invitation: PairingInvitation
    ) throws -> any WorkerTransportSession {
        throw PeerTransportJoinError.invitationUnsupported
    }
}
