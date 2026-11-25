import Foundation
import Observation
import SynologyAPI

/// Menu, shortcut and drag additions to each album while they run and briefly after. While
/// several are queued for one album, successes are not shown and a failure is shown briefly
/// before the spinner returns; the last one to finish shows its result at once.
/// Kept apart from `LibraryModel` so only the sidebar rows that show it observe it.
@MainActor @Observable
final class AlbumAdditionStatusStore {
    enum Phase: Equatable { case running, succeeded, failed }
    private struct Entry {
        var running: Set<UUID> = []
        /// A failure shown while other additions still run.
        var failureFlash: UUID?
        /// The result shown after the last running addition finished.
        var result: (token: UUID, succeeded: Bool)?
        var isEmpty: Bool { running.isEmpty && failureFlash == nil && result == nil }
    }
    private var entries: [PhotoCollectionDescriptor: Entry] = [:]
    @ObservationIgnored var successDuration: Duration = .seconds(1.5)
    @ObservationIgnored var failureDuration: Duration = .seconds(4)

    func phase(for collection: PhotoCollectionDescriptor) -> Phase? {
        guard let entry = entries[collection] else { return nil }
        if entry.failureFlash != nil { return .failed }
        if !entry.running.isEmpty { return .running }
        return entry.result.map { $0.succeeded ? .succeeded : .failed }
    }

    func begin(_ collection: PhotoCollectionDescriptor) -> UUID {
        let id = UUID()
        var entry = entries[collection] ?? Entry()
        entry.running.insert(id)
        entry.result = nil
        entries[collection] = entry
        return id
    }

    func finish(_ collection: PhotoCollectionDescriptor, id: UUID, succeeded: Bool) {
        guard var entry = entries[collection], entry.running.remove(id) != nil else { return }
        let token = UUID()
        if !entry.running.isEmpty {
            guard !succeeded else { entries[collection] = entry; return }
            entry.failureFlash = token
            entries[collection] = entry
            clear(collection, after: failureDuration) { entry in
                guard entry.failureFlash == token else { return false }
                entry.failureFlash = nil
                return true
            }
        } else {
            entry.failureFlash = nil
            entry.result = (token, succeeded)
            entries[collection] = entry
            clear(collection, after: succeeded ? successDuration : failureDuration) { entry in
                guard entry.result?.token == token else { return false }
                entry.result = nil
                return true
            }
        }
    }

    /// Applies `update` after `delay`; it returns false when a newer state replaced this one.
    private func clear(_ collection: PhotoCollectionDescriptor, after delay: Duration, _ update: @escaping (inout Entry) -> Bool) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, var entry = self.entries[collection], update(&entry) else { return }
            self.entries[collection] = entry.isEmpty ? nil : entry
        }
    }
}
