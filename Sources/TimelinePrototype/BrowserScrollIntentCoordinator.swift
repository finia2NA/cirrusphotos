import Foundation
import PhotoCache

struct BrowserRevealRequest: Equatable {
    let id = UUID()
    let itemID: Int64
    let dayID: String
    let sectionOffsetHint: Int?
}

/// Owns navigation intent, independently of AppKit's row hosting and scroll effects.
/// Explicit navigation replaces earlier work; layout/page updates only refine it.
struct BrowserScrollIntentCoordinator {
    enum Intent {
        case idle
        case restoration(PhotoTimelineRestorationAnchor, LibraryViewportGeometry.Anchor?)
        case preservation(LibraryViewportGeometry.Anchor)
        case reveal(BrowserRevealRequest, LibraryViewportGeometry.Anchor?)
    }

    enum Resolution {
        case preserveViewport
        case scroll(Double)
        case reveal(UUID, Int64)
        case settled
    }

    private(set) var intent: Intent = .idle
    private var capturedRestoration = false
    private var lastJump: UUID?
    private var verifiedSections: Set<Int> = []
    private var programmaticY: Double?

    var restoration: PhotoTimelineRestorationAnchor? {
        if case .restoration(let saved, _) = intent { return saved }
        return nil
    }

    var anchor: LibraryViewportGeometry.Anchor? {
        switch intent {
        case .idle: nil
        case .restoration(_, let anchor), .reveal(_, let anchor): anchor
        case .preservation(let anchor): anchor
        }
    }

    var revealID: UUID? {
        if case .reveal(let request, _) = intent { return request.id }
        return nil
    }

    var canPersistViewport: Bool {
        if case .idle = intent { return true }
        return false
    }

    mutating func captureRestoration(_ saved: PhotoTimelineRestorationAnchor?) {
        guard !capturedRestoration else { return }
        capturedRestoration = true
        if let saved { intent = .restoration(saved, nil) }
    }

    /// Rebase against a new descriptor map, preserving the reason for the anchor.
    mutating func rebuild(index: LibraryIndex, geometry: LibraryViewportGeometry,
                          previousIndex: LibraryIndex?, visibleAnchor: LibraryViewportGeometry.Anchor?,
                          timelineVerified: Bool) -> Double? {
        verifiedSections.removeAll()
        switch intent {
        case .restoration(let saved, _):
            intent = .restoration(saved, Self.anchor(dayID: saved.dayID, itemID: saved.itemID,
                offsetHint: saved.sectionOffsetHint, localOffset: saved.localOffset,
                fraction: saved.sectionFraction, index: index, geometry: geometry))
        case .reveal(let request, _):
            intent = .reveal(request, Self.anchor(dayID: request.dayID, itemID: request.itemID,
                offsetHint: request.sectionOffsetHint, index: index, geometry: geometry))
        case .idle, .preservation:
            if let previous = anchor ?? visibleAnchor {
                let offset = previousIndex.flatMap {
                    $0.sections.indices.contains(previous.sectionIndex) ? $0.sections[previous.sectionIndex].offset : nil
                }
                if let rebased = Self.anchor(dayID: previous.dayID, itemID: previous.itemID,
                    offsetHint: offset, localOffset: previous.localOffset, fraction: previous.fraction,
                    index: index, geometry: geometry) {
                    intent = .preservation(rebased)
                } else { settle() }
            }
        }
        let target = anchor.flatMap { geometry.y(for: $0) ?? geometry.y(forDay: $0.dayID) }
        timelineDidVerify(index: index, verified: timelineVerified)
        return target
    }

    mutating func timelineDidVerify(index: LibraryIndex, verified: Bool) {
        if verified, let saved = restoration, !index.dayIDs.contains(saved.dayID) { settle() }
    }

    mutating func jump(id: UUID, dayID: String, index: LibraryIndex,
                       geometry: LibraryViewportGeometry) -> Double? {
        guard id != lastJump else { return nil }
        lastJump = id
        settle()
        return geometry.nearestDay(to: dayID, orderedDays: index.dayIDs).flatMap { geometry.y(forDay: $0) }
    }

