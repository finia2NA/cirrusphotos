import SwiftUI
import AppKit
import PhotoCache
import SynologyAPI

enum SharingExpiry {
    static func endOfDay(_ date: Date, calendar: Calendar = .current) -> Int64? {
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else { return nil }
        return Int64(next.timeIntervalSince1970) - 1
    }
}

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
    @State private var access = "private"
    @State private var passwordAction = "unchanged"
    @State private var password = ""
    @State private var hasExpiry = false
    @State private var expiryDate = Date()

    private var editable: Bool {
        guard let album = snapshot?.album else { return false }
        return ["private", "public-view", "public-download"].contains(album.sharingInfo?.privacyType ?? "")
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
    private var accessChange: AlbumSharingAccessChange {
        guard let album = snapshot?.album, access != (album.shared ? (album.sharingInfo?.privacyType ?? "") : "private") else { return .unchanged }
        return access == "private" ? .private : .publicView
    }
    private var expiryChange: Int64? {
        let original = snapshot?.album.shared == true ? (snapshot?.album.sharingInfo?.expiration ?? 0) : 0
        if !hasExpiry { return original == 0 ? nil : 0 }
        if original > 0 && Calendar.current.isDate(expiryDate, inSameDayAs: Date(timeIntervalSince1970: TimeInterval(original))) { return nil }
        return SharingExpiry.endOfDay(expiryDate)
    }
    private var passwordChange: SharingPasswordChange {
        switch passwordAction {
        case "set": return .set(password)
        case "clear": return .clear
        default: return .unchanged
        }
    }
    private var hasChanges: Bool {
        !changes.isEmpty || accessChange != .unchanged || passwordChange != .unchanged || expiryChange != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sharing").font(.title2.weight(.semibold))
            if let snapshot {
                Text(snapshot.album.name).foregroundStyle(.secondary)
                if !editable { Text("These sharing settings cannot be edited here.").foregroundStyle(.secondary) }
                if editable {
                    Picker("Access", selection: $access) {
                        Text("Private").tag("private")
                        Text("Public View").tag("public-view")
                        if snapshot.album.sharingInfo?.privacyType == "public-download" {
                            Text("Public Download (existing)").tag("public-download")
                        }
                    }
                    Picker("Password", selection: $passwordAction) {
                        Text(snapshot.album.sharingInfo?.enablePassword == true ? "Keep current password" : "No password").tag("unchanged")
                        Text("Set password").tag("set")
                        if snapshot.album.sharingInfo?.enablePassword == true { Text("Clear password").tag("clear") }
                    }
                    if passwordAction == "set" { SecureField("New password", text: $password) }
                    Toggle("Expires", isOn: $hasExpiry)
                    if hasExpiry {
                        DatePicker("Expiry date (local time)", selection: $expiryDate, displayedComponents: .date)
                    }
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
                        .disabled((snapshot?.album.shared == true && !hasChanges) || (passwordAction == "set" && password.isEmpty))
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
                access = loaded.album.shared ? (loaded.album.sharingInfo?.privacyType ?? "private") : "private"
                passwordAction = "unchanged"; password = ""
                let expiry = loaded.album.shared ? (loaded.album.sharingInfo?.expiration ?? 0) : 0
                hasExpiry = expiry > 0
                expiryDate = expiry > 0 ? Date(timeIntervalSince1970: TimeInterval(expiry)) : Date()
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
        let access = accessChange, password = passwordChange, expiry = expiryChange
        busy = true; error = nil
        Task {
            do {
                _ = try await repository.saveAlbumSharing(snapshot: snapshot, changes: delta, disable: disable, access: access, password: password, expiration: expiry)
                load()
            } catch {
                self.snapshot = nil
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}
