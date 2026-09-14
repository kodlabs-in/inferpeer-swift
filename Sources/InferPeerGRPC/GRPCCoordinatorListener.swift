import GRPCCore
import GRPCNIOTransportHTTP2Posix
import InferPeerCore

final class GRPCCoordinatorListener: CoordinatorTransportListener, @unchecked Sendable {
    private let inboundSessions: BoundedMessagePipe<InboundPeerSession>
    private let terminator: SessionTerminator

    init(
        inboundSessions: BoundedMessagePipe<InboundPeerSession>,
        server: GRPCServer<HTTP2ServerTransport.Posix>,
        serverTask: Task<Void, Never>
    ) {
        self.inboundSessions = inboundSessions
        terminator = SessionTerminator {
            server.beginGracefulShutdown()
            serverTask.cancel()
            inboundSessions.finish()
        }
    }

    func sessions(bufferingLimit: Int) -> InboundPeerSessionStream {
        inboundSessions.claimedStream(bufferingLimit: bufferingLimit)
    }

    func close() async {
        await Task.yield()
        terminator.terminate()
    }
}
