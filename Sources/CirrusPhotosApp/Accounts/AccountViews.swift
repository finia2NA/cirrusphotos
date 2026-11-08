import AppKit
import PhotoCache
import SwiftUI
import SynologyAPI

/// The library of the open account; or the sign-in window, which continues with setup
/// after a new sign-in while the account loads behind it.
struct AccountRootView: View {
    let accounts: AccountController

    var body: some View {
        Group {
            if let context = accounts.context, let step = accounts.setupStep {
                SetupView(accounts: accounts, context: context, step: step)
                    .frame(minWidth: 560, minHeight: 560)
                    .id(context.id)
                    .task(id: context.id) {
                        await context.model.load()
                        context.thumbnailPreload.resumeIfRequested(library: context.model)
                    }
            } else if let context = accounts.context {
                AppShellView(navigation: context.navigation, albumPresentation: context.albumPresentation)
                    .environment(context.model)
                    .environmentObject(context.infoPanel)
                    .environmentObject(context.libraryFilter)
                    .environmentObject(context.timelineSectionLoad)
                    .environmentObject(context.metadataSync)
                    .environmentObject(context.thumbnailPreload)
                    .environment(\.metadataSyncModel, context.metadataSync)
                    .frame(minWidth: 560, minHeight: 420)
                    .id(context.id)
                    .task(id: context.id) {
                        await context.model.load()
                        context.thumbnailPreload.resumeIfRequested(library: context.model)
                    }
            } else if accounts.phase == .switching || (accounts.usesEnvironmentFile && accounts.context == nil) {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SignInView(accounts: accounts)
                    .frame(minWidth: 560, minHeight: 560)
            }
        }
        .sheet(item: Binding(get: { accounts.certificatePrompt }, set: { accounts.certificatePrompt = $0 })) { prompt in
            CertificateTrustSheet(host: prompt.host, fingerprint: prompt.fingerprint,
                                  cancel: { accounts.certificatePrompt = nil },
                                  trust: { Task { await accounts.trustPresentedCertificate() } })
        }
    }
}

/// One page of the sign-in window: app icon, title and explanation, content, and a
/// footer with secondary actions leading and the default action last.
struct OnboardingPage<Content: View, Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content,
         @ViewBuilder leading: () -> Leading = { EmptyView() }, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
                HStack(spacing: 8) {
                    leading
                    Spacer()
                    trailing
                }
            }
            .frame(width: 400)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Content for an auxiliary window that belongs to the open account.
struct AccountScoped<Content: View>: View {
    let accounts: AccountController
    @ViewBuilder let content: (AccountContext) -> Content

    var body: some View {
        if let context = accounts.context {
            content(context).id(context.id)
        } else {
            ContentUnavailableView("Not Signed In", systemImage: "person.crop.circle.badge.questionmark")
                .frame(width: 360, height: 200)
        }
    }
}

// MARK: - Sign-in

struct SignInView: View {
    let accounts: AccountController
    /// Set when the form adds an account in its own window; the library stays open
    /// until the new sign-in succeeds.
    var addingAccount: (() -> Void)? = nil
    @State private var model = SignInModel()
    @FocusState private var focus: Field?

    private enum Field { case server, username, password }

