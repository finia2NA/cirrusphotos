import PhotoCache
import SwiftUI
import SynologyAPI

/// Normal and thumbnail-only rotation of the browser selection or viewer photo.
extension LibraryModel {
    var canRotate: Bool {
        if let activeViewer { return capabilities(for: activeViewer.collection).allowsSpaceItemActions && activeViewer.canRotate }
        return browserCommandsActive && capabilities(for: browserCommandSnapshot.collection).allowsSpaceItemActions && !browserCommandSnapshot.selectedOrdinals.isEmpty &&
            timelineVerified(for: browserCommandSnapshot.collection) && !rotationBusy
    }

    func rotateSelection(_ direction: PhotoRotationDirection) {
        if let activeViewer {
            activeViewer.rotate(direction)
            updateViewerCommands()
            return
        }
        guard canRotate, let repository else { return }
        rotationBusy = true
        let snapshot = browserCommandSnapshot
        Task { [weak self] in
            guard let self else { return }
            defer { rotationBusy = false }
            guard let action = await resolveRotation(snapshot, repository: repository) else {
                reportUnverified("Rotate", message: "The selected photos could not be verified or do not support rotation.")
                return
            }
            // A rotation is relative, so it is never retried: a repeat could turn a photo twice.
            let handle = activity.begin(.rotate(direction), items: action.activityItems)
            do {
                try await repository.rotate(action, direction: direction)
                handle.succeed()
            } catch {
                handle.fail(error, operation: "Rotation")
            }
        }
    }

    var canRotateThumbnails: Bool {
        canRotate && capabilities(for: activeViewer?.collection ?? browserCommandSnapshot.collection).allowsSpaceItemActions
    }

    func rotateThumbnailPreviews(_ direction: PhotoRotationDirection) {
        guard canRotateThumbnails, thumbnailRotationTask == nil, let repository else { return }
        isFixingThumbnailRotations = false
        let snapshot = browserCommandSnapshot
        thumbnailRotationProgress = .init(completedItems: 0, totalItems: 0, itemID: nil, stage: .preparing)
        thumbnailRotationTask = Task { [weak self] in
            guard let self else { return }
            let action: SelectionRotationAction?
            if let viewer = activeViewer { action = viewer.rotationAction() }
            else { action = await resolveRotation(snapshot, repository: repository) }
            guard let action, !action.itemIDs.isEmpty else {
                thumbnailRotationProgress = .init(completedItems: 0, totalItems: 0, itemID: nil,
                    stage: .finished, failures: ["No selected photos support thumbnail rotation."])
                thumbnailRotationTask = nil
                return
            }
            for await progress in await repository.rotateThumbnails(action, direction: direction) {
                thumbnailRotationProgress = progress
            }
            DecodedImages.shared.clear()
            thumbnailRotationTask = nil
        }
    }

    func fixThumbnailRotations() {
        guard canRotateThumbnails else { return }
        guard thumbnailRotationTask == nil, let repository else { return }
        isFixingThumbnailRotations = true
        let snapshot = browserCommandSnapshot
        thumbnailRotationProgress = .init(completedItems: 0, totalItems: 0,
                                          itemID: nil, stage: .preparing)
        thumbnailRotationTask = Task { [weak self] in
            guard let self else { return }
            let action: SelectionRotationAction?
            if let viewer = activeViewer { action = viewer.rotationAction() }
            else { action = await resolveRotation(snapshot, repository: repository) }
            guard let action, !action.itemIDs.isEmpty else {
                thumbnailRotationProgress = .init(
                    completedItems: 0, totalItems: 0, itemID: nil, stage: .finished,
                    failures: ["No selected photos support thumbnail rotation repair."]
                )
                thumbnailRotationTask = nil
                return
            }
            for await progress in await repository.fixThumbnailRotations(action) {
                thumbnailRotationProgress = progress
            }
            DecodedImages.shared.clear()
            thumbnailRotationTask = nil
        }
    }

    func cancelThumbnailRotation() {
        thumbnailRotationTask?.cancel()
        thumbnailRotationTask = nil
    }

    func dismissThumbnailRotation() {
        if thumbnailRotationProgress?.stage != .finished { cancelThumbnailRotation() }
        thumbnailRotationProgress = nil
        isFixingThumbnailRotations = false
    }


    func resolveRotation(_ snapshot: BrowserCommandSnapshot,
                                 repository: CachedPhotosRepository) async -> SelectionRotationAction? {
        guard snapshot.active, let selection = snapshot.captureSelection(timeline: snapshots[snapshot.collection]) else { return nil }
        return await SelectionRotationResolver(repository: repository).resolve(selection)
    }
}

extension SelectionRotationAction {
    var activityItems: [ActivityItem] { itemIDs.compactMap { itemsByID[$0] }.map { ActivityItem(photo: $0, collection: collection) } }
}
