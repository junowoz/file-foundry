import CryptoKit
import Foundation

enum SHA256HasherError: LocalizedError {
    case sizeChanged(expected: UInt64, read: UInt64)

    var errorDescription: String? {
        switch self {
        case .sizeChanged(let expected, let read):
            "O arquivo mudou ou não pôde ser lido por completo (esperado: \(expected) bytes; lido: \(read))."
        }
    }
}

struct SHA256Hasher: Sendable {
    let chunkSize: Int

    init(chunkSize: Int = 1_048_576) {
        self.chunkSize = chunkSize
    }

    func hash(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let expectedSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var bytesRead: UInt64 = 0
        while true {
            let data = try handle.read(upToCount: chunkSize)
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
            bytesRead += UInt64(data.count)
        }
        guard bytesRead == expectedSize else {
            throw SHA256HasherError.sizeChanged(expected: expectedSize, read: bytesRead)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
