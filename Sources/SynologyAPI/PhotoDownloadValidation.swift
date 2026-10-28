import Foundation

enum PhotoDownloadValidation {
    /// Every ZIP, including ZIP64, ends with an EOCD record and an optional comment.
    /// Check the bounded trailer before publishing an archive without a Content-Length.
    static func hasCompleteZIPTrailer(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { return false }
        let length = min(size, 65_557)
        try handle.seek(toOffset: size - length)
        let tail = [UInt8](try handle.readToEnd() ?? Data())
        guard tail.count >= 22 else { return false }
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            guard tail[index] == 0x50, tail[index + 1] == 0x4b,
                  tail[index + 2] == 0x05, tail[index + 3] == 0x06 else { continue }
            let commentLength = Int(tail[index + 20]) | Int(tail[index + 21]) << 8
            if index + 22 + commentLength == tail.count { return true }
        }
        return false
    }
}
