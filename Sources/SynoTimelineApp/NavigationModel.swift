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
    case personalLibrary, favorites, recentlyAdded, albums, map, people, subjects, tags

    var indexKind: CollectionIndexKind? {
        switch self {
        case .people: .person
        case .subjects: .subject
        case .tags: .tag
        default: nil
        }
    }
}

enum SidebarSelection: Codable, Hashable {
    case destination(LibraryDestination)
    case album(PhotoCollectionDescriptor)

    var destination: LibraryDestination {
        switch self { case .destination(let destination): destination; case .album: .albums }
    }
}

struct RestorableSpaceNavigation: Codable, Equatable {
    var namespace: String?
    var openedIndexEntries: [CollectionIndexKind: Int64] = [:]
    var showsFolders = false
    var folderPath: [Int64] = []
}

struct RestorableAppNavigationState: Codable, Equatable {
    static let currentVersion = 10

    var version = currentVersion
    var sidebarSelection: SidebarSelection = .destination(.personalLibrary)
    var openedAlbum: PhotoCollectionDescriptor?
    var selectedSpace: PhotoSpace = .personal
    var spaces: [PhotoSpace: RestorableSpaceNavigation] = [:]
    /// Keyed by `PhotoCollectionDescriptor.rawValue`.
    var anchors: [String: PhotoTimelineRestorationAnchor] = [:]
}

/// The single source of navigation state. Every change persists, so the window
/// restores the same destination, space, album, folder and collection on launch.
@MainActor
final class NavigationModel: ObservableObject {
    static let defaultsKey = "appNavigationState"

    private let defaults: UserDefaults
    private let key: String
    /// Not `@Published`: timeline anchors change while scrolling and must not
    /// re-render observers. Navigation setters announce their own changes.
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
        state.sidebarSelection.destination
    }

    var sidebarSelection: SidebarSelection {
        get { state.sidebarSelection }
        set { objectWillChange.send(); state.sidebarSelection = newValue; save() }
    }

    var selectedSpace: PhotoSpace {
        get { state.selectedSpace }
        set { objectWillChange.send(); state.selectedSpace = newValue; save() }
    }

    private var spaceNavigation: RestorableSpaceNavigation {
        state.spaces[state.selectedSpace] ?? RestorableSpaceNavigation()
    }
    private func updateSpaceNavigation(_ update: (inout RestorableSpaceNavigation) -> Void) {
        var navigation = spaceNavigation
        update(&navigation)
        state.spaces[state.selectedSpace] = navigation
        save()
    }
    private func prepareSpace(namespace: String) {
        guard spaceNavigation.namespace != namespace else { return }
        objectWillChange.send()
        updateSpaceNavigation { navigation in
            navigation = RestorableSpaceNavigation(namespace: namespace, showsFolders: navigation.showsFolders)
        }
    }

    /// Folder mode and path for the selected space.
    var showsFolders: Bool {
        get { spaceNavigation.showsFolders }
        set { objectWillChange.send(); updateSpaceNavigation { $0.showsFolders = newValue } }
    }
    var folderPath: [Int64] {
        get { spaceNavigation.folderPath }
        set { objectWillChange.send(); updateSpaceNavigation { $0.folderPath = newValue } }
    }
    /// The opened person, subject or tag of each index in the selected space.
    var openedIndexEntries: [CollectionIndexKind: Int64] {
        get { spaceNavigation.openedIndexEntries }
        set { objectWillChange.send(); updateSpaceNavigation { $0.openedIndexEntries = newValue } }
    }
    func prepareFolders(namespace: String) -> [Int64] {
        prepareSpace(namespace: namespace)
        return folderPath
    }
    func prepareIndexEntry(_ kind: CollectionIndexKind, namespace: String) -> Int64? {
        prepareSpace(namespace: namespace)
        return spaceNavigation.openedIndexEntries[kind]
    }


    var openedAlbum: PhotoCollectionDescriptor? {
        get { state.openedAlbum }
        set { objectWillChange.send(); state.openedAlbum = newValue; save() }
    }

    /// Clears a nested album destination only after an authoritative list proves
    /// that it no longer exists. Returns true when persisted state changed.
    @discardableResult
    func clearOpenedAlbumIfMissing(in albums: [AlbumSummary], verified: Bool) -> Bool {
        guard verified, let collection = state.openedAlbum,
              !albums.contains(where: { $0.collection == collection }) else { return false }
        objectWillChange.send()
        state.openedAlbum = nil
        if case .album = state.sidebarSelection { state.sidebarSelection = .destination(.albums) }
        save()
        return true
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
