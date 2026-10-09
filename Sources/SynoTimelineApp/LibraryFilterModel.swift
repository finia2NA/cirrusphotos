import Foundation
import PhotoCache
import SynologyAPI

@MainActor
final class LibraryFilterModel: ObservableObject {
    enum SizeUnit: String, CaseIterable, Identifiable { case KB, MB, GB; var id: String { rawValue } }

    @Published var isPresented = false
    @Published var draft = LibraryFilter()
    @Published private(set) var committed = LibraryFilter()
    @Published private(set) var catalog = LibraryFilterCatalog()
    @Published private(set) var progress = TimelineSectionLoadProgress(
        total: 0, processed: 0, verified: 0, provisional: 0, failed: 0, remaining: 0,
        currentSectionLabel: nil, matchCount: nil, state: .idle, failures: [])
    @Published private(set) var activeCollection: PhotoCollectionDescriptor?
    @Published private(set) var validationErrors: [String: String] = [:]
    @Published var megapixelsMin = ""; @Published var megapixelsMax = ""
    @Published var sizeMin = ""; @Published var sizeMax = ""
    @Published var sizeMinUnit: SizeUnit = .MB; @Published var sizeMaxUnit: SizeUnit = .MB
    @Published var isoMin = ""; @Published var isoMax = ""
    @Published var focalMin = ""; @Published var focalMax = ""
    @Published var apertureMin = ""; @Published var apertureMax = ""
    @Published var shutterMin = ""; @Published var shutterMax = ""

    private weak var library: LibraryModel?
    private var controller: LibraryFilterController?
    private var observer: Task<Void, Never>?
    private var fingerprint: String?
    private var lastTailDemandProcessed = -1
    private var installedRegistration: LibraryFilterRegistration?
    private var installingRegistration: LibraryFilterRegistration?

    var isActive: Bool { activeCollection != nil }
    var isReady: Bool { controller != nil }
    var activeCount: Int { committed.activeCriterionCount }
    var canApply: Bool { validateFields().isEmpty }
    var coverageText: String {
        if progress.total > 0 && progress.verified == progress.total { return "All \(progress.total) sections loaded" }
        return "Options from \(progress.processed) of \(progress.total) sections"
    }
    var statusText: String {
        let matches = progress.matchCount ?? 0
        return "\(matches) Matches · \(progress.processed)/\(progress.total) Sections"
    }

    func configure(library: LibraryModel) {
        self.library = library
        guard let snapshot = library.snapshot, library.timelineVerified, let repository = library.repository else { return }
        let next = LibraryIndex(snapshot: snapshot).fingerprint
        guard fingerprint != next else { return }
        observer?.cancel()
        clear()
        fingerprint = next
        let controller = LibraryFilterController(repository: repository, snapshot: snapshot)
        self.controller = controller
        observer = Task { [weak self] in
            for await event in await controller.observe() {
                guard !Task.isCancelled else { return }
                await self?.receive(event)
            }
        }
    }

    func ingest(sectionIndex: Int, items: [PhotoItem], verified: Bool) {
        guard let controller else { return }
        Task { await controller.ingest(sectionIndex: sectionIndex, items: items, verified: verified) }
    }

    func apply() {
        validationErrors = validateFields()
        guard validationErrors.isEmpty else { return }
        guard let controller else {
            validationErrors["Library"] = "Library metadata is still loading."
            return
        }
        var filter = draft
        filter.megapixels = range(megapixelsMin, megapixelsMax, parser: parsePositive)
        filter.bytes = byteRange()
        filter.iso = range(isoMin, isoMax, parser: parsePositiveInteger)
        filter.focalLengthMM = range(focalMin, focalMax, parser: parsePositive)
        filter.aperture = range(apertureMin, apertureMax, parser: parseAperture)
        filter.exposureSeconds = range(shutterMin, shutterMax, parser: parseShutter)
        if filter.isEmpty { clear(); isPresented = false; return }
        committed = filter
        isPresented = false
        Task {
            let registration = await controller.apply(filter)
            await install(registration)
            await controller.loadNextBatch()
        }
    }

    func clear() {
        if let descriptor = activeCollection, let repository = library?.repository {
            Task { await repository.unregisterLibraryFilter(descriptor) }
            library?.unregisterSessionCollection(descriptor)
        }
        activeCollection = nil
        committed = LibraryFilter()
        draft = LibraryFilter()
        megapixelsMin = ""; megapixelsMax = ""; sizeMin = ""; sizeMax = ""
        isoMin = ""; isoMax = ""; focalMin = ""; focalMax = ""
        apertureMin = ""; apertureMax = ""; shutterMin = ""; shutterMax = ""
        sizeMinUnit = .MB; sizeMaxUnit = .MB
        validationErrors = [:]
        installedRegistration = nil
        installingRegistration = nil
        let currentController = controller
        Task { await currentController?.unregisterFilter() }
    }

