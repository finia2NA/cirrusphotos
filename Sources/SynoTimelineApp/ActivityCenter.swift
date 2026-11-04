import Foundation
import Observation
import PhotoCache
import SynologyAPI

enum ActivityTab: Hashable { case activity, history }

/// What an activity does. Equal values merge in History, so cases carry their target.
enum ActivityKind: Equatable, Sendable {
    case favorite(Bool)
    case rotate(PhotoRotationDirection)
    case rating(Int)
    case addTags([String]), removeTags([String]), newTag(String)
    case addToAlbum(id: Int64, name: String), addToIncomingAlbum(name: String)
    case createAlbum(name: String), removeFromAlbum(id: Int64, name: String), deleteAlbum(name: String)
    case deleteItems
    case download(name: String), editHandoff(name: String, application: String), filePromise(name: String)
    case upload(destination: String?)
    case renameAlbum(from: String, to: String), renamePerson(name: String)
    case mergePerson(source: String, target: String), albumSharing(name: String)
    /// A change that stopped before sending because its selection could not be verified.
    case unverified(action: String)
    /// A manual Refresh. Not a change, so it is never added to History.
    case refresh
    /// Information without an outcome, such as a lost connection.
    case notice(title: String)

    /// Transfers stay in the Activity tab after they finish, like a downloads list.
    var isTransfer: Bool {
        switch self {
        case .download, .editHandoff, .filePromise, .upload: true
        default: false
        }
    }

    /// Kinds whose newer action for a photo replaces an older failure for it.
    var supersedeFamily: SupersedeFamily? {
        switch self {
        case .favorite: .favorite
        case .rating: .rating
        default: nil
        }
    }

    /// Refresh and notices are not changes; History lists changes and transfers only.
    var recordsHistory: Bool {
        switch self {
        case .refresh, .notice: false
        default: true
        }
    }

    /// Counted bulk changes merge into the previous History record; named one-off actions do not.
    var mergesInHistory: Bool {
        switch self {
        case .favorite, .rotate, .rating, .addTags, .removeTags, .newTag, .addToAlbum, .addToIncomingAlbum,
             .removeFromAlbum, .deleteItems: true
        default: false
        }
    }
}

enum SupersedeFamily: Hashable, Sendable { case favorite, rating }

/// A photo or file an activity affects.
struct ActivityItem: Identifiable, Sendable {
    enum Reference: Sendable {
        case photo(PhotoItem, collection: PhotoCollectionDescriptor)
        case file(URL)
    }

    let reference: Reference
    /// A per-item failure message, for example one upload's error.
    var message: String?

    init(photo: PhotoItem, collection: PhotoCollectionDescriptor) { reference = .photo(photo, collection: collection) }
    init(file: URL) { reference = .file(file) }

    var id: String {
        switch reference {
        case .photo(let photo, _): "photo:\(photo.id)"
        case .file(let url): "file:\(url.path)"
        }
    }

    var name: String {
        switch reference {
        case .photo(let photo, _): photo.filename ?? "Photo"
        case .file(let url): url.lastPathComponent
        }
    }

    var photoID: Int64? {
        if case .photo(let photo, _) = reference { return photo.id }
        return nil
    }

    var fileURL: URL? {
        if case .file(let url) = reference { return url }
        return nil
    }
}

enum ActivityPhase: Equatable, Sendable {
    case queued, running, succeeded, failed, unconfirmed, cancelled
    var isSettled: Bool { self != .queued && self != .running }
    var needsAttention: Bool { self == .failed || self == .unconfirmed }
}

/// What the user sees for a failure, plus what a copied report needs.
struct ActivityFailure: Sendable {
    let message: String
    let operation: String
    let errorKind: String
    /// The error and what it wraps, one line per level, for a copied report.
    let underlying: [String]
    let date: Date
    let unconfirmed: Bool

    /// Describes an error without logging it.
    init(error: any Error, operation: String, date: Date = Date()) {
        self.init(RepositoryError(error), original: error, operation: operation, date: date)
    }

    /// Logs the error through `RepositoryError.record`, as every failure the app shows is logged.
    static func recorded(_ error: any Error, operation: String, date: Date = Date()) -> ActivityFailure {
        ActivityFailure(RepositoryError.record(error, operation: operation), original: error, operation: operation, date: date)
    }

