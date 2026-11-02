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
    case personalLibrary, favorites, albums, map, people, subjects, tags
}

enum SidebarSelection: Codable, Hashable {
    case destination(LibraryDestination)
    case album(PhotoCollectionDescriptor)

    var destination: LibraryDestination {
        switch self { case .destination(let destination): destination; case .album: .albums }
    }
}

struct RestorableAppNavigationState: Codable, Equatable {
    static let currentVersion = 6

    var version = currentVersion
    var sidebarSelection: SidebarSelection = .destination(.personalLibrary)
    var openedAlbum: PhotoCollectionDescriptor?
    var openedPersonID: Int64?
    var personNamespace: String?
    var openedSubjectID: Int64?
    var subjectNamespace: String?
    var openedTagID: Int64?
    var tagNamespace: String?
    var showsFolders = false
    var folderPath: [Int64] = []
    var folderNamespace: String?
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

    var showsFolders: Bool { state.showsFolders }
    var folderPath: [Int64] { state.folderPath }
    func prepareFolders(namespace: String) -> [Int64] {
        if state.folderNamespace != namespace { state.folderPath = []; state.folderNamespace = namespace; save() }
        return state.folderPath
    }
    func setFolders(shown: Bool, path: [Int64]) { state.showsFolders = shown; state.folderPath = path; save() }

    func preparePerson(namespace: String) -> Int64? {
        if state.personNamespace != namespace { state.openedPersonID = nil; state.personNamespace = namespace; save() }
        return state.openedPersonID
    }
    func setOpenedPerson(_ id: Int64?) { state.openedPersonID = id; save() }

    func prepareSubject(namespace: String) -> Int64? {
        if state.subjectNamespace != namespace { state.openedSubjectID = nil; state.subjectNamespace = namespace; save() }
        return state.openedSubjectID
    }
    func setOpenedSubject(_ id: Int64?) { state.openedSubjectID = id; save() }

    func prepareTag(namespace: String) -> Int64? {
        if state.tagNamespace != namespace { state.openedTagID = nil; state.tagNamespace = namespace; save() }
        return state.openedTagID
    }
    func setOpenedTag(_ id: Int64?) { state.openedTagID = id; save() }

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
