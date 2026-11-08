import PhotoCache
import Testing
@testable import CirrusPhotosApp

@MainActor
@Suite struct CacheUsageSegmentsTests {
    private let rows = [
        CacheUsageView.Row(id: "a", name: "alice", usage: CacheUsageBreakdown(bytes: [.metadata: 10, .thumbnails: 30])),
        CacheUsageView.Row(id: "b", name: "bob", usage: CacheUsageBreakdown(bytes: [.video: 20])),
    ]

    @Test func accountsFillTheBarInOrderThenTheAvailableSpace() {
        let segments = CacheUsageView.segments(rows: rows, budget: 100, showsCategories: false)
        #expect(segments.map(\.key) == ["alice", "bob", CacheUsageView.availableKey])
        #expect(segments.map(\.start) == [0, 40, 60])
        #expect(segments.map(\.end) == [40, 60, 100])
    }

    @Test func categoriesSplitEachAccount() {
        let segments = CacheUsageView.segments(rows: rows, budget: 100, showsCategories: true)
        #expect(segments.map(\.key) == ["Metadata", "Thumbnails", "Video", CacheUsageView.availableKey])
        #expect(segments.map(\.end) == [10, 40, 60, 100])
        #expect(CacheUsageView.accountBoundaries(rows: rows) == [40])
    }

    @Test func noAvailableSpaceWhenOverTheMaximum() {
        let segments = CacheUsageView.segments(rows: rows, budget: 50, showsCategories: false)
        #expect(segments.map(\.key) == ["alice", "bob"])
        #expect(segments.last?.end == 60)
    }
}
