import Foundation
import SynologyAPI

struct CollectionIndexJobKey: Hashable, Sendable {
    let kind: CollectionIndexKind
    let space: PhotoSpace
}

extension CachedPhotosRepository {
    /// People, Subjects or Tags for a space, cached-first and validated once per run.
    public func collectionIndex(_ kind: CollectionIndexKind, space: PhotoSpace) -> AsyncStream<ResourceEvent<[CollectionIndexEntry]>> {
        metadataIndex(key: CollectionIndexJobKey(kind: kind, space: space), space: space, name: kind.displayName,
                      guardsPeopleMutations: kind == .person, jobs: \.collectionIndexJobs,
            cached: { try await $0.metadataCollectionIndex(kind, namespace: $1) },
            fetch: { try await $0.collectionIndex(kind, space: space) },
            persist: { try await $0.storeMetadataCollectionIndex(kind, $2, namespace: $1, currentRun: $3, admission: $4) })
    }
}

extension CollectionIndexKind {
    var displayName: String {
        switch self {
        case .person: "People"
        case .subject: "Subjects"
        case .tag: "Tags"
        }
    }
}