    var body: some View {
        OnboardingPage(title: "Sign in to Synology Photos",
                       subtitle: "Use your Synology NAS address and DSM account.") {
            VStack(spacing: 14) {
                form
                if let message = model.errorMessage ?? (addingAccount == nil ? accounts.notice : nil) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if addingAccount == nil && !accounts.accounts.isEmpty { savedAccounts }
            }
        } trailing: {
            if model.isWorking && model.step == .credentials { ProgressView().controlSize(.small) }
            if let addingAccount {
                Button("Cancel", action: addingAccount)
                    .keyboardShortcut(.cancelAction)
            }
            Button("Sign In") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit || model.step != .credentials)
        }
        .onAppear(perform: prefill)
        .sheet(isPresented: Binding(get: { model.step == .code }, set: { if !$0 && model.step == .code { model.back() } })) {
            CodeEntrySheet(model: model, account: "\(model.username) on \(model.serverURL?.host ?? model.server)") { submit() }
        }
        .sheet(isPresented: Binding(get: { if case .certificate = model.step { true } else { false } },
                                    set: { if !$0, case .certificate = model.step { model.back() } })) {
            if case .certificate(let fingerprint) = model.step {
                CertificateTrustSheet(host: model.serverURL?.host ?? model.server, fingerprint: fingerprint,
                                      working: model.isWorking, cancel: model.back, trust: submit)
            }
        }
    }

    private var form: some View {
        Form {
            TextField("Server", text: $model.server, prompt: Text("nas.example.com"))
                .textContentType(.URL)
                .focused($focus, equals: .server)
                .textInputSuggestions {
                    ForEach(serverSuggestions, id: \.self) { address in
                        Text(address).textInputCompletion(address)
                    }
                }
            TextField("Username", text: $model.username)
                .textContentType(.username)
                .focused($focus, equals: .username)
            SecureField("Password", text: $model.password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .onSubmit(submit)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.isWorking)
    }

    private var savedAccounts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved accounts").font(.caption).foregroundStyle(.secondary)
            ForEach(accounts.accounts) { account in
                Button(account.displayName) { Task { await accounts.switchTo(account) } }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Remembered addresses containing what was typed; all of them for an empty field.
    private var serverSuggestions: [String] {
        let typed = model.server.trimmingCharacters(in: .whitespaces).lowercased()
        let suggestions = accounts.store.serverSuggestions
        guard !typed.isEmpty else { return suggestions }
        return suggestions.filter { $0.lowercased().contains(typed) && $0.lowercased() != typed }
    }

    private func prefill() {
        if let account = accounts.reauthenticating {
            model.server = account.serverURL.absoluteString
            model.username = account.username
            focus = .password
        } else {
            focus = .server
        }
    }

    private func submit() {
        Task {
            let signedIn = await model.submit()
            if let server = model.answeringServer { accounts.store.rememberServer(server) }
            guard let signedIn else { return }
            await accounts.completeSignIn(signedIn)
            addingAccount?()
        }
    }
}

private struct CodeEntrySheet: View {
    @Bindable var model: SignInModel
    let account: String
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        SheetScaffold(title: "Enter Verification Code",
                      subtitle: "Open your authenticator app for \(account).", width: 380) {
            VStack(spacing: 10) {
                TextField("Code", text: Binding(get: { model.code }, set: { value in
                    model.setCode(value)
                    if SignInModel.isCode(model.code) && !model.isWorking { submit() }
                }), prompt: Text("123456"))
                    .textContentType(.oneTimeCode)
                    .font(.title.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .focused($focused)
                    .disabled(model.isWorking)
                if let message = model.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                Text("This Mac won’t ask for a code again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } leading: {
            if model.isWorking { ProgressView().controlSize(.small) }
        } trailing: {
            Button("Back") { model.back() }
                .keyboardShortcut(.cancelAction)
            Button("Verify", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit)
        }
        .onAppear { focused = true }
    }
}

/// Asks whether to connect to a NAS whose certificate macOS cannot verify, for example
/// a self-signed certificate or one that does not list the address used.
struct CertificateTrustSheet: View {
    let host: String
    /// SHA-256 of the leaf certificate, lowercase hex.
    let fingerprint: String
    var working = false
    let cancel: () -> Void
    let trust: () -> Void

    var body: some View {
        SheetScaffold(title: "Connect to \(host)?",
                      subtitle: "macOS could not verify this server’s certificate.",
                      width: 460) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect only if this fingerprint matches the certificate in DSM (Control Panel ▸ Security ▸ Certificate).")
                    .fixedSize(horizontal: false, vertical: true)
                Text(SignInModel.formatted(fingerprint: fingerprint))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Text("You will be asked again if the certificate changes.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } leading: {
            if working { ProgressView().controlSize(.small) }
        } trailing: {
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button("Trust and Connect", action: trust)
                .disabled(working)
        }
    }
}

/// Adds an account without closing the open library. A successful sign-in closes this
/// window and switches the main window to the new account's setup pages.
struct AddAccountWindow: View {
    static let id = "add-account"
    let accounts: AccountController
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        SignInView(accounts: accounts) { dismissWindow(id: Self.id) }
            .frame(width: 480, height: 560)
    }
}

// MARK: - Setup after sign-in

/// The pages after a new sign-in, shown in the sign-in window while the account loads.
private struct SetupView: View {
    let accounts: AccountController
    let context: AccountContext
    let step: AccountController.SetupStep

    var body: some View {
        switch step {
        case .preferences:
            SetupPreferencesPage(back: { Task { await accounts.backToSignIn() } },
                                 next: { accounts.finishPreferencesSetup() })
        case .download:
            SetupDownloadPage(context: context,
                              back: {
                                  if accounts.skippedPreferencesSetup {
                                      Task { await accounts.backToSignIn() }
                                  } else {
                                      accounts.setupStep = .preferences
                                  }
                              },
                              done: { accounts.setupStep = nil })
        }
    }
}

/// Step 2: how thumbnails look and how much this Mac may keep.
private struct SetupPreferencesPage: View {
    let back: () -> Void
    let next: () -> Void
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        OnboardingPage(title: "Set Up Cirrus Photos",
                       subtitle: "You can change both later in Settings.") {
            Form {
                Section {
                    ThumbnailQualityPicker(size: $preferences.thumbnailSize)
                } footer: {
                    Text("Larger thumbnails are sharper but load slower and use more space.")
                }
                Section {
                    LabeledContent("Cache size") {
                        HStack {
                            Slider(value: $preferences.budgetFraction, in: 0...1)
                            Text(ByteCountFormatter.string(fromByteCount: CacheBudget.bytes(at: preferences.budgetFraction),
                                                           countStyle: .file))
                                .monospacedDigit()
                                .frame(width: 72, alignment: .trailing)
                        }
                    }
                } footer: {
                    Text("Viewed photos and videos stay available offline, up to this size.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        } leading: {
            Button("Back", action: back)
        } trailing: {
            Button("Next", action: next)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Step 3: explains downloading thumbnails ahead, then offers it. Library details
/// sync in the background on their own, so they are not offered here.
private struct SetupDownloadPage: View {
    let context: AccountContext
    let back: () -> Void
    let done: () -> Void
    @EnvironmentObject private var preferences: AppPreferences
    @AppStorage(AppPreferences.Key.warmingIncludesSharedSpace) private var includesSharedSpace = true
    @State private var selection: ThumbnailDaySelection?

    var body: some View {
        let targets = ThumbnailPreloadTargets(library: context.model, includesSharedSpace: includesSharedSpace)
        OnboardingPage(title: "Download Thumbnails?",
                       subtitle: "Photos from the chosen dates show instantly and stay visible offline.") {
            VStack(spacing: 10) {
                if !targets.verified {
                    SheetPlaceholder(state: .loading("Reading your library…"), minHeight: 200)
                } else {
                    Form {
                        Section {
                            Toggle("Include Shared Space", isOn: $includesSharedSpace)
                        }
                        Section {
                            ThumbnailRangeSelector(snapshot: targets.combined, selection: $selection)
                        } header: {
                            Text("Dates")
                        } footer: {
                            Text("Up to \(targets.estimate(selection).formatted()) thumbnails at \(qualityName) quality · cache size \(ByteCountFormatter.string(fromByteCount: CacheBudget.bytes(at: preferences.budgetFraction), countStyle: .file))")
                                .monospacedDigit()
                        }
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } leading: {
            Button("Back", action: back)
        } trailing: {
            Button("Skip", action: done)
                .keyboardShortcut(.cancelAction)
            Button("Download") { start(targets) }
                .keyboardShortcut(.defaultAction)
                .disabled(!targets.verified || targets.estimate(selection) == 0)
        }
        .task(id: includesSharedSpace) {
            if includesSharedSpace { context.model.ensureCollectionLoaded(.library(.shared)) }
        }
    }

    private var qualityName: String {
        switch preferences.thumbnailSize { case .sm: "Small"; case .m: "Medium"; case .xl: "Large" }
    }

    private func start(_ targets: ThumbnailPreloadTargets) {
        if let selection {
            context.thumbnailPreload.start(library: context.model, targets: targets, selection: selection,
                                           size: preferences.thumbnailSize)
        }
        done()
    }
}

// MARK: - Account menu

struct AccountCommands: Commands {
    let accounts: AccountController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandMenu("Account") {
            if let context = accounts.context {
                Text(context.title)
            } else {
                Text("Not signed in")
            }
            if !accounts.usesEnvironmentFile {
                Divider()
                Menu("Switch Account") {
                    ForEach(accounts.accounts) { account in
                        Toggle(account.displayName, isOn: Binding(
                            get: { accounts.context?.account?.id == account.id },
                            set: { if $0 { Task { await accounts.switchTo(account) } } }))
                    }
                    if !accounts.accounts.isEmpty { Divider() }
                    Button("Add Account…") { openWindow(id: AddAccountWindow.id) }
                        .disabled(accounts.context == nil)
                }
                Button("Manage Accounts…") {
                    UserDefaults.standard.set("account", forKey: "settings.selectedTab")
                    openSettings()
                }
            }
        }
    }
}
