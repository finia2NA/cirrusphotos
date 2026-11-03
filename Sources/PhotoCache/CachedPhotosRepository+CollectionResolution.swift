import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Resolve transient filter collections to the source that owns their media.
    public func mediaCollection(for collection: PhotoCollectionDescriptor) -> PhotoCollectionDescriptor {
        var source = collection
        var seen: Set<PhotoCollectionDescriptor> = []
        while let filterID = source.libraryFilterID {
            guard seen.insert(source).inserted, let state = metadata.sessions.libraryFilters[filterID] else { return source }
            source = state.registration.sourceCollection
        }
        if let id = source.mapFilterID {
            guard let map = metadata.sessions.mapFilters[id] else { return source }
            return PhotoCollectionDescriptor.library(map.space)
        }
        return source.space.map { .library($0) } ?? source
    }
}
