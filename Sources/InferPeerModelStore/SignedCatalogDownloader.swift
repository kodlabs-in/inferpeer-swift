import Foundation

/// Network failures specific to fetching a signed model catalog envelope.
public enum ModelCatalogDownloadError: Error, Equatable, Sendable {
    case insecureURL
    case invalidResponse
    case responseTooLarge(maximumBytes: Int)
}

/// Bounded HTTPS transport for signed catalog envelopes.
public protocol SignedModelCatalogDownloading: Sendable {
    func download(from url: URL) async throws -> Data
}

/// Downloads a small signed catalog while enforcing both initial and final HTTPS URLs.
public actor HTTPSSignedModelCatalogDownloader: SignedModelCatalogDownloading {
    /// Conservative upper bound for catalog metadata, not model artifacts.
    public static let defaultMaximumBytes = 1_048_576

    private let session: URLSession
    private let maximumBytes: Int

    public init(
        configuration: URLSessionConfiguration = .default,
        maximumBytes: Int = defaultMaximumBytes
    ) {
        session = URLSession(configuration: configuration)
        self.maximumBytes = maximumBytes
    }

    public func download(from url: URL) async throws -> Data {
        guard maximumBytes > 0, url.scheme?.lowercased() == "https" else {
            throw ModelCatalogDownloadError.insecureURL
        }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ModelCatalogDownloadError.invalidResponse
        }
        guard response.url?.scheme?.lowercased() == "https" else {
            throw ModelCatalogDownloadError.insecureURL
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw ModelCatalogDownloadError.responseTooLarge(maximumBytes: maximumBytes)
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw ModelCatalogDownloadError.responseTooLarge(maximumBytes: maximumBytes)
            }
            data.append(byte)
        }
        return data
    }
}
