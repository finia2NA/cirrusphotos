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

struct SharingPasswordDraft {
    let originallyRequired: Bool
    var required: Bool
    var value = ""

    init(originallyRequired: Bool) {
        self.originallyRequired = originallyRequired
        self.required = originallyRequired
    }

    var change: SharingPasswordChange {
        guard required else { return originallyRequired ? .clear : .unchanged }
        if value.isEmpty && originallyRequired { return .unchanged }
        return .set(value)
    }

    var needsPassword: Bool { required && !originallyRequired && value.isEmpty }
}

struct AlbumSharingSheet: View {
    let albumID: Int64
    let repository: CachedPhotosRepository
    let activity: ActivityCenter
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: AlbumSharingSnapshot?
    @State private var roles: [Int64: String] = [:]
    @State private var selectedID: Int64?
    @State private var busy = false
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDisable = false
    @State private var access = "private"
    @State private var passwordDraft = SharingPasswordDraft(originallyRequired: false)
    @State private var hasExpiry = false
    @State private var expiryDate = Date()
    @State private var showingExpiryCalendar = false

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
        switch access {
        case "private": return .private
        case "public-download": return .publicDownload
        default: return .publicView
        }
    }
    private var expiryChange: Int64? {
        let original = snapshot?.album.shared == true ? (snapshot?.album.sharingInfo?.expiration ?? 0) : 0
        if !hasExpiry { return original == 0 ? nil : 0 }
        if original > 0 && Calendar.current.isDate(expiryDate, inSameDayAs: Date(timeIntervalSince1970: TimeInterval(original))) { return nil }
        return SharingExpiry.endOfDay(expiryDate)
    }
    private var passwordChange: SharingPasswordChange { passwordDraft.change }
    private var hasChanges: Bool {
        !changes.isEmpty || accessChange != .unchanged || passwordChange != .unchanged || expiryChange != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sharing").font(.title2.weight(.semibold))
                if let snapshot { Text(snapshot.album.name).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let snapshot {
                        sharingContent(snapshot)
                    } else if busy {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                    if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .disabled(busy)

            Divider()
            HStack {
                if snapshot == nil && !busy { Button("Reload") { load() } }
                Spacer()
                Button("Close") { dismiss() }
                    .disabled(saving)
                if snapshot?.album.shared == true && editable {
                    Button("Save") { save(disable: false, closeOnSuccess: true) }
                        .disabled(busy || !hasChanges || passwordDraft.needsPassword)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 560, height: 600)
        .interactiveDismissDisabled(saving)
        .task { load() }
        .alert("Disable sharing?", isPresented: $confirmDisable) {
            Button("Disable Sharing", role: .destructive) { save(disable: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Invitees will lose access to this album.") }
    }

    @ViewBuilder
    private func sharingContent(_ snapshot: AlbumSharingSnapshot) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Share Link").font(.headline)
                Text(snapshot.album.shared ? "Sharing is on" : "Sharing is off")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Share Link", isOn: Binding(
                get: { snapshot.album.shared },
                set: { enabled in
                    if enabled { save(disable: false) } else { confirmDisable = true }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!snapshot.album.shared && !editable)
        }

        if snapshot.album.shared {
            if let link = snapshot.album.sharingInfo?.sharingLink, !link.isEmpty {
                HStack(spacing: 8) {
                    Text(link)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                        .accessibilityLabel("Share Link")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy Link")
                        .accessibilityLabel("Copy Link")
                }
            }
            if editable {
                settingsContent(snapshot)
            } else {
                Text("These sharing settings cannot be edited here.").foregroundStyle(.secondary)
            }
        } else if !editable {
            Text("These sharing settings cannot be edited here.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func settingsContent(_ snapshot: AlbumSharingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy").font(.headline)
            Picker("Access", selection: $access) {
                Text("Private — invited users only").tag("private")
                Text("Public — anyone with the link can view").tag("public-view")
                Text("Public — anyone with the link can download").tag("public-download")
            }
            .labelsHidden()
            .accessibilityLabel("Access")
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("Link Protection").font(.headline)
            HStack {
                Toggle("Require password", isOn: Binding(
                    get: { passwordDraft.required },
                    set: { required in passwordDraft.required = required; passwordDraft.value = "" }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                SecureField(passwordDraft.originallyRequired ? "Leave blank to keep password" : "Password", text: $passwordDraft.value)
                    .frame(width: 220)
                    .disabled(!passwordDraft.required)
                    .accessibilityLabel("Password")
            }
            HStack {
                Toggle("Expire on", isOn: $hasExpiry)
                    .toggleStyle(.checkbox)
                Spacer()
                Button { showingExpiryCalendar.toggle() } label: {
                    HStack {
                        Text(expiryDate, format: .dateTime.year().month(.abbreviated).day())
                        Spacer()
                        Image(systemName: "calendar")
                    }.frame(width: 204)
                }
                .disabled(!hasExpiry)
                .accessibilityLabel("Expiry date")
                .popover(isPresented: $showingExpiryCalendar, arrowEdge: .bottom) {
                    DatePicker("Expiry date (local time)", selection: $expiryDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .accessibilityLabel("Expiry date, local time")
                        .padding(12)
                }
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("Invitees").font(.headline)
            HStack(spacing: 8) {
                Picker("Add user", selection: $selectedID) {
                    Text("Choose a user").tag(Int64?.none)
                    ForEach(snapshot.principals.filter { roles[$0.id] == nil }) { user in
                        Text(user.name).tag(Optional(user.id))
                    }
                }.labelsHidden().accessibilityLabel("Add user")
                Button("Add") {
                    if let id = selectedID { roles[id] = "view"; selectedID = nil }
                }.disabled(selectedID == nil)
            }
            if roles.isEmpty {
                Text("No invitees").foregroundStyle(.secondary)
            } else {
                ForEach(roles.keys.sorted(), id: \.self) { id in
                    HStack(spacing: 10) {
                        Text(snapshot.principals.first(where: { $0.id == id })?.name ?? existing[id]?.name ?? "User")
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let role = roles[id], ["view", "download", "upload"].contains(role) {
                            Picker("Role", selection: Binding(get: { roles[id] ?? "view" }, set: { roles[id] = $0 })) {
                                Text("Viewer").tag("view")
                                Text("Downloader").tag("download")
                                Text("Provider").tag("upload")
                            }.labelsHidden().frame(width: 130)
                            Button("Remove") { roles.removeValue(forKey: id) }
                        } else {
                            Text("Other role").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
    private func load(warning: String? = nil) {
        busy = true; error = nil; snapshot = nil; roles = [:]
        Task {
            do {
                let loaded = try await repository.albumSharing(id: albumID)
                snapshot = loaded
                access = loaded.album.shared ? (loaded.album.sharingInfo?.privacyType ?? "private") : "private"
                passwordDraft = SharingPasswordDraft(originallyRequired: loaded.album.shared && loaded.album.sharingInfo?.enablePassword == true)
                let expiry = loaded.album.shared ? (loaded.album.sharingInfo?.expiration ?? 0) : 0
                hasExpiry = expiry > 0
                expiryDate = expiry > 0 ? Date(timeIntervalSince1970: TimeInterval(expiry)) : Date()
                if loaded.album.shared {
                    for grant in loaded.album.sharingInfo?.permission ?? [] where grant.type == "user" {
                        if let id = grant.principalID { roles[id] = grant.role }
                    }
                }
                self.error = warning
            } catch {
                self.error = warning.map { "\($0)\nCould not reload: \(reportedFailure(error, operation: "Album sharing reload"))" } ?? reportedFailure(error, operation: "Album sharing reload")
            }
            busy = false
        }
    }
    private func save(disable: Bool, closeOnSuccess: Bool = false) {
        guard let snapshot else { return }
        let delta = changes
        let access = accessChange, password = passwordChange, expiry = expiryChange
        let kind = ActivityKind.albumSharing(name: snapshot.album.name)
        busy = true; saving = true; error = nil
        Task {
            do {
                _ = try await repository.saveAlbumSharing(snapshot: snapshot, changes: delta, disable: disable, access: access, password: password, expiration: expiry)
                activity.record(kind, outcome: .succeeded)
                saving = false
                if closeOnSuccess {
                    busy = false
                    dismiss()
                } else {
                    load()
                }
            } catch {
                saving = false
                let failure = ActivityFailure.recorded(error, operation: "Album sharing")
                activity.record(kind, outcome: failure.unconfirmed ? .unconfirmed : .failed, failure: failure)
                load(warning: failure.message)
            }
        }
    }
}
