import Foundation
import ImageIO

public enum PhotoDownloadValidation {
    /// The API error code when `data` is a Synology `{"success":false,"error":{...}}` body,
    /// which the NAS can serve with status 200 in place of media (for example, code 119
    /// after the session expires). Media is never JSON, so a small envelope is conclusive.
    public static func apiErrorCode(in data: Data) -> Int? {
        guard data.count <= 4_096, data.first == UInt8(ascii: "{"),
              let envelope = try? JSONDecoder().decode(APIEnvelope<EmptyData>.self, from: data),
              !envelope.success else { return nil }
        return envelope.error?.code
    }

    /// True when ImageIO recognizes at least one image. `CGImageSourceCreateWithData`
    /// alone is not a check: it returns a source for arbitrary bytes.
    static func containsImage(_ data: Data) -> Bool {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

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
