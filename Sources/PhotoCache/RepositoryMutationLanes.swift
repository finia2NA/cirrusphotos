import SynologyAPI

/// Changes that must not overlap. A second change in a busy lane fails with
/// `RepositoryError.busy` instead of queueing behind the first.
enum MutationLane: Hashable, Sendable {
    /// Album creation, membership, rename, deletion, sharing and incoming contribution.
    case album
    case deletion
    case upload
    case people(PhotoSpace)
}

extension CachedPhotosRepository {
    func claimMutation(_ lane: MutationLane, busy message: String) throws {
        guard activeMutations.insert(lane).inserted else { throw RepositoryError.busy(message) }
    }

    func releaseMutation(_ lane: MutationLane) { activeMutations.remove(lane) }

    func isMutating(_ lane: MutationLane) -> Bool { activeMutations.contains(lane) }
}
