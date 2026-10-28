import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    public func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind,
                               progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        try await connect()
        return try await client.downloadPhotos(itemIDs: itemIDs, kind: kind, progress: progress)
    }
}