    private init(_ error: RepositoryError, original: any Error, operation: String, date: Date) {
        message = error.localizedDescription
        self.operation = operation
        errorKind = error.kindName
        underlying = Self.chain(original)
        self.date = date
        if case .unconfirmed = error { unconfirmed = true } else { unconfirmed = false }
    }

    /// Error types and codes, outermost first. Messages are left out: the user-facing one is
    /// reported separately, and server text can carry request details.
    static func chain(_ error: any Error, depth: Int = 0) -> [String] {
        guard depth < 5 else { return [] }
        switch error {
        case let error as BatchFavoriteError:
            return ["BatchFavoriteError(succeeded: \(error.outcome.successfulCount), failed: \(error.outcome.failedCount))"]
                + chain(error.underlyingError, depth: depth + 1)
        case let error as RepositoryError:
            if case .server(let server) = error { return ["RepositoryError.server", "SynologyAPIError.\(server.diagnosticCode)"] }
            return ["RepositoryError.\(error.kindName)"]
        case let error as SynologyAPIError:
            return ["SynologyAPIError.\(error.diagnosticCode)"]
        case let error as URLError:
            return ["URLError(\(error.code.rawValue))"]
        case is CancellationError:
            return ["CancellationError"]
        default:
            let error = error as NSError
            let line = "\(String(reflecting: type(of: error as Any))) \(error.domain)(\(error.code))"
            guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error else { return [line] }
            return [line] + chain(underlying, depth: depth + 1)
        }
    }
}

/// Starts a new tracked activity for the given items. Returns false when it could not start,
/// for example while another upload runs; the items then stay in the failed entry.
typealias ActivityRetry = @MainActor ([ActivityItem]) -> Bool

struct ActivityEntry: Identifiable {
    let id: UUID
    var kind: ActivityKind
    let startedAt: Date
    var phase: ActivityPhase
    var items: [ActivityItem]
    var totalCount: Int
    var completedCount = 0
    /// Byte progress of a transfer.
    var fraction: Double?
    var status: String?
    var failure: ActivityFailure?
    var failedItems: [ActivityItem] = []
    var savedURL: URL?
    var finishedAt: Date?
    var cancel: (@MainActor () -> Void)?
    var retry: ActivityRetry?
    /// A newer notice with the same key replaces this one.
    var noticeKey: String?
}

enum HistoryOutcome: Equatable, Sendable {
    case succeeded, partial(failed: Int), failed, unconfirmed, cancelled
}

struct HistoryRecord: Identifiable {
    let id = UUID()
    let kind: ActivityKind
    var outcome: HistoryOutcome
    /// Succeeded items, or the attempted count when nothing succeeded.
    var count: Int
    var items: [ActivityItem]
    var finishedAt: Date
    var failure: ActivityFailure?
}

/// The producer's side of one activity. Every call is ignored once the activity settled.
@MainActor
final class ActivityHandle {
    let id: UUID
    private weak var center: ActivityCenter?

    init(id: UUID, center: ActivityCenter) {
        self.id = id
        self.center = center
    }

    func start() { center?.update(id) { if $0.phase == .queued { $0.phase = .running } } }
    func progress(completed: Int) { center?.update(id) { $0.completedCount = min(max(completed, 0), $0.totalCount) } }
    func progress(fraction: Double?) { center?.update(id) { $0.fraction = fraction } }
    func status(_ text: String?) { center?.update(id) { $0.status = text } }
    /// Replaces the kind, for example once a download's name is known.
    func rename(_ kind: ActivityKind) { center?.update(id) { $0.kind = kind } }
    /// Sets the items once they are resolved.
    func setItems(_ items: [ActivityItem]) {
        center?.update(id) {
            $0.items = items
            $0.totalCount = max(items.count, 1)
        }
    }
    func setRetry(_ retry: ActivityRetry?) { center?.update(id) { $0.retry = retry } }
    /// Removes the activity without a History record, for work that turned out to be a no-op.
    func discard() { center?.discard(id) }
    func succeed(savedURL: URL? = nil) { center?.succeed(id, savedURL: savedURL) }
    /// Settles as failed, or as unconfirmed for `RepositoryError.unconfirmed`; cancellation settles
    /// as cancelled. `failedItems` nil means every item failed. Returns the user-facing message.
    @discardableResult
    func fail(_ error: any Error, operation: String, failedItems: [ActivityItem]? = nil,
              note: String? = nil, logs: Bool = true) -> String {
        center?.fail(id, error: error, operation: operation, failedItems: failedItems, note: note, logs: logs)
            ?? RepositoryError(error).localizedDescription
    }
    func cancelled() { center?.cancelled(id) }
}

