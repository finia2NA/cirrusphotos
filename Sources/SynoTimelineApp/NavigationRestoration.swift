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
    var openedPersonID: Int64?
    var openedSubjectID: Int64?
    var openedTagID: Int64?
    var showsFolders = false
    var folderPath: [Int64] = []
}

struct RestorableAppNavigationState: Codable, Equatable {
    static let currentVersion = 9

    var version = currentVersion
    var sidebarSelection: SidebarSelection = .destination(.personalLibrary)
    var openedAlbum: PhotoCollectionDescriptor?
    var selectedSpace: PhotoSpace = .personal
    var spaces: [PhotoSpace: RestorableSpaceNavigation] = [:]
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
        state.sidebarSelection.destination
    }

    var sidebarSelection: SidebarSelection { state.sidebarSelection }

    var selectedSpace: PhotoSpace { state.selectedSpace }
    func selectSpace(_ space: PhotoSpace) { state.selectedSpace = space; save() }

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
        updateSpaceNavigation { navigation in
            navigation = RestorableSpaceNavigation(namespace: namespace, showsFolders: navigation.showsFolders)
        }
    }

    var showsFolders: Bool { spaceNavigation.showsFolders }
    var folderPath: [Int64] { spaceNavigation.folderPath }
    func prepareFolders(namespace: String) -> [Int64] {
        prepareSpace(namespace: namespace)
        return folderPath
    }
    func setFolders(shown: Bool, path: [Int64]) {
        updateSpaceNavigation { $0.showsFolders = shown; $0.folderPath = path }
    }
    func preparePerson(namespace: String) -> Int64? {
        prepareSpace(namespace: namespace)
        return spaceNavigation.openedPersonID
    }
    func setOpenedPerson(_ id: Int64?) { updateSpaceNavigation { $0.openedPersonID = id } }
    func prepareSubject(namespace: String) -> Int64? {
        prepareSpace(namespace: namespace)
        return spaceNavigation.openedSubjectID
    }
    func setOpenedSubject(_ id: Int64?) { updateSpaceNavigation { $0.openedSubjectID = id } }
    func prepareTag(namespace: String) -> Int64? {
        prepareSpace(namespace: namespace)
        return spaceNavigation.openedTagID
    }
    func setOpenedTag(_ id: Int64?) { updateSpaceNavigation { $0.openedTagID = id } }

    var openedAlbum: PhotoCollectionDescriptor? {
        state.openedAlbum
    }

    func selectSidebar(_ selection: SidebarSelection) {
        state.sidebarSelection = selection
        save()
    }

    func setOpenedAlbum(_ collection: PhotoCollectionDescriptor?) {
        state.openedAlbum = collection
        save()
    }

    /// Clears a nested album destination only after an authoritative list proves
    /// that it no longer exists. Returns true when persisted state changed.
    @discardableResult
    func clearOpenedAlbumIfMissing(in albums: [AlbumSummary], verified: Bool) -> Bool {
        guard verified, let collection = state.openedAlbum,
              !albums.contains(where: { $0.collection == collection }) else { return false }
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
