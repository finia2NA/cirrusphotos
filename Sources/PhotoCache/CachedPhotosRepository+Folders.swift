import Foundation
import SynologyAPI

public struct FolderDirectory: Codable, Sendable {
    public let folder: FolderSummary
    public let children: [FolderSummary]
}

extension CachedPhotosRepository {
    public func folderDirectory(id: Int64, space: PhotoSpace) -> AsyncStream<ResourceEvent<FolderDirectory>> {
        metadataIndex(key: PhotoCollectionDescriptor.folder(id, space: space), space: space, name: "Folders", jobs: \.folderJobs,
            cached: { try await $0.metadataFolderDirectory($1, id: id) },
            fetch: { client in
                let folder = try await client.folder(id: id, space: space)
                let children = try await client.folders(parentID: folder.id, space: space)
                return FolderDirectory(folder: folder, children: children)
            },
            persist: { try await $0.storeMetadataFolderDirectory($2, namespace: $1, id: id, currentRun: $3, admission: $4) })
    }
}

extension CachedPhotosRepository {
    /// Folders visited and uncached directory reads allowed per cover search.
    private static let coverVisitLimit = 30
    private static let coverFetchLimit = 6

    /// Up to `limit` thumbnails representing `folder`: its own cover, else the covers of
    /// descendant folders found breadth-first, then the folder's direct photos from a
    /// cached first page. Directories come from the cache; at most a few unread ones are fetched.
    public func folderCovers(for folder: FolderSummary, space: PhotoSpace, limit: Int = 4) async -> [ThumbnailInfo] {
        if let own = folder.thumbnail { return [own] }
        let namespace = metadataNamespace(for: space)
        var covers: [ThumbnailInfo] = []
        var queue = [folder.id]
        var visited: Set<Int64> = [folder.id]
        var fetches = 0
        var index = 0
        while index < queue.count, covers.count < limit, index < Self.coverVisitLimit, !Task.isCancelled {
            let id = queue[index]
            index += 1
            var directory = (try? await store.metadataFolderDirectory(namespace, id: id))?.0
            if directory == nil, fetches < Self.coverFetchLimit {
                fetches += 1
                for await event in folderDirectory(id: id, space: space) {
                    if case .value(let value, _) = event { directory = value }
                    break
                }
            }
            for child in directory?.children ?? [] where visited.insert(child.id).inserted {
                if let thumbnail = child.thumbnail {
                    if covers.count < limit { covers.append(thumbnail) }
                } else { queue.append(child.id) }
            }
        }
        if covers.count < limit, !Task.isCancelled {
            covers += await cachedFolderPhotoThumbnails(folderID: folder.id, space: space, limit: limit - covers.count)
        }
        return covers
    }

    /// Thumbnails of the first cached page of the folder's most recent day; nothing is fetched.
    private func cachedFolderPhotoThumbnails(folderID: Int64, space: PhotoSpace, limit: Int) async -> [ThumbnailInfo] {
        let namespace = metadataNamespace(for: space)
        let collection = PhotoCollectionDescriptor.folder(folderID, space: space)
        guard let catalog = try? await store.metadataCatalog(CollectionKey(namespace: namespace, collection: collection)),
              let day = catalog.catalog.days.first,
              let address = try? DayPageAddress(collection: collection, day: day.day, offset: 0),
              let page = try? await store.metadataPage(address, namespace: namespace, currentRun: runID) else { return [] }
        let thumbnails = page.slots.compactMap { slot -> ThumbnailInfo? in
            guard let item = slot.item, item.hasDisplayableStillImage else { return nil }
            return item.additional?.thumbnail
        }
        return Array(thumbnails.prefix(limit))
    }
}
