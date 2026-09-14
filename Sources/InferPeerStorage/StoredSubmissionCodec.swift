import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import SwiftProtobuf

enum StoredSubmissionCodec {
    static func encodeRequest(_ request: TextGenerationRequest) throws -> Data {
        try request.wireValue.serializedData()
    }

    static func decode(
        requestID rawRequestID: String,
        callerID rawCallerID: String,
        requestData: Data,
        contentDigest: Data
    ) throws -> RequestSubmission {
        do {
            guard let requestID = RequestID(rawValue: rawRequestID),
                let callerID = PeerID(rawValue: rawCallerID)
            else {
                throw SQLiteStorageError.corruptData
            }
            let wireRequest = try InferPeer_V1_TextRequest(serializedBytes: requestData)
            return RequestSubmission(
                requestID: requestID,
                callerID: callerID,
                request: try TextGenerationRequest(wireValue: wireRequest),
                contentDigest: try RequestContentDigest(bytes: contentDigest)
            )
        } catch let error as SQLiteStorageError {
            throw error
        } catch {
            throw SQLiteStorageError.corruptData
        }
    }
}
