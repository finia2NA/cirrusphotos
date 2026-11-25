import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Albums among `targets` whose cached pages already list every selected item. Reads only
    /// the cache and ignores validation, so the answer is a hint that may be stale. Album member
    /// IDs do not reveal their space, so a member also needs the selection's cached filename,
    /// capture time, kind and size. Unloaded selected items, or more than 2,000, give no answer.
    public func cachedContainment(of selection: PhotoSelectionSnapshot,
                                  in targets: [PhotoCollectionDescriptor]) async -> Set<PhotoCollectionDescriptor> {
        guard !targets.isEmpty, !selection.selectedOrdinals.isEmpty, selection.selectedOrdinals.count <= 2000 else { return [] }
        var ids: [Int64] = []
        for ordinal in selection.selectedOrdinals {
            guard let id = selection.knownItemIDsByOrdinal[ordinal] else { return [] }
            ids.append(id)
        }
        let unique = Array(Set(ids))
        let source = mediaCollection(for: selection.collection)
        var result = Set<PhotoCollectionDescriptor>()
        if targets.contains(source) { result.insert(source) }
        let albums = targets.filter { $0 != source && ($0.albumID != nil || $0.incomingAlbumIdentity != nil) }
        guard !albums.isEmpty, (try? await initializeMetadataEngine()) != nil,
              let sourceFacets = try? await store.metadataCachedFacets(metadataNamespace(for: source), ids: unique),
              sourceFacets.count == unique.count else { return result }
        for album in albums {
            let namespace = metadataNamespace(for: album)
            guard let members = try? await store.metadataCachedMemberIDs(namespace, collection: album, ids: unique),
                  members.count == unique.count,
                  let facets = try? await store.metadataCachedFacets(namespace, ids: unique),
                  unique.allSatisfy({ Self.sameItem(sourceFacets[$0], facets[$0]) }) else { continue }
            result.insert(album)
        }
        return result
    }

    private static func sameItem(_ a: ItemFacets?, _ b: ItemFacets?) -> Bool {
        guard let a, let b, a.filename != nil else { return false }
        return a.filename == b.filename && a.captureTime == b.captureTime && a.mediaKind == b.mediaKind && a.bytes == b.bytes
    }
}
