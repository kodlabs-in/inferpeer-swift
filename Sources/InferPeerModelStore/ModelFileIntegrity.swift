import Crypto
import Foundation

enum ModelFileIntegrity {
    static func matches(_ url: URL, file: ModelDownloadFile) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
            size.uint64Value == file.byteCount
        else {
            return false
        }
        return try digest(url) == file.sha256.bytes
    }

    private static func digest(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }
}
