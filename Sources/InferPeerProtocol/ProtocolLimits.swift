import SwiftProtobuf

/// Hard wire-size limits shared by callers, coordinators, workers, and transports.
public enum InferPeerProtocolLimits {
    /// Maximum serialized request or event message size: 256 KiB.
    public static let maximumMessageBytes = 256 * 1_024

    /// Returns whether a text request fits the protocol payload budget.
    public static func permits(_ request: InferPeer_V1_TextRequest) -> Bool {
        serializedSize(of: request) <= maximumMessageBytes
    }

    /// Returns whether a generation event fits the protocol payload budget.
    public static func permits(_ event: InferPeer_V1_GenerationEvent) -> Bool {
        serializedSize(of: event) <= maximumMessageBytes
    }

    private static func serializedSize<Message: SwiftProtobuf.Message>(
        of message: Message
    ) -> Int {
        (try? message.serializedData().count) ?? .max
    }
}
