import Foundation
import SynologyAPI

enum AlbumOverviewSection: CaseIterable {
    case albums, shared, incoming

    var title: String {
        switch self { case .albums: "Albums"; case .shared: "Shared Albums"; case .incoming: "Shared with me" }
    }
    func contains(_ album: AlbumSummary) -> Bool {
        switch self {
        case .albums: !album.isIncoming && !album.shared
        case .shared: !album.isIncoming && album.shared
        case .incoming: album.isIncoming
        }
    }
}

enum AlbumOverviewSort: String, Codable, CaseIterable {
    case name, newest, oldest
    var title: String {
        switch self { case .name: "Name"; case .newest: "Newest"; case .oldest: "Oldest" }
    }
    func sorted(_ albums: [AlbumSummary]) -> [AlbumSummary] {
        albums.sorted { a, b in
            if self != .name, a.createTime != b.createTime {
                guard let left = a.createTime else { return false }
                guard let right = b.createTime else { return true }
                return self == .newest ? left > right : left < right
            }
            let result = a.name.localizedStandardCompare(b.name)
            return result == .orderedSame ? a.id < b.id : result == .orderedAscending
        }
    }
}

/// Presentation preferences belong to one account on one server, not to album data.
@MainActor
final class AlbumPresentationStore: ObservableObject {
    private struct State: Codable {
        var version = 2
        var pinnedIDs: [Int64] = []
        var pinnedCollections: [PhotoCollectionDescriptor]? = nil
        var sharedExpanded = false
        var albumsExpanded = false
        var incomingExpanded: Bool? = nil
        var sort: AlbumOverviewSort = .name
    }
    @Published private(set) var pinnedCollections: [PhotoCollectionDescriptor] = []
    var pinnedIDs: [Int64] { pinnedCollections.compactMap(\.albumID) }
    @Published private(set) var sharedExpanded = false
    @Published private(set) var albumsExpanded = false
    @Published private(set) var incomingExpanded = false
    @Published private(set) var sort: AlbumOverviewSort = .name
    private let defaults: UserDefaults
    private var key: String?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func configure(namespace: String) {
        let newKey = "albumPresentation.\(namespace)"
        guard key != newKey else { return }
        key = newKey
        if let data = defaults.data(forKey: newKey),
           let state = try? JSONDecoder().decode(State.self, from: data), state.version == 2,
           Set(state.pinnedCollections ?? state.pinnedIDs.map { .album($0) }).count == (state.pinnedCollections?.count ?? state.pinnedIDs.count) {
            pinnedCollections = state.pinnedCollections ?? state.pinnedIDs.map { .album($0) }
            sharedExpanded = state.sharedExpanded; albumsExpanded = state.albumsExpanded; incomingExpanded = state.incomingExpanded ?? false; sort = state.sort
        } else {
            pinnedCollections = []; sharedExpanded = false; albumsExpanded = false; incomingExpanded = false; sort = .name
            defaults.removeObject(forKey: newKey)
        }
    }

    func expanded(_ section: AlbumOverviewSection) -> Bool {
        switch section { case .albums: albumsExpanded; case .shared: sharedExpanded; case .incoming: incomingExpanded }
    }
    func setExpanded(_ expanded: Bool, section: AlbumOverviewSection) {
        switch section { case .albums: albumsExpanded = expanded; case .shared: sharedExpanded = expanded; case .incoming: incomingExpanded = expanded }
        save()
    }
    func section(_ albums: [AlbumSummary], section: AlbumOverviewSection) -> [AlbumSummary] {
        sort.sorted(albums.filter(section.contains))
    }
    func setSort(_ value: AlbumOverviewSort) { sort = value; save() }
    func add(_ collection: PhotoCollectionDescriptor) {
        guard key != nil, !pinnedCollections.contains(collection) else { return }
        pinnedCollections.append(collection); save()
    }
    func insert(_ collection: PhotoCollectionDescriptor, before target: PhotoCollectionDescriptor?) {
        guard key != nil, target != collection else { return }
        if let target, !pinnedCollections.contains(target) { return }
        var updated = pinnedCollections.filter { $0 != collection }
        let index = target.flatMap { updated.firstIndex(of: $0) } ?? updated.endIndex
        updated.insert(collection, at: index)
        guard updated != pinnedCollections else { return }
        pinnedCollections = updated; save()
    }
    func remove(_ collection: PhotoCollectionDescriptor) {
        guard pinnedCollections.contains(collection) else { return }
        pinnedCollections.removeAll { $0 == collection }; save()
    }
    func move(_ collection: PhotoCollectionDescriptor, before target: PhotoCollectionDescriptor?) {
        guard pinnedCollections.contains(collection) else { return }
        insert(collection, before: target)
    }
    func reconcile(_ albums: [AlbumSummary], verified: Bool) {
        guard verified else { return }
        let available = Set(albums.compactMap(\.collection))
        let retained = pinnedCollections.filter { available.contains($0) }
        guard retained != pinnedCollections else { return }
        pinnedCollections = retained; save()
    }
    private func save() {
        guard let key, let data = try? JSONEncoder().encode(State(pinnedIDs: pinnedIDs, pinnedCollections: pinnedCollections, sharedExpanded: sharedExpanded, albumsExpanded: albumsExpanded, incomingExpanded: incomingExpanded, sort: sort)) else { return }
        defaults.set(data, forKey: key)
    }
}
