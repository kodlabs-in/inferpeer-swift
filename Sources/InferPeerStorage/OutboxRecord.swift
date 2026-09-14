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
