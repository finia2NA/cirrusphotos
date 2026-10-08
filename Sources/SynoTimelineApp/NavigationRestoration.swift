import Foundation
import SynologyAPI

struct PhotoTimelineRestorationAnchor: Codable, Equatable {
    let itemID: Int64?
    let dayID: String
    let sectionOffsetHint: Int?
    let localOffset: Double
    let sectionFraction: Double
}

/// The app-level sidebar destination. Collections within Albums and Map are separate
/// from the destination itself so the last opened album or location filter survives a
/// switch away from it.
enum LibraryDestination: String, Codable, Hashable, Sendable, CaseIterable {
    case personalLibrary, favorites, albums, map
}

struct RestorableAppNavigationState: Codable, Equatable {
    static let currentVersion = 3

    var version = currentVersion
    var selectedDestination: LibraryDestination = .personalLibrary
    var openedAlbumID: Int64?
    /// Keyed by `PhotoCollectionDescriptor.rawValue`.
    var anchors: [String: PhotoTimelineRestorationAnchor] = [:]
}

@MainActor
final class NavigationRestorationStore: ObservableObject {
    static let defaultsKey = "appNavigationState"

    private let defaults: UserDefaults
    private let key: String
    private(set) var state: RestorableAppNavigationState

    init(defaults: UserDefaults = .standard, key: String = defaultsKey) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(RestorableAppNavigationState.self, from: data),
           decoded.version == RestorableAppNavigationState.currentVersion {
            state = decoded
        } else {
            state = RestorableAppNavigationState()
            defaults.removeObject(forKey: key)
        }
    }

    var selectedDestination: LibraryDestination {
        state.selectedDestination
    }

    var openedAlbumID: Int64? {
        state.openedAlbumID
    }

    func select(_ destination: LibraryDestination) {
        state.selectedDestination = destination
        save()
    }

    func setOpenedAlbum(_ id: Int64?) {
        state.openedAlbumID = id
        save()
    }

    func timelineAnchor(for collection: PhotoCollectionDescriptor) -> PhotoTimelineRestorationAnchor? {
        state.anchors[collection.rawValue]
    }

    func setTimelineAnchor(_ anchor: PhotoTimelineRestorationAnchor,
                           for collection: PhotoCollectionDescriptor) {
        state.anchors[collection.rawValue] = anchor
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
