import Foundation
import SynologyAPI

/// Presentation preferences belong to one account on one server, not to album data.
@MainActor
final class AlbumPresentationStore: ObservableObject {
    private struct State: Codable {
        var version = 1
        var pinnedIDs: [Int64] = []
    }
    @Published private(set) var pinnedIDs: [Int64] = []
    private let defaults: UserDefaults
    private var key: String?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func configure(namespace: String) {
        let newKey = "albumPresentation.\(namespace)"
        guard key != newKey else { return }
        key = newKey
        if let data = defaults.data(forKey: newKey),
           let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1,
           Set(state.pinnedIDs).count == state.pinnedIDs.count {
            pinnedIDs = state.pinnedIDs
        } else {
            pinnedIDs = []
            defaults.removeObject(forKey: newKey)
        }
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
        guard let key, let data = try? JSONEncoder().encode(State(pinnedIDs: pinnedIDs)) else { return }
        defaults.set(data, forKey: key)
    }
}
