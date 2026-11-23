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
        return metadataIndex(key: PhotoCollectionDescriptor.folder(id, space: space), space: space, name: "Folders", guardsFolderRefresh: true, priority: priority, jobs: \.folderJobs,
            cached: { try await $0.metadataFolderDirectory($1, id: id) },
            fetch: { client in
                let folder = if let known { known } else { try await client.folder(id: id, space: space) }
                let children = try await client.folders(parentID: folder.id, space: space)
                return FolderDirectory(folder: folder, children: children)
            },
            persist: { try await $0.storeMetadataFolderDirectory($2, namespace: $1, id: id, currentRun: $3, admission: $4) })
    }
}

/// A folder card's ordered image sources. Custom images are addressed by folder, not photo unit.
public enum FolderCoverResource: Codable, Hashable, Sendable {
    case photo(ThumbnailInfo)
    case custom(folderID: Int64, cacheKey: String, sequence: Int64)
}

public struct FolderCoverPresentation: Codable, Equatable, Sendable {
    public let folder: FolderSummary
    public let resources: [FolderCoverResource]
}

extension FolderSummary {
    /// A custom selection occupies the whole card. Ordinary server entries keep their order.
    var serverCoverResources: [FolderCoverResource] {
        let entries = additional?.thumbnail ?? []
        for entry in entries {
            if case .custom(let key, let sequence) = entry {
                return [.custom(folderID: id, cacheKey: key, sequence: sequence)]
            }
        }
        return entries.prefix(4).compactMap {
            if case .photo(let thumbnail) = $0 { return .photo(thumbnail) }
            return nil
        }
    }
}

extension CachedPhotosRepository {
    private static let coverVisitLimit = 30
    private static let coverFetchLimit = 6

    /// NAS covers take precedence. Only folders without them search their descendants.
    public func folderCovers(for folder: FolderSummary, space: PhotoSpace) async throws -> FolderCoverPresentation {
        let supplied = folder.serverCoverResources
        if !supplied.isEmpty { return FolderCoverPresentation(folder: folder, resources: supplied) }
        let namespace = metadataNamespace(for: space)
        if let stored = try? await store.metadataFolderCovers(namespace, id: folder.id),
           stored.validatedRun == runID, stored.covers.folder == folder {
            return stored.covers
        }
        let admission = try? await store.metadataAdmission(namespace)
        var covers: [FolderCoverResource] = []
        func add(_ cover: FolderCoverResource) {
            guard covers.count < 4, !covers.contains(cover) else { return }
            covers.append(cover)
        }
        var queue = [folder.id]
        var visited: Set<Int64> = [folder.id]
        var fetches = 0
        var index = 0
        while index < queue.count, covers.count < 4, index < Self.coverVisitLimit, !Task.isCancelled {
            let id = queue[index]
            index += 1
            var directory = (try? await store.metadataFolderDirectory(namespace, id: id))?.0
            if directory == nil, fetches < Self.coverFetchLimit {
                fetches += 1
                for await event in folderDirectory(id: id, space: space, priority: .prefetch) {
                    if case .value(let value, _) = event { directory = value }
                    break
                }
            }
            for child in directory?.children ?? [] where visited.insert(child.id).inserted {
                let resources = child.serverCoverResources
                if resources.isEmpty { queue.append(child.id) }
                else { resources.forEach(add) }
            }
        }
        if covers.count < 4, !Task.isCancelled {
            for thumbnail in await cachedFolderPhotoThumbnails(folderID: folder.id, space: space, limit: 4) {
                add(.photo(thumbnail))
            }
        }
        let result = FolderCoverPresentation(folder: folder, resources: covers)
        try Task.checkCancellation()
        if let admission {
            do {
                try await store.storeMetadataFolderCovers(result, namespace: namespace, id: folder.id,
                                                          currentRun: runID, admission: admission)
            } catch let error as MetadataAdmissionError {
                throw error
            } catch {
                // A failed cache write does not prevent displaying the resolved images.
            }
        }
        return result
    }

    /// Supplies the NAS composition immediately, or the previous locally derived composition.
    public func cachedFolderCovers(for folder: FolderSummary, space: PhotoSpace) async -> FolderCoverPresentation? {
        let supplied = folder.serverCoverResources
        if !supplied.isEmpty { return FolderCoverPresentation(folder: folder, resources: supplied) }
        return try? await store.metadataFolderCovers(metadataNamespace(for: space), id: folder.id)?.covers
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

extension CachedPhotosRepository {
    /// Whether the account may download originals of `item` shown in `collection`, from what the
    /// NAS reported: the album's grant for an album shared with the account, or the cached
    /// listing of the item's Shared Space folder. Nil when nothing says.
    public func originalDownloadAllowed(for item: PhotoItem, in collection: PhotoCollectionDescriptor) async -> Bool? {
        let source = mediaCollection(for: collection)
        if source.incomingAlbumIdentity != nil { return incomingAccess[source]?.access.download }
        guard source.contentScope == .space(.shared), let folderID = item.folderID,
              let directory = try? await store.metadataFolderDirectory(metadataNamespace(for: .shared), id: folderID)?.0 else { return nil }
        return directory.folder.allowsDownload
    }
}
