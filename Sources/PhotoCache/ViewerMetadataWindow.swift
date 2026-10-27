import Foundation
import SynologyAPI

/// Bounded metadata storage and ordinal geometry, mutated only by its owning viewer actor.
struct ViewerMetadataWindow {
    struct SectionSpan: Sendable {
        let sectionIndex: Int
        let start: Int
        let count: Int
    }
    struct PageEntry: Sendable {
        let slots: [PhotoItemSlot]
        let verified: Bool
        let membershipVerified: Bool
        var items: [PhotoItem] { slots.compactMap(\.item) }
        func slot(at offset: Int) -> PhotoItemSlot? { slots.indices.contains(offset) ? slots[offset] : nil }
        init(slots: [PhotoItemSlot], verified: Bool, membershipVerified: Bool? = nil) {
            self.slots = slots; self.verified = verified; self.membershipVerified = membershipVerified ?? verified
        }
        init(items: [PhotoItem], verified: Bool) {
            self.init(slots: items.map { PhotoItemSlot(itemID: $0.id, item: $0, verified: verified) }, verified: verified)
        }
    }
    struct PageJob {
        let id: UUID
        let allowNetwork: Bool
        let task: Task<Void, Never>
    }

    let spans: [SectionSpan]
    let totalCount: Int
    let maximumPages: Int
    var pages: [Int: PageEntry] = [:]
    var pageJobs: [Int: PageJob] = [:]

    init(index: LibraryIndex, maximumPages: Int) {
        self.maximumPages = max(1, min(3, maximumPages))
        var built: [SectionSpan] = []
        var running = 0
        for sectionIndex in index.sections.indices {
            let count = max(0, index.sections[sectionIndex].limit)
            built.append(SectionSpan(sectionIndex: sectionIndex, start: running, count: count))
            let sum = running.addingReportingOverflow(count)
            running = sum.overflow ? Int.max : sum.partialValue
        }
        spans = built
        totalCount = running
    }

    func seedLocation(sectionIndex: Int, pageOffset: Int) -> PhotoViewerLocation {
        let section = min(max(0, sectionIndex), max(0, spans.count - 1))
        let span = spans.indices.contains(section) ? spans[section] : SectionSpan(sectionIndex: 0, start: 0, count: 0)
        let offset = min(max(0, pageOffset), max(0, span.count - 1))
        return PhotoViewerLocation(sectionIndex: section, pageOffset: offset, ordinal: span.start + offset)
    }

    mutating func cancelJobs() {
        for job in pageJobs.values { job.task.cancel() }
        pageJobs.removeAll()
    }

    mutating func trimPages(around location: PhotoViewerLocation) {
        var desiredSections = [location.sectionIndex]
        if let previous = self.location(for: location.ordinal - 1), !desiredSections.contains(previous.sectionIndex) {
            desiredSections.append(previous.sectionIndex)
        }
        if let next = self.location(for: location.ordinal + 1), !desiredSections.contains(next.sectionIndex) {
            desiredSections.append(next.sectionIndex)
        }
        let retained = Set(desiredSections.prefix(maximumPages))
        pages = pages.filter { retained.contains($0.key) }
    }

    mutating func trimPageJobs(around location: PhotoViewerLocation) {
        var retained: Set<Int> = [location.sectionIndex]
        // Neighbor metadata is needed for the always-on thumbnail buffer. Original-image
        // prefetch remains separately gated on the current original succeeding.
        if let previous = self.location(for: location.ordinal - 1) { retained.insert(previous.sectionIndex) }
        if let next = self.location(for: location.ordinal + 1) { retained.insert(next.sectionIndex) }
        for (section, job) in pageJobs where !retained.contains(section) {
            job.task.cancel()
            pageJobs.removeValue(forKey: section)
        }
    }

    func location(for ordinal: Int) -> PhotoViewerLocation? {
        guard ordinal >= 0, ordinal < totalCount else { return nil }
        // The section count is compact (one record per server page); no item array is built.
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            let span = spans[mid]
            if ordinal < span.start { high = mid }
            else if ordinal >= span.start + span.count { low = mid + 1 }
            else {
                return PhotoViewerLocation(sectionIndex: span.sectionIndex,
                                           pageOffset: ordinal - span.start, ordinal: ordinal)
            }
        }
        return nil
    }
}
