import Foundation
import SynologyAPI

/// Tracks the portion of an AVFoundation request not already supplied.
struct VideoLoadingDemand {
    private(set) var offset: Int64
    let end: Int64?
    let informationOnly: Bool

    init(requestedOffset: Int64, currentOffset: Int64, requestedLength: Int,
         allToEnd: Bool, informationOnly: Bool = false) throws {
        guard requestedOffset >= 0, currentOffset >= 0, requestedLength >= 0 else { throw SynologyAPIError.invalidResponse }
        offset = max(requestedOffset, currentOffset)
        self.informationOnly = informationOnly
        if informationOnly {
            let (value, overflow) = offset.addingReportingOverflow(1)
            guard !overflow else { throw SynologyAPIError.invalidResponse }
            end = value
        }
        else if allToEnd { end = nil }
        else {
            let (value, overflow) = requestedOffset.addingReportingOverflow(Int64(requestedLength))
            guard !overflow else { throw SynologyAPIError.invalidResponse }
            end = value
        }
    }

    func nextLength(limit: Int64) -> Int? {
        guard limit > 0 else { return nil }
        if let end { return offset < end ? Int(min(limit, end - offset)) : nil }
        return Int(limit)
    }

    mutating func advance(_ count: Int) throws {
        guard count > 0 else { throw SynologyAPIError.invalidResponse }
        let (next, overflow) = offset.addingReportingOverflow(Int64(count))
        guard !overflow, end == nil || next <= end! else { throw SynologyAPIError.invalidResponse }
        offset = next
    }
}
