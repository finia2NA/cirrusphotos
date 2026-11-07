import Foundation
import SynologyAPI

/// Ratings and tags. Both are per-item server fields; every write is followed by an
/// authoritative read of the affected items, which replaces the cached rating and tags.
extension CachedPhotosRepository {
    /// Creates a tag, or returns the existing tag of that name, in the space that owns
    /// the action's items.
    public func createTag(named name: String, for action: SelectionAnnotationAction) async throws -> PhotoTag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RepositoryError.invalidInput("Enter a tag name.") }
        let space = try await annotationSpace(for: action)
        try await connect()
        let tag = try await client.createTag(name: trimmed, space: space)
        await invalidateTagIndex(space: space)
        return tag
    }

    /// Applies a rating or tag edit to the verified items.
    public func annotate(_ action: SelectionAnnotationAction, edit: PhotoAnnotationEdit) async throws {
        guard !action.itemIDs.isEmpty else { return }
        let space = try await annotationSpace(for: action)
        try await performAnnotation(action, edit: edit, space: space)
    }

    /// Creates the tag if needed, then adds it to the items.
    public func addNewTag(named name: String, to action: SelectionAnnotationAction) async throws {
        guard !action.itemIDs.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RepositoryError.invalidInput("Enter a tag name.") }
        let space = try await annotationSpace(for: action)
        try await connect()
        let tag = try await client.createTag(name: trimmed, space: space)
        await invalidateTagIndex(space: space)
        try await performAnnotation(action, edit: .addTags([tag]), space: space)
    }

    private func annotationSpace(for action: SelectionAnnotationAction) async throws -> PhotoSpace {
        let source = mediaCollection(for: action.collection)
        guard source.incomingAlbumIdentity == nil, !source.isSessionDerived else {
            throw RepositoryError.unavailable("Ratings and tags are unavailable for shared album photos.")
        }
        return try await itemActionSpace(itemIDs: action.itemIDs, collection: source)
    }

    private func performAnnotation(_ action: SelectionAnnotationAction, edit: PhotoAnnotationEdit,
                                   space: PhotoSpace) async throws {
        if case .rating(let rating) = edit, !(0...PhotoAnnotations.maximumRating).contains(rating) {
            throw RepositoryError.invalidInput("A rating is between 0 and 5 stars.")
        }
        if let expected = action.expectedTimelineFingerprint {
            guard let snapshot = metadata.latestTimelines[action.collection],
                  LibraryIndex(snapshot: snapshot).fingerprint == expected else {
                throw RepositoryError.stale("The collection changed before the update. Try again.")
            }
        }
        let epoch = metadata.admissionEpoch
        let identities = action.itemIDs.map { PhotoItemIdentity(scope: .space(space), itemID: $0) }
        guard identities.allSatisfy({ !itemMutations.pendingIDs.contains($0) }) else {
            throw RepositoryError.busy("Another change to one of these photos is in progress.")
        }
        itemMutations.pendingIDs.formUnion(identities)
        defer { itemMutations.pendingIDs.subtract(identities) }

        var attemptedWrite = false
        var writeError: (any Error)?
        do {
            try await connect()
            for start in stride(from: 0, to: action.itemIDs.count, by: 100) {
                let chunk = Array(action.itemIDs[start..<min(start + 100, action.itemIDs.count)])
                attemptedWrite = true
                switch edit {
                case .rating(let rating): try await client.setRating(itemIDs: chunk, rating: rating, space: space)
                case .addTags(let tags): try await client.addTags(tags.map(\.id), toItems: chunk, space: space)
                case .removeTags(let tags): try await client.removeTags(tags.map(\.id), fromItems: chunk, space: space)
                }
            }
        } catch {
            writeError = error
        }
        // Even a failed write may have changed some items, so the result is always read back.
        if attemptedWrite {
            let refreshed = try? await lookupAllRotationItems(action.itemIDs, space: space)
            if let refreshed {
                await publishAnnotations(refreshed, previous: action.itemsByID, edit: edit,
                                         collection: action.collection, space: space, epoch: epoch)
            }
            if writeError == nil, refreshed == nil {
                throw RepositoryError.unconfirmed("The change was sent but could not be confirmed. Refresh to check.")
            }
        }
        if let writeError { throw writeError }
    }

    private func publishAnnotations(_ refreshed: [PhotoItem], previous: [Int64: PhotoItem], edit: PhotoAnnotationEdit,
                                    collection: PhotoCollectionDescriptor, space: PhotoSpace, epoch: UInt64) async {
        guard isAdmitted(epoch) else { return }
        let values = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0.annotations) })
        var changedTags = Set<Int64>()
        if case .addTags(let tags) = edit { changedTags.formUnion(tags.map(\.id)) }
        if case .removeTags(let tags) = edit { changedTags.formUnion(tags.map(\.id)) }
        let source = mediaCollection(for: collection)
        var namespaces = [metadataNamespace(for: space)]
        if source.albumID != nil { namespaces.append(metadataNamespace(for: source)) }
        if metadata.initialized {
            for scoped in namespaces {
                guard let admission = try? await store.metadataAdmission(scoped), isAdmitted(epoch) else { continue }
                try? await store.applyMetadataAnnotations(values, changedTagIDs: changedTags, namespace: scoped, admission: admission)
                await publishDetailReferences(ids: Array(values.keys), namespace: scoped)
            }
            publishDerivedPageChanges(ids: Set(values.keys), space: space)
        }
        itemMutations.publish(PhotoItemChange(items: [:], annotations: values, scope: .space(space)))
        if source.albumID != nil {
            itemMutations.publish(PhotoItemChange(items: [:], annotations: values, scope: source.contentScope))
        }
    }

    /// Tells page observers (filters, derived collections) which cached pages list these items.
    private func publishDetailReferences(ids: [Int64], namespace scoped: MetadataNamespace) async {
        let sources = Set(metadata.collectionPageObservers.values.map(\.collection))
            .filter { !$0.isSessionDerived && metadataNamespace(for: $0) == scoped }
        for source in sources {
            guard let references = try? await store.metadataCollectionReferences(scoped, collection: source, ids: ids) else { continue }
            for section in references {
                if let key = CacheKey.page(scope: source.contentScope, namespace: namespace, section: section, collection: source) {
                    publishCollectionPage(key: key)
                }
            }
        }
    }

    private func invalidateTagIndex(space: PhotoSpace) async {
        guard metadata.initialized else { return }
        let scoped = metadataNamespace(for: space)
        guard let admission = try? await store.metadataAdmission(scoped) else { return }
        try? await store.invalidateMetadataCollectionIndex(.tag, namespace: scoped, admission: admission)
    }
}