/// Session-only record of running work, failures and settled user-initiated changes.
/// Call sites begin an activity and settle it through the returned handle.
@MainActor @Observable
final class ActivityCenter {
    static let shared = ActivityCenter()
    static let historyLimit = 500
    static let settledEntryLimit = 200
    static let mergeWindow: TimeInterval = 60
    static let autoPresentInterval: TimeInterval = 10
    static let highlightDuration: Duration = .milliseconds(1500)

    /// Newest first.
    private(set) var entries: [ActivityEntry] = []
    /// Newest first.
    private(set) var history: [HistoryRecord] = []
    var isPresented = false
    var selectedTab: ActivityTab = .activity
    private(set) var highlightedEntryID: UUID?
    private(set) var unseenFailureIDs: Set<UUID> = []
    /// False while the toolbar that anchors the panel is hidden.
    var canAutoPresent = true

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastAutoPresent: Date?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    // MARK: Sections

    var attention: [ActivityEntry] { entries.filter { $0.phase.needsAttention } }
    var notices: [ActivityEntry] { entries.filter { $0.noticeKey != nil } }
    var transfers: [ActivityEntry] { entries.filter { $0.kind.isTransfer && !$0.phase.needsAttention } }
    var inProgress: [ActivityEntry] { entries.filter { !$0.kind.isTransfer && !$0.phase.isSettled } }
    var runningCount: Int { entries.count { !$0.phase.isSettled } }
    /// Set by `LibraryModel`: false after a lost connection, when load failures are expected.
    var connectionIsHealthy = true
    /// The collection the main browser shows, when a photo of it can be revealed there.
    var revealableCollection: PhotoCollectionDescriptor?
    @ObservationIgnored var revealHandler: (@MainActor (PhotoItem, PhotoCollectionDescriptor) -> Void)?
    var hasSettledEntries: Bool { entries.contains { $0.phase.isSettled } }
    var hasRetryableFailures: Bool { entries.contains { $0.phase.needsAttention && $0.retry != nil } }

    /// The byte progress when exactly one transfer runs and reports it.
    var singleTransferFraction: Double? {
        let running = entries.filter { $0.kind.isTransfer && !$0.phase.isSettled }
        return running.count == 1 ? running[0].fraction : nil
    }

    // MARK: Producers

    @discardableResult
    func begin(_ kind: ActivityKind, items: [ActivityItem] = [], totalCount: Int? = nil, queued: Bool = false,
               id: UUID = UUID(), cancel: (@MainActor () -> Void)? = nil, retry: ActivityRetry? = nil) -> ActivityHandle {
        if let family = kind.supersedeFamily {
            supersede(family, photoIDs: Set(items.compactMap(\.photoID)))
        }
        let entry = ActivityEntry(id: id, kind: kind, startedAt: now(), phase: queued ? .queued : .running,
                                  items: items, totalCount: totalCount ?? max(items.count, 1),
                                  cancel: cancel, retry: retry)
        entries.insert(entry, at: 0)
        return ActivityHandle(id: id, center: self)
    }

    /// Adds a settled change to History only, for sheets that show their own result.
    func record(_ kind: ActivityKind, outcome: HistoryOutcome, items: [ActivityItem] = [], failure: ActivityFailure? = nil) {
        appendHistory(HistoryRecord(kind: kind, outcome: outcome, count: max(items.count, 1), items: items,
                                    finishedAt: now(), failure: failure))
    }

    func update(_ id: UUID, _ change: (inout ActivityEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].phase.isSettled else { return }
        change(&entries[index])
    }

    func discard(_ id: UUID) {
        entries.removeAll { $0.id == id && !$0.phase.isSettled }
    }