    mutating func reveal(_ request: BrowserRevealRequest, index: LibraryIndex,
                         geometry: LibraryViewportGeometry) -> Double? {
        settle()
        guard let target = Self.anchor(dayID: request.dayID, itemID: request.itemID,
            offsetHint: request.sectionOffsetHint, index: index, geometry: geometry) else { return nil }
        intent = .reveal(request, target)
        // The hinted slice matters when a single day spans more than the page window.
        return geometry.y(forItem: request.itemID, offset: 0) ?? geometry.y(for: target)
    }

    mutating func reconcile(pages: [Int: LibraryPage], index: LibraryIndex,
                            geometry: LibraryViewportGeometry, timelineVerified: Bool) -> Resolution {
        guard let pending = anchor else { return .preserveViewport }
        let dayID = restoration?.dayID ?? pending.dayID
        for page in pages.values where page.verified && index.slices(inSection: page.sectionIndex)
            .contains(where: { $0.dayID == dayID }) {
            verifiedSections.insert(page.sectionIndex)
        }
        if let itemID = pending.itemID, let exact = geometry.y(forItem: itemID, offset: pending.localOffset) {
            if case .reveal(let request, _) = intent { return .reveal(request.id, itemID) }
            settle()
            return .scroll(exact)
        }
        let sections = Set(index.sectionIndices(forDay: pending.dayID))
        if !sections.isEmpty, sections.isSubset(of: verifiedSections) {
            if let saved = restoration,
               !timelineVerified || (index.dayIDs.contains(saved.dayID) && pending.dayID != saved.dayID) {
                return .preserveViewport
            }
            settle()
            return .settled
        }
        return .preserveViewport
    }

    func nextSectionToVerify(index: LibraryIndex, allowNetwork: Bool) -> Int? {
        guard allowNetwork, let saved = restoration, index.dayIDs.contains(saved.dayID) else { return nil }
        let candidates = index.sectionIndices(forDay: saved.dayID).filter { !verifiedSections.contains($0) }
        guard let hint = saved.sectionOffsetHint else { return candidates.first }
        return candidates.min { abs(index.sections[$0].offset - hint) < abs(index.sections[$1].offset - hint) }
    }

    mutating func revealPositioned(id: UUID) {
        guard case .reveal(let request, _) = intent, request.id == id else { return }
        intent = .reveal(request, nil)
    }

    /// Deferred rectangle conversion can only complete the request that scheduled it.
    @discardableResult
    mutating func finishReveal(id: UUID) -> Bool {
        guard revealID == id else { return false }
        settle()
        return true
    }

    mutating func didScrollProgrammatically(to y: Double) { programmaticY = y }

    mutating func viewportMoved(to y: Double) {
        guard let programmaticY, abs(y - programmaticY) > 2 else { return }
        settle()
        self.programmaticY = nil
    }

    mutating func stop() { settle(); programmaticY = nil }

    private mutating func settle() {
        intent = .idle
        verifiedSections.removeAll()
    }

    private static func anchor(dayID: String, itemID: Int64?, offsetHint: Int?,
                               localOffset: Double = 0, fraction: Double = 0,
                               index: LibraryIndex, geometry: LibraryViewportGeometry) -> LibraryViewportGeometry.Anchor? {
        guard let day = geometry.nearestDay(to: dayID, orderedDays: index.dayIDs),
              let slice = index.slices(forDay: day).min(by: { lhs, rhs in
                  guard let offsetHint else { return lhs.sectionIndex < rhs.sectionIndex }
                  return abs(index.sections[lhs.sectionIndex].offset - offsetHint) <
                      abs(index.sections[rhs.sectionIndex].offset - offsetHint)
              }) else { return nil }
        return LibraryViewportGeometry.Anchor(dayID: day, sectionIndex: slice.sectionIndex,
            itemID: day == dayID ? itemID : nil, localOffset: localOffset, fraction: fraction)
    }
}
