import Foundation
import SynologyAPI

/// The displayed collection and selection captured when an operation is requested.
/// Ordinals always belong to `collection`, including session-derived collections.
public struct PhotoSelectionSnapshot: Sendable {
    let retention: SelectionSnapshotRetention?
    public let authority: PhotoSelectionAuthority?
    public let collection: PhotoCollectionDescriptor
    public let timeline: TimelineSnapshot
    public let timelineFingerprint: String
    public let selectedOrdinals: IndexSet
    public let knownItemIDsByOrdinal: [Int: Int64]

    public init(collection: PhotoCollectionDescriptor, timeline: TimelineSnapshot,
                timelineFingerprint: String, selectedOrdinals: IndexSet,
                knownItemIDsByOrdinal: [Int: Int64], authority: PhotoSelectionAuthority? = nil) {
        self.retention = authority?.retain()
        self.authority = authority
        self.collection = collection
        self.timeline = timeline
        self.timelineFingerprint = timelineFingerprint
        self.selectedOrdinals = selectedOrdinals
        self.knownItemIDsByOrdinal = knownItemIDsByOrdinal
    }
}
