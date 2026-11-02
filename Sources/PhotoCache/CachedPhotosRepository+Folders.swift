import Foundation
import SynologyAPI

public struct FolderDirectory: Codable, Sendable {
    public let folder: FolderSummary
    public let children: [FolderSummary]
}

extension CachedPhotosRepository {
    public func folderDirectory(id: Int64, space: PhotoSpace = .personal) -> AsyncStream<ResourceEvent<FolderDirectory>> {
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
