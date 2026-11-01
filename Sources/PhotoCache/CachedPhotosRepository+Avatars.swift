import Foundation
import SynologyAPI

struct AvatarIdentity: Hashable { let photosID: Int64; let principalID: Int64 }
struct AvatarWork {
    let id: UUID
    let task: Task<Data?, Never>
    var observers: Set<UUID>
}

extension CachedPhotosRepository {
    /// Identity is verified in both namespaces before using a server-supplied descriptor.
    public func recipientAvatar(photosID: Int64, principalID: Int64) async -> Data? {
        let key = AvatarIdentity(photosID: photosID, principalID: principalID)
        if let data = avatars[key] { return data }
        guard !Task.isCancelled else { return nil }
        let observer = UUID()
        let work: AvatarWork
        if var existing = avatarTasks[key] {
            existing.observers.insert(observer)
            avatarTasks[key] = existing
            work = existing
        } else {
            guard avatarTasks.count < 32 else { return nil }
            let task = Task<Data?, Never> {
                do {
                    try await self.connect()
                    let id = UUID()
                    try await self.gate.acquire(.thumbnail, priority: .visible, id: id)
                    do {
                        let profiles = try await self.client.userProfiles(ids: [photosID])
                        guard !Task.isCancelled,
                              let profile = profiles.first(where: { $0.id == photosID && $0.uid == principalID && $0.enabled }),
                              let descriptor = profile.profile?.photo, !descriptor.isEmpty else {
                            await self.gate.release(.thumbnail); return nil
                        }
                        let data = try await self.client.profilePhoto(descriptor: descriptor)
                        await self.gate.release(.thumbnail)
                        return Task.isCancelled ? nil : data
                    } catch { await self.gate.release(.thumbnail); return nil }
                } catch { return nil }
            }
            work = AvatarWork(id: UUID(), task: task, observers: [observer])
            avatarTasks[key] = work
        }
        return await withTaskCancellationHandler {
            let data = await work.task.value
            finishAvatarObserver(key: key, workID: work.id, observer: observer, data: data)
            return Task.isCancelled ? nil : data
        } onCancel: {
            Task { await self.finishAvatarObserver(key: key, workID: work.id, observer: observer, data: nil) }
        }
    }

    private func finishAvatarObserver(key: AvatarIdentity, workID: UUID, observer: UUID, data: Data?) {
        guard var work = avatarTasks[key], work.id == workID, work.observers.remove(observer) != nil else { return }
        if let data {
            if avatars.count >= 128 { avatars.removeAll() }
            avatars[key] = data
        }
        if work.observers.isEmpty {
            avatarTasks[key] = nil
            work.task.cancel()
        } else {
            avatarTasks[key] = work
        }
    }
}
