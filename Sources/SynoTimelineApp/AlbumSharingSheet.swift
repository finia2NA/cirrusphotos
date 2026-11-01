import SwiftUI
import AppKit
import PhotoCache
import SynologyAPI

struct AlbumSharingSheet: View {
    let albumID: Int64
    let repository: CachedPhotosRepository
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: AlbumSharingSnapshot?
    @State private var roles: [Int64: String] = [:]
    @State private var selectedID: Int64?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDisable = false

    private var editable: Bool {
        guard let album = snapshot?.album else { return false }
        return album.sharingInfo?.privacyType == "private"
    }
    private var existing: [Int64: AlbumSharingPermission] {
        var result: [Int64: AlbumSharingPermission] = [:]
        guard snapshot?.album.shared == true else { return result }
        for grant in snapshot?.album.sharingInfo?.permission ?? [] where grant.type == "user" {
            if let id = grant.principalID { result[id] = grant }
        }
        return result
    }
    private var changes: [SharingPermissionChange] {
        let ids = Set(roles.keys).union(existing.keys)
        return ids.sorted().compactMap { id in
            let old = existing[id]?.role
            let new = roles[id]
            guard old != new else { return nil }
            let member = SharingPermissionChange.Member(type: "user", id: id)
            if let new { return SharingPermissionChange(action: "update", role: new, member: member) }
            return SharingPermissionChange(action: "delete", member: member)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sharing").font(.title2.weight(.semibold))
            if let snapshot {
                Text(snapshot.album.name).foregroundStyle(.secondary)
                if !editable { Text("These sharing settings cannot be edited here.").foregroundStyle(.secondary) }
                if editable {
                    List {
                        ForEach(roles.keys.sorted(), id: \.self) { id in
                            HStack {
                                Text(snapshot.principals.first(where: { $0.id == id })?.name ?? existing[id]?.name ?? "User")
                                Spacer()
                                if let role = roles[id], role == "view" || role == "download" {
                                    Picker("Role", selection: Binding(get: { roles[id] ?? "view" }, set: { roles[id] = $0 })) {
                                        Text("Viewer").tag("view")
                                        Text("Downloader").tag("download")
                                    }.labelsHidden().frame(width: 130)
                                    Button("Remove") { roles.removeValue(forKey: id) }
                                } else {
                                    Text("Other role").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.frame(height: 180)
                    HStack {
                        Picker("Add user", selection: $selectedID) {
                            Text("Choose a user").tag(Int64?.none)
                            ForEach(snapshot.principals.filter { roles[$0.id] == nil }) { user in
                                Text(user.name).tag(Optional(user.id))
                            }
                        }
                        Button("Add") {
                            if let id = selectedID { roles[id] = "view"; selectedID = nil }
                        }.disabled(selectedID == nil)
                    }
                }
                if snapshot.album.shared, let link = snapshot.album.sharingInfo?.sharingLink, !link.isEmpty {
                    Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) }
                }
                if snapshot.album.shared {
                    Button("Disable Sharing…", role: .destructive) { confirmDisable = true }
                }
            } else if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if snapshot == nil && !busy { Button("Reload") { load() } }
                Spacer()
                Button("Close") { dismiss() }
                if snapshot != nil && editable {
                    Button(snapshot?.album.shared == true ? "Save" : "Enable Sharing") { save(disable: false) }
                        .disabled(snapshot?.album.shared == true && changes.isEmpty)
                }
            }
        }
        .padding(24).frame(width: 520)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .task { load() }
        .alert("Disable sharing?", isPresented: $confirmDisable) {
            Button("Disable Sharing", role: .destructive) { save(disable: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Invitees will lose access to this album.") }
    }
    private func load() {
        busy = true; error = nil; snapshot = nil; roles = [:]
        Task {
            do {
                let loaded = try await repository.albumSharing(id: albumID)
                snapshot = loaded
                if loaded.album.shared {
                    for grant in loaded.album.sharingInfo?.permission ?? [] where grant.type == "user" {
                        if let id = grant.principalID { roles[id] = grant.role }
                    }
                }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func save(disable: Bool) {
        guard let snapshot else { return }
        let delta = changes
        busy = true; error = nil
        Task {
            do {
                _ = try await repository.saveAlbumSharing(snapshot: snapshot, changes: delta, disable: disable)
                load()
            } catch {
                self.snapshot = nil
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}
