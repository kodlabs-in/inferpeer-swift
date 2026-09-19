import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import Testing

struct StorageTestDatabase {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        self.directoryURL = directoryURL
        databaseURL = directoryURL.appendingPathComponent("inferpeer.sqlite")
    }

    func makeStore(
        configuration: SQLiteStorageConfiguration = .standard,
        date: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> SQLiteJobStore {
        try SQLiteJobStore(
            databaseURL: databaseURL,
            configuration: configuration,
            dateProvider: FixedStorageDateProvider(date: date)
        )
    }

    func makeOutboxStore(
        configuration: SQLiteStorageConfiguration = .standard,
        date: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> SQLiteOutboxStore {
        try SQLiteOutboxStore(
            databaseURL: databaseURL,
            configuration: configuration,
            dateProvider: FixedStorageDateProvider(date: date)
        )
    }

    func makePeerStore(
        configuration: SQLiteStorageConfiguration = .standard,
        date: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> SQLitePeerStore {
        try SQLitePeerStore(
            databaseURL: databaseURL,
            configuration: configuration,
            dateProvider: FixedStorageDateProvider(date: date)
        )
    }

    func makeModelStore(
        configuration: SQLiteStorageConfiguration = .standard,
        date: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> SQLiteModelStore {
        try SQLiteModelStore(
            databaseURL: databaseURL,
            configuration: configuration,
            dateProvider: FixedStorageDateProvider(date: date)
        )
    }

    func makeDirectRequestStore(
        configuration: SQLiteStorageConfiguration = .standard,
        date: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> SQLiteDirectRequestStore {
        try SQLiteDirectRequestStore(
            databaseURL: databaseURL,
            configuration: configuration,
            dateProvider: FixedStorageDateProvider(date: date)
        )
    }

    func makeDirectAssetStore(
        configuration: SQLiteStorageConfiguration = .standard,
        date: Date = Date(timeIntervalSince1970: 1_000)
    ) throws -> SQLiteDirectAssetStore {
        try SQLiteDirectAssetStore(
            databaseURL: databaseURL,
            assetDirectoryURL: directoryURL.appendingPathComponent("assets", isDirectory: true),
            configuration: configuration,
            dateProvider: FixedStorageDateProvider(date: date)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

struct FixedStorageDateProvider: StorageDateProvider {
    let date: Date

    func now() -> Date {
        date
    }
}

func makeSubmission(
    request: String = "request-1",
    caller: String = "caller-1",
    prompt: String = "Hello",
    digestByte: UInt8 = 0xA5,
    revision: UInt64 = 1
) throws -> RequestSubmission {
    let requestID = try #require(RequestID(rawValue: request))
    let callerID = try #require(PeerID(rawValue: caller))
    let conversationID = try #require(ConversationID(rawValue: "conversation-1"))
    let context = try ConversationContext(
        conversationID: conversationID,
        revision: revision,
        messages: [try TextMessage(role: .user, text: prompt)]
    )
    let options = try GenerationOptions(
        modelRequirement: .exact(try makeModelReference()),
        maximumOutputTokens: 64
    )
    return RequestSubmission(
        requestID: requestID,
        callerID: callerID,
        request: TextGenerationRequest(context: context, options: options),
        contentDigest: try RequestContentDigest(
            bytes: Data(repeating: digestByte, count: RequestContentDigest.byteCount)
        )
    )
}

func makeModelReference() throws -> ModelReference {
    let modelID = try #require(ModelID(rawValue: "model-1"))
    return try ModelReference(modelID: modelID, revision: "revision-1")
}

func makePeerIdentity(
    peerID: String = "peer-1",
    fingerprintByte: UInt8 = 0x5A
) throws -> PresentedPeerIdentity {
    PresentedPeerIdentity(
        peerID: try #require(PeerID(rawValue: peerID)),
        certificateFingerprint: try CertificateFingerprint(
            bytes: Data(repeating: fingerprintByte, count: CertificateFingerprint.byteCount)
        )
    )
}

func makeModelArtifact(
    directoryPath: String = "/models/model-1",
    digestByte: UInt8 = 0xC3
) throws -> LocalModelArtifact {
    let metadata = try ModelMetadata(
        quantization: "4-bit",
        tokenizer: "tokenizer.json",
        chatTemplate: "chat-template",
        license: "apache-2.0"
    )
    let descriptor = try ModelDescriptor(
        reference: makeModelReference(),
        runtimeFormat: .mlx,
        metadata: metadata,
        contextTokenLimit: 4_096,
        contentDigest: try ModelContentDigest(
            bytes: Data(repeating: digestByte, count: ModelContentDigest.byteCount)
        ),
        measuredMemoryBytes: 1_024
    )
    return try LocalModelArtifact(
        descriptor: descriptor,
        directoryURL: URL(fileURLWithPath: directoryPath, isDirectory: true)
    )
}

func acceptedRequest(from result: RequestAcceptance) throws -> StoredRequest {
    guard case .accepted(let request) = result else {
        Issue.record("Expected a newly accepted request")
        throw TestSupportError.unexpectedResult
    }
    return request
}

enum TestSupportError: Error {
    case unexpectedResult
}