    func succeed(_ id: UUID, savedURL: URL?) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].phase.isSettled else { return }
        var entry = entries[index]
        entry.phase = .succeeded
        entry.finishedAt = now()
        entry.completedCount = entry.totalCount
        entry.savedURL = savedURL
        entry.cancel = nil
        if entry.kind.isTransfer {
            entry.fraction = 1
            entries[index] = entry
            trimSettledEntries()
        } else {
            entries.remove(at: index)
        }
        guard entry.kind.recordsHistory else { return }
        appendHistory(HistoryRecord(kind: entry.kind, outcome: .succeeded, count: entry.totalCount, items: entry.items,
                                    finishedAt: entry.finishedAt ?? now()))
    }

    func fail(_ id: UUID, error: any Error, operation: String, failedItems: [ActivityItem]?,
              note: String?, logs: Bool) -> String {
        if error is CancellationError {
            cancelled(id)
            return "Cancelled"
        }
        let failure = logs ? ActivityFailure.recorded(error, operation: operation, date: now())
                           : ActivityFailure(error: error, operation: operation, date: now())
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].phase.isSettled else {
            return failure.message
        }
        var entry = entries[index]
        let failed = failedItems ?? entry.items
        let failedIDs = Set(failed.map(\.id))
        let succeeded = entry.items.filter { !failedIDs.contains($0.id) }
        entry.phase = failure.unconfirmed ? .unconfirmed : .failed
        entry.failure = failure
        entry.failedItems = failed
        entry.finishedAt = now()
        entry.cancel = nil
        entry.status = note
        entries[index] = entry
        let finishedAt = entry.finishedAt ?? now()
        if !entry.kind.recordsHistory {
            // Not a change: nothing to add to History.
        } else if failedItems != nil, !failed.isEmpty, !succeeded.isEmpty {
            appendHistory(HistoryRecord(kind: entry.kind, outcome: .partial(failed: failed.count),
                                        count: max(entry.totalCount - failed.count, succeeded.count),
                                        items: succeeded, finishedAt: finishedAt, failure: failure))
        } else {
            appendHistory(HistoryRecord(kind: entry.kind, outcome: failure.unconfirmed ? .unconfirmed : .failed,
                                        count: entry.totalCount, items: entry.items, finishedAt: finishedAt,
                                        failure: failure))
        }
        trimSettledEntries()
        requestAttention(id)
        return failure.message
    }

    func cancelled(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].phase.isSettled else { return }
        var entry = entries[index]
        entry.phase = .cancelled
        entry.finishedAt = now()
        entry.cancel = nil
        if entry.status == nil { entry.status = "Cancelled" }
        if entry.kind.isTransfer {
            entries[index] = entry
            trimSettledEntries()
        } else {
            entries.remove(at: index)
        }
        guard entry.kind.recordsHistory else { return }
        appendHistory(HistoryRecord(kind: entry.kind, outcome: .cancelled, count: entry.totalCount, items: entry.items,
                                    finishedAt: entry.finishedAt ?? now()))
    }

    /// Shows information in the Notices section. It never opens the panel or enters History;
    /// a notice with the same key replaces the previous one.
    func notice(_ title: String, detail: String? = nil, key: String) {
        entries.removeAll { $0.noticeKey == key }
        var entry = ActivityEntry(id: UUID(), kind: .notice(title: title), startedAt: now(), phase: .succeeded,
                                  items: [], totalCount: 1)
        entry.status = detail
        entry.finishedAt = entry.startedAt
        entry.noticeKey = key
        entries.insert(entry, at: 0)
        trimSettledEntries()
    }

    /// Removes earlier failures of a kind once a later attempt succeeded, such as a Refresh.
    func resolveFailures(of kind: ActivityKind) {
        let resolved = entries.filter { $0.kind == kind && $0.phase.needsAttention }.map(\.id)
        entries.removeAll { resolved.contains($0.id) }
        unseenFailureIDs.subtract(resolved)
    }

    func canReveal(_ item: ActivityItem) -> Bool {
        guard case .photo(_, let collection) = item.reference else { return false }
        return revealHandler != nil && collection == revealableCollection
    }

    /// Scrolls the main browser to the photo and selects it.
    func reveal(_ item: ActivityItem) {
        guard canReveal(item), case .photo(let photo, let collection) = item.reference else { return }
        revealHandler?(photo, collection)
    }

    // MARK: User actions

    func dismiss(_ id: UUID) {
        entries.removeAll { $0.id == id && $0.phase.isSettled }
        unseenFailureIDs.remove(id)
    }

    /// Removes one failed item; the entry goes away with its last one.
    func dismiss(itemID: String, from entryID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].failedItems.removeAll { $0.id == itemID }
        if entries[index].failedItems.isEmpty { dismiss(entryID) }
    }

    func dismissHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
    }

    /// Removes everything settled; running and queued work stays.
    func clearActivity() {
        entries.removeAll { $0.phase.isSettled }
        unseenFailureIDs.formIntersection(entries.map(\.id))
    }

    func clearHistory() {
        history.removeAll()
    }

    /// Retries the given failed items, or all of them when `itemIDs` is nil.
    func retry(_ entryID: UUID, itemIDs: Set<String>? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
              entries[index].phase.needsAttention, let retry = entries[index].retry else { return }
        let original = entries[index]
        let chosen = original.failedItems.filter { itemIDs?.contains($0.id) ?? true }
        let remaining = original.failedItems.filter { !(itemIDs?.contains($0.id) ?? true) }
        if remaining.isEmpty {
            entries.remove(at: index)
            unseenFailureIDs.remove(entryID)
        } else {
            entries[index].failedItems = remaining
        }
        guard !retry(chosen) else { return }
        if let current = entries.firstIndex(where: { $0.id == entryID }) {
            entries[current].failedItems = original.failedItems
        } else {
            entries.insert(original, at: min(index, entries.count))
        }
    }

    func retryAllFailed() {
        for id in entries.filter({ $0.phase.needsAttention && $0.retry != nil }).map(\.id) {
            retry(id)
        }
    }

    func markFailuresSeen() {
        if !unseenFailureIDs.isEmpty { unseenFailureIDs.removeAll() }
    }

    func present(highlighting entryID: UUID? = nil) {
        selectedTab = .activity
        isPresented = true
        if let entryID { highlight(entryID) }
    }

    func togglePresented() {
        if isPresented { isPresented = false } else { present() }
    }

    /// A newer action for these photos replaces their older failures of the same family.
    func supersede(_ family: SupersedeFamily, photoIDs: Set<Int64>) {
        guard !photoIDs.isEmpty else { return }
        for index in entries.indices.reversed() {
            let entry = entries[index]
            guard entry.phase.needsAttention, entry.kind.supersedeFamily == family, !entry.failedItems.isEmpty else { continue }
            entries[index].failedItems.removeAll { $0.photoID.map(photoIDs.contains) ?? false }
            if entries[index].failedItems.isEmpty {
                entries.remove(at: index)
                unseenFailureIDs.remove(entry.id)
            }
        }
    }

    // MARK: Private

    private func requestAttention(_ id: UUID) {
        unseenFailureIDs.insert(id)
        if isPresented {
            highlight(id)
            return
        }
        guard canAutoPresent else { return }
        let date = now()
        if let lastAutoPresent, date.timeIntervalSince(lastAutoPresent) < Self.autoPresentInterval { return }
        lastAutoPresent = date
        present(highlighting: id)
    }

    private func highlight(_ id: UUID) {
        highlightedEntryID = id
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: Self.highlightDuration)
            guard !Task.isCancelled, let self, self.highlightedEntryID == id else { return }
            self.highlightedEntryID = nil
        }
    }

    private func appendHistory(_ record: HistoryRecord) {
        if let newest = history.first, record.outcome == .succeeded, newest.outcome == .succeeded,
           record.kind.mergesInHistory, newest.kind == record.kind,
           record.finishedAt.timeIntervalSince(newest.finishedAt) <= Self.mergeWindow {
            history[0].count += record.count
            history[0].items += record.items
            history[0].finishedAt = record.finishedAt
            return
        }
        history.insert(record, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    private func trimSettledEntries() {
        var settled = entries.count { $0.phase.isSettled }
        guard settled > Self.settledEntryLimit else { return }
        for index in entries.indices.reversed() where settled > Self.settledEntryLimit && entries[index].phase.isSettled {
            unseenFailureIDs.remove(entries[index].id)
            entries.remove(at: index)
            settled -= 1
        }
    }
}
