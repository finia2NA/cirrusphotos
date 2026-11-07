import Foundation
import SynologyAPI

/// Resolves selected still images through the shared selection verifier.
public struct SelectionDownloadResolver: Sendable {
    private let repository: CachedPhotosRepository

    public init(repository: CachedPhotosRepository) { self.repository = repository }

    public func resolve(_ selection: PhotoSelectionSnapshot) async -> [PhotoItem]? {
        return await SelectionItemResolver(repository: repository).resolve(selection)?.filter(\.hasDisplayableStillImage)
    }
}
