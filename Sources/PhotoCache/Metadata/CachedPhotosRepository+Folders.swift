import Foundation
import SynologyAPI

public struct FolderDirectory: Codable, Sendable, Equatable {
    public let folder: FolderSummary
    public let children: [FolderSummary]
}

extension CachedPhotosRepository {
    /// The folder and its child listing. `known` is the folder's summary from its parent's
    /// listing verified this run; it saves the folder's own `get` request, so a walk of the tree
    /// costs one listing request per folder. The root always needs `get` to resolve its ID.
    public func folderDirectory(id: Int64, space: PhotoSpace, known: FolderSummary? = nil,
                                priority: RequestPriority = .visible) -> AsyncStream<ResourceEvent<FolderDirectory>> {
        let known = id != 0 && known?.id == id ? known : nil
        return metadataIndex(key: PhotoCollectionDescriptor.folder(id, space: space), space: space, name: "Folders", priority: priority, jobs: \.folderJobs,
            cached: { try await $0.metadataFolderDirectory($1, id: id) },
            fetch: { client in
                let folder = if let known { known } else { try await client.folder(id: id, space: space) }
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

    /// Up to `limit` distinct thumbnails representing `folder`: its own cover, then the covers of
    /// descendant folders found breadth-first, then the folder's direct photos from a cached
    /// first page. Directories come from the cache; unread ones are fetched at prefetch priority,
    /// a few for a folder without its own cover and only the folder's own listing otherwise.
    /// Results persist per folder. A result computed in this run is reused as is; one from an
    /// earlier run is shown by `cachedFolderCovers` and recomputed once. Listing changes and uploads
    /// withdraw the current run's results.
    public func folderCovers(for folder: FolderSummary, space: PhotoSpace, limit: Int = 4) async -> [ThumbnailInfo] {
        let started = ContinuousClock.now
        let namespace = metadataNamespace(for: space)
        if let stored = try? await store.metadataFolderCovers(namespace, id: folder.id), stored.validatedRun == runID {
            return stored.covers
        }
        var covers: [ThumbnailInfo] = []
        func add(_ thumbnail: ThumbnailInfo) {
            guard covers.count < limit,
                  !covers.contains(where: { $0.unitID == thumbnail.unitID && $0.cacheKey == thumbnail.cacheKey }) else { return }
            covers.append(thumbnail)
        }
        if let own = folder.thumbnail { add(own) }
        let fetchLimit = folder.thumbnail == nil ? Self.coverFetchLimit : 1
        var queue = [folder.id]
        var visited: Set<Int64> = [folder.id]
        var fetches = 0
        var index = 0
        while index < queue.count, covers.count < limit, index < Self.coverVisitLimit, !Task.isCancelled {
            let id = queue[index]
            index += 1
            var directory = (try? await store.metadataFolderDirectory(namespace, id: id))?.0
            if directory == nil, fetches < fetchLimit {
                fetches += 1
                for await event in folderDirectory(id: id, space: space, priority: .prefetch) {
                    if case .value(let value, _) = event { directory = value }
                    break
                }
            }
            for child in directory?.children ?? [] where visited.insert(child.id).inserted {
                if let thumbnail = child.thumbnail { add(thumbnail) } else { queue.append(child.id) }
            }
        }
        if covers.count < limit, !Task.isCancelled {
            for thumbnail in await cachedFolderPhotoThumbnails(folderID: folder.id, space: space, limit: limit) { add(thumbnail) }
        }
        guard !Task.isCancelled else { return covers }
        if let admission = try? await store.metadataAdmission(namespace) {
            try? await store.storeMetadataFolderCovers(covers, namespace: namespace, id: folder.id, currentRun: runID, admission: admission)
        }
        SynologyDiagnostics.folders.info("covers folder=\(folder.id, privacy: .public) found=\(covers.count, privacy: .public) visited=\(index, privacy: .public) fetches=\(fetches, privacy: .public) elapsed=\(String(describing: ContinuousClock.now - started), privacy: .public)")
        return covers
    }

    /// The covers last stored for `folder`, from this run or an earlier one; nothing is read from the network.
    public func cachedFolderCovers(for folder: FolderSummary, space: PhotoSpace) async -> [ThumbnailInfo]? {
        try? await store.metadataFolderCovers(metadataNamespace(for: space), id: folder.id)?.covers
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