    func loadNext() { Task { await controller?.loadNextBatch() } }
    func loadNextIfNeeded() {
        guard progress.remaining > 0, progress.processed != lastTailDemandProcessed else { return }
        lastTailDemandProcessed = progress.processed
        loadNext()
    }
    func loadAll(useCachedPages: Bool = false) {
        Task { await controller?.loadAll(useCachedPages: useCachedPages) }
    }
    func cancel() { Task { await controller?.cancelScan() } }
    func retry() { Task { await controller?.retryFailed() } }

    private func receive(_ event: LibraryFilterControllerEvent) async {
        catalog = event.catalog
        progress = event.progress
        if let registration = event.registration, activeCollection == registration.descriptor {
            await install(registration)
        }
    }

    private func install(_ registration: LibraryFilterRegistration) async {
        guard let library, let repository = library.repository else { return }
        guard !registration.hasSameContent(as: installedRegistration),
              !registration.hasSameContent(as: installingRegistration) else { return }
        installingRegistration = registration
        defer {
            if registration.hasSameContent(as: installingRegistration) {
                installingRegistration = nil
            }
        }
        do {
            if activeCollection == registration.descriptor {
                try await repository.replaceLibraryFilterSnapshot(registration)
            } else {
                if let old = activeCollection {
                    await repository.unregisterLibraryFilter(old)
                    library.unregisterSessionCollection(old)
                }
                try await repository.registerLibraryFilter(registration)
                activeCollection = registration.descriptor
            }
            library.registerSessionCollection(registration.descriptor, snapshot: registration.snapshot)
            installedRegistration = registration
        } catch {
            validationErrors["scan"] = error.localizedDescription
        }
    }

    private func validateFields() -> [String: String] {
        var errors: [String: String] = [:]
        validate("Megapixels", megapixelsMin, megapixelsMax, parser: parsePositive, into: &errors)
        validate("Size", sizeMin, sizeMax, parser: parsePositive, into: &errors)
        validate("ISO", isoMin, isoMax, parser: parsePositiveInteger, into: &errors)
        validate("Focal Length", focalMin, focalMax, parser: parsePositive, into: &errors)
        validate("Aperture", apertureMin, apertureMax, parser: parseAperture, into: &errors)
        validate("Shutter Speed", shutterMin, shutterMax, parser: parseShutter, into: &errors)
        return errors
    }

    private func validate(_ name: String, _ minimum: String, _ maximum: String,
                          parser: (String) -> Double?, into errors: inout [String: String]) {
        let min = minimum.isEmpty ? nil : parser(minimum), max = maximum.isEmpty ? nil : parser(maximum)
        if (!minimum.isEmpty && min == nil) || (!maximum.isEmpty && max == nil) { errors[name] = "Enter a positive number." }
        else if let min, let max, min > max { errors[name] = "Minimum must not exceed maximum." }
    }

    private func range(_ min: String, _ max: String,
                       parser: (String) -> Double?) -> OptionalNumericRange<Double> {
        .init(minimum: min.isEmpty ? nil : parser(min), maximum: max.isEmpty ? nil : parser(max))
    }
    private func byteRange() -> OptionalNumericRange<Int64> {
        func value(_ text: String, _ unit: SizeUnit) -> Int64? {
            guard let number = parsePositive(text) else { return nil }
            let multiplier: Double = unit == .KB ? 1_000 : unit == .MB ? 1_000_000 : 1_000_000_000
            let result = number * multiplier
            return result <= Double(Int64.max) ? Int64(result.rounded()) : nil
        }
        return .init(minimum: sizeMin.isEmpty ? nil : value(sizeMin, sizeMinUnit),
                     maximum: sizeMax.isEmpty ? nil : value(sizeMax, sizeMaxUnit))
    }
    private func parsePositive(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite, value > 0 else { return nil }
        return value
    }
    private func parsePositiveInteger(_ text: String) -> Double? {
        guard let value = parsePositive(text), value.rounded() == value else { return nil }
        return value
    }
    private func parseAperture(_ text: String) -> Double? {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("f/") { text.removeFirst(2) } else if text.hasPrefix("f") { text.removeFirst() }
        return parsePositive(text)
    }
    private func parseShutter(_ text: String) -> Double? {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix("s") { text.removeLast(); text = text.trimmingCharacters(in: .whitespaces) }
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        if pieces.count == 2, let a = Double(pieces[0]), let b = Double(pieces[1]), b != 0 {
            let value = a / b; return value.isFinite && value > 0 ? value : nil
        }
        return parsePositive(text)
    }
}

private extension LibraryFilterRegistration {
    func hasSameContent(as other: LibraryFilterRegistration?) -> Bool {
        guard let other else { return false }
        return descriptor == other.descriptor
            && snapshot.sections == other.snapshot.sections
            && referencesBySection == other.referencesBySection
            && filter == other.filter
    }
}
