import Foundation
import GRDB
import InferPeerCore

struct OutboxRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "callerOutbox"

    var requestID: String
    var callerID: String
    var requestData: Data
    var contentDigest: Data
    var enqueuedAt: Date

    init(submission: RequestSubmission, enqueuedAt: Date) throws {
        requestID = submission.requestID.rawValue
        callerID = submission.callerID.rawValue
        requestData = try StoredSubmissionCodec.encodeRequest(submission.request)
        contentDigest = submission.contentDigest.bytes
        self.enqueuedAt = enqueuedAt
    }

    func storedRequest() throws -> StoredOutboxRequest {
        StoredOutboxRequest(
            submission: try StoredSubmissionCodec.decode(
                requestID: requestID,
                callerID: callerID,
                requestData: requestData,
                contentDigest: contentDigest
            ),
            enqueuedAt: enqueuedAt
        )
    }
}

struct CallerReplayRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "callerReplayState"

    var requestID: String
    var callerID: String
    var latestCursor: Int64
    var acknowledgedCursor: Int64?
}

/// Durable caller-side replay cursors used to resume after process or connection loss.
public struct CallerReplayState: Equatable, Sendable {
    /// Highest event persisted locally before host delivery.
    public let latestCursor: UInt64

    /// Highest cursor the host explicitly acknowledged, when present.
    public let acknowledgedCursor: UInt64?

    /// Creates a validated replay checkpoint.
    public init(latestCursor: UInt64, acknowledgedCursor: UInt64?) {
        self.latestCursor = latestCursor
        self.acknowledgedCursor = acknowledgedCursor
    }
}
