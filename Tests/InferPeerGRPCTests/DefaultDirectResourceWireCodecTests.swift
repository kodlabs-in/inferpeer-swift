import Foundation
import InferPeerCore
import InferPeerGRPC
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Default direct resource wire codec")
struct DefaultDirectResourceWireCodecTests {
    @Test("Text specifications preserve exact model, context, and policies")
    func roundTripsTextSpecification() throws {
        let codec = DefaultDirectResourceWireCodec()
        let model = try makeWireModel()
        let query = InferenceQuery.text(
            model: .exact(model),
            messages: [.system("Be concise"), .user("Hello")],
            generation: .init(maxOutputTokens: 77, temperature: 0.2, topP: 0.8, seed: 42)
        )
        let options = RunOptions(
            queuePolicy: .rejectWhenBusy,
            missingModelPolicy: .requireReady,
            disconnectPolicy: .cancelAfter(.seconds(9))
        )

        let encoded = try codec.encode(query, options: options)
        let decoded = try codec.decode(encoded)

        #expect(decoded.query == query)
        #expect(decoded.options.queuePolicy == .rejectWhenBusy)
        #expect(decoded.options.missingModelPolicy == .requireReady)
        #expect(encoded.attachmentReceipts.isEmpty)
    }

    @Test("Vision specifications carry only resource-issued receipts")
    func roundTripsVisionReceipts() throws {
        let codec = DefaultDirectResourceWireCodec()
        let query = InferenceQuery.vision(
            model: .exact(try makeWireModel()),
            messages: [.user("Describe the image")],
            images: [.receipt(InferenceAssetReceipt(rawValue: "receipt-1"))]
        )

        let encoded = try codec.encode(query, options: .default)
        let decoded = try codec.decode(encoded)

        #expect(decoded.query == query)
        #expect(encoded.attachmentReceipts == ["receipt-1"])
    }

    @Test("A local file cannot be smuggled into a remote specification")
    func rejectsLocalVisionFiles() throws {
        let codec = DefaultDirectResourceWireCodec()
        let query = InferenceQuery.vision(
            model: .exact(try makeWireModel()),
            messages: [.user("Describe")],
            images: [.file(URL(fileURLWithPath: "/tmp/private.jpg"))]
        )

        #expect(throws: InferPeerError.self) {
            _ = try codec.encode(query, options: .default)
        }
    }

    @Test("Text completion events round-trip through bounded payloads")
    func roundTripsCompletionEvent() throws {
        let codec = DefaultDirectResourceWireCodec()
        let model = try makeWireModel()
        let result = RunResult(
            text: "done",
            model: model,
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 4, outputTokens: 1)
        )
        let requestID = try #require(RequestID(rawValue: "request-wire"))

        let wire = try codec.encode(
            .completed(result),
            requestID: requestID,
            incarnation: "host-start-1",
            sequence: 3
        )
        let decoded = try codec.decode(wire)

        guard case .completed(let value) = decoded else {
            Issue.record("Expected a completed event")
            return
        }
        #expect(value == result)
    }
}

private func makeWireModel() throws -> ModelKey {
    try ModelKey(
        modelID: #require(ModelID(rawValue: "fixture-model")),
        revision: "manifest-sha256"
    )
}
