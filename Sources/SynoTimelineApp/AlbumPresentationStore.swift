import Foundation
import SynologyAPI

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
        var sharedExpanded = false
        var albumsExpanded = false
        var sort: AlbumOverviewSort = .name
    }
    @Published private(set) var pinnedIDs: [Int64] = []
    @Published private(set) var sharedExpanded = false
    @Published private(set) var albumsExpanded = false
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
           Set(state.pinnedIDs).count == state.pinnedIDs.count {
            pinnedIDs = state.pinnedIDs
            sharedExpanded = state.sharedExpanded; albumsExpanded = state.albumsExpanded; sort = state.sort
        } else {
            pinnedIDs = []; sharedExpanded = false; albumsExpanded = false; sort = .name
            defaults.removeObject(forKey: newKey)
        }
    }

    func setExpanded(_ expanded: Bool, shared: Bool) {
        if shared { sharedExpanded = expanded } else { albumsExpanded = expanded }
        save()
    }
    func setSort(_ value: AlbumOverviewSort) { sort = value; save() }
    func section(_ albums: [AlbumSummary], shared: Bool) -> [AlbumSummary] {
        sort.sorted(albums.filter { $0.shared == shared })
    }
    func add(_ id: Int64) {
        guard key != nil, !pinnedIDs.contains(id) else { return }
        pinnedIDs.append(id); save()
    }
    func insert(_ id: Int64, before target: Int64?) {
        guard key != nil, target != id else { return }
        if let target, !pinnedIDs.contains(target) { return }
        var updated = pinnedIDs.filter { $0 != id }
        let index = target.flatMap { updated.firstIndex(of: $0) } ?? updated.endIndex
        updated.insert(id, at: index)
        guard updated != pinnedIDs else { return }
        pinnedIDs = updated; save()
    }
    func remove(_ id: Int64) {
        guard pinnedIDs.contains(id) else { return }
        pinnedIDs.removeAll { $0 == id }; save()
    }
    /// Moves an existing pin before another pin, or to the end when target is nil.
    func move(_ id: Int64, before target: Int64?) {
        guard pinnedIDs.contains(id), target != id else { return }
        if let target, !pinnedIDs.contains(target) { return }
        pinnedIDs.removeAll { $0 == id }
        let index = target.flatMap { pinnedIDs.firstIndex(of: $0) } ?? pinnedIDs.endIndex
        pinnedIDs.insert(id, at: index); save()
    }
    func reconcile(_ albums: [AlbumSummary], verified: Bool) {
        guard verified else { return }
        let available = Set(albums.map(\.id))
        let retained = pinnedIDs.filter { available.contains($0) }
        guard retained != pinnedIDs else { return }
        pinnedIDs = retained; save()
    }
    private func save() {
        guard let key, let data = try? JSONEncoder().encode(State(pinnedIDs: pinnedIDs, sharedExpanded: sharedExpanded, albumsExpanded: albumsExpanded, sort: sort)) else { return }
        defaults.set(data, forKey: key)
    }
}
