import Foundation
import SynologyAPI

struct PhotoTimelineRestorationAnchor: Codable, Equatable {
    let itemID: Int64?
    let dayID: String
    let sectionOffsetHint: Int?
    let localOffset: Double
    let sectionFraction: Double
}

struct RestorableAppNavigationState: Codable, Equatable {
    static let currentVersion = 2

    var version = currentVersion
    var selectedCollection: PhotoCollectionDescriptor = .personalLibrary
    var personalLibraryAnchor: PhotoTimelineRestorationAnchor?
    var favoritesAnchor: PhotoTimelineRestorationAnchor?
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

    var selectedCollection: PhotoCollectionDescriptor {
        state.selectedCollection
    }

    func select(_ collection: PhotoCollectionDescriptor) {
        state.selectedCollection = collection
        save()
    }

    func timelineAnchor(for collection: PhotoCollectionDescriptor) -> PhotoTimelineRestorationAnchor? {
        switch collection {
        case .personalLibrary: state.personalLibraryAnchor
        case .favorites: state.favoritesAnchor
        }
    }

    func setTimelineAnchor(_ anchor: PhotoTimelineRestorationAnchor,
                           for collection: PhotoCollectionDescriptor) {
        switch collection {
        case .personalLibrary: state.personalLibraryAnchor = anchor
        case .favorites: state.favoritesAnchor = anchor
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
