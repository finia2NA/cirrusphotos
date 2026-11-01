import Foundation

public struct FolderSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let parent: Int64
    public let additional: Additional?
    public struct Additional: Codable, Hashable, Sendable {
        public let thumbnail: [ThumbnailInfo]?
    }
    public var displayName: String { name.split(separator: "/").last.map(String.init) ?? "/" }
    public var thumbnail: ThumbnailInfo? {
        guard let thumbnails = additional?.thumbnail else { return nil }
        return thumbnails.first(where: { $0.isReady(.m) || $0.isReady(.sm) || $0.isReady(.xl) }) ?? thumbnails.first
    }
}
