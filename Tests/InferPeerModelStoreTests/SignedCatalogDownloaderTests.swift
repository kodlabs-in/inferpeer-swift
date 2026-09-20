import Foundation
import InferPeerInference
import InferPeerModelStore
import Testing

@Suite("Bounded HTTPS downloads", .serialized)
struct SignedCatalogDownloaderTests {
    @Test("Catalog responses are bounded before decoding")
    func rejectsOversizedCatalog() async throws {
        StubURLProtocol.install(
            responseURL: try #require(URL(string: "https://catalog.example/models.json")),
            data: Data(repeating: 0x2A, count: 5),
            headers: ["Content-Length": "5"]
        )
        let downloader = HTTPSSignedModelCatalogDownloader(
            configuration: stubConfiguration(),
            maximumBytes: 4
        )

        await #expect(
            throws: ModelCatalogDownloadError.responseTooLarge(maximumBytes: 4)
        ) {
            _ = try await downloader.download(
                from: try #require(URL(string: "https://catalog.example/models.json"))
            )
        }
    }

    @Test("Catalog transport rejects a non-HTTPS final response URL")
    func rejectsCatalogDowngrade() async throws {
        StubURLProtocol.install(
            responseURL: try #require(URL(string: "http://catalog.example/models.json")),
            data: Data("{}".utf8)
        )
        let downloader = HTTPSSignedModelCatalogDownloader(
            configuration: stubConfiguration()
        )

        await #expect(throws: ModelCatalogDownloadError.insecureURL) {
            _ = try await downloader.download(
                from: try #require(URL(string: "https://catalog.example/models.json"))
            )
        }
    }

    @Test("Model transport rejects a non-HTTPS final response URL")
    func rejectsModelDowngrade() async throws {
        StubURLProtocol.install(
            responseURL: try #require(URL(string: "http://models.example/weights.bin")),
            data: Data([0x01])
        )
        let downloader = ResumableHTTPSModelDownloader(configuration: stubConfiguration())
        let file = try ModelDownloadFile(
            relativePath: "weights.bin",
            url: try #require(URL(string: "https://models.example/weights.bin")),
            byteCount: 1,
            sha256: ModelContentDigest(bytes: Data(repeating: 0, count: 32))
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: ModelDownloadError.insecureURL) {
            _ = try await downloader.download(file, to: destination) { _ in }
        }
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Stub {
        let responseURL: URL
        let data: Data
        let headers: [String: String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stub: Stub?

    static func install(
        responseURL: URL,
        data: Data,
        headers: [String: String] = [:]
    ) {
        lock.lock()
        stub = Stub(responseURL: responseURL, data: data, headers: headers)
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let stub = Self.stub
        Self.lock.unlock()
        guard let stub,
            let response = HTTPURLResponse(
                url: stub.responseURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
