import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    func itemActionSpace(itemIDs: [Int64], collection: PhotoCollectionDescriptor) async throws -> PhotoSpace {
        switch collection.contentScope {
        case .space(let space): return space
        case .album: return try await albumItemSpace(itemIDs: itemIDs, collection: collection)
        case .incomingAlbum: throw RepositoryError.unavailable("This action is unavailable for incoming albums.")
        }
    }

    /// Album IDs do not establish a member's origin. Compare authoritative reads
    /// in both domains and accept exactly one complete matching domain. Never
    /// persist these probe results into either canonical space namespace.
    func albumItemSpace(itemIDs: [Int64], collection: PhotoCollectionDescriptor) async throws -> PhotoSpace {
        let source = mediaCollection(for: collection)
        guard source.albumID != nil, !itemIDs.isEmpty,
              Set(itemIDs).count == itemIDs.count else {
            throw RepositoryError.stale("The album item origin could not be verified.")
        }
        try await initializeMetadataEngine()
        try await connect()
        var origin: PhotoSpace?
        for start in stride(from: 0, to: itemIDs.count, by: 100) {
            try Task.checkCancellation()
            let chunk = Array(itemIDs[start..<min(start + 100, itemIDs.count)])
            let album = try await resolveMetadataItems(chunk, priority: .visible, collection: source, freshness: .fresh)
            var candidates: [PhotoSpace: [PhotoItem]] = [:]
            for space in PhotoSpace.allCases {
                let result = try await metadataReadRequest(priority: .visible) { try await client.items(ids: chunk, space: space) }
                guard Set(result.map(\.id)).isSubset(of: Set(chunk)), Set(result.map(\.id)).count == result.count else {
                    throw SynologyAPIError.invalidResponse
                }
                candidates[space] = result
            }
            let resolved = try Self.uniqueAlbumItemSpace(album, candidates: candidates)
            guard origin == nil || origin == resolved else {
                throw RepositoryError.unavailable("Choose items from one space for this action.")
            }
            origin = resolved
        }
        guard let origin else { throw SynologyAPIError.invalidResponse }
        return origin
    }

    static func uniqueAlbumItemSpace(_ album: [PhotoItem], candidates: [PhotoSpace: [PhotoItem]]) throws -> PhotoSpace {
        guard !album.isEmpty else { throw SynologyAPIError.invalidResponse }
        var origins: Set<PhotoSpace> = []
        for member in album {
            let matching = PhotoSpace.allCases.filter { space in
                candidates[space]?.contains { candidate in
                    guard let thumbnail = member.additional?.thumbnail else { return false }
                    return candidate.id == member.id && candidate.ownerUserID == member.ownerUserID &&
                        candidate.time == member.time && candidate.filename == member.filename &&
                        candidate.type == member.type && candidate.liveType == member.liveType &&
                        candidate.filesize == member.filesize && candidate.additional?.thumbnail == thumbnail
                } == true
            }
            guard matching.count == 1 else {
                throw RepositoryError.unavailable("The album item origin is ambiguous or unavailable.")
            }
            origins.insert(matching[0])
        }
        guard origins.count == 1, let space = origins.first else {
            throw RepositoryError.unavailable("Choose items from one space for this action.")
        }
        return space
    }
}
