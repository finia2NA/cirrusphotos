import Foundation
import SynologyAPI

public struct VideoPlaybackData: Sendable, Equatable {
    public let data: Data
    public let range: ClosedRange<Int64>
    public let totalLength: Int64
    public let contentType: String
}

struct CachedVideoSegment: Sendable {
    struct Header: Codable {
        let rangeLower: Int64
        let rangeUpper: Int64
        let totalLength: Int64
        let contentType: String
    }

    let header: Header
    let data: Data

    func encoded() throws -> Data {
        let metadata = try JSONEncoder().encode(header)
        guard metadata.count <= Int(UInt32.max) else { throw CacheError.storage }
        var length = UInt32(metadata.count).bigEndian
        var output = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        output.append(metadata)
        output.append(data)
        return output
    }

    init(response: VideoRangeResponse) {
        header = Header(rangeLower: response.range.lowerBound,
                        rangeUpper: response.range.upperBound,
                        totalLength: response.totalLength,
                        contentType: response.contentType)
        data = response.data
    }

    init(encoded: Data) throws {
        guard encoded.count >= 4 else { throw CacheError.storage }
        let length = encoded.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let end = 4 + Int(length)
        guard end <= encoded.count else { throw CacheError.storage }
        header = try JSONDecoder().decode(Header.self, from: encoded[4..<end])
        data = Data(encoded[end...])
        guard header.rangeUpper >= header.rangeLower,
              data.count == Int(header.rangeUpper - header.rangeLower + 1),
              header.totalLength > header.rangeUpper else { throw CacheError.storage }
    }
}
