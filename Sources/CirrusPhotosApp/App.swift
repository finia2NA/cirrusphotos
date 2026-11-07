import AppKit
import SwiftUI

@main
struct CirrusPhotosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var preferences: AppPreferences
    @State private var accounts: AccountController

    init() {
        let preferences = AppPreferences()
        _preferences = StateObject(wrappedValue: preferences)
        let accounts = AccountController(preferences: preferences)
        // Open the saved or .env account before the first frame, so sign-in never flashes.
        accounts.start()
        _accounts = State(initialValue: accounts)
    }

    var body: some Scene {
        WindowGroup("Cirrus Photos") {
            AccountRootView(accounts: accounts)
                .environmentObject(preferences)
                .task {
                    ModelChangeSignposts.shared.observe(preferences, name: "AppPreferences")
                    delegate.accounts = accounts
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 860, height: 820)
        .commands {
            if let context = accounts.context {
                LibraryCommands(model: context.model, activity: context.model.activity, preferences: preferences,
                                infoPanel: context.infoPanel, filter: context.libraryFilter,
                                timelineSectionLoad: context.timelineSectionLoad)
            }
            AccountCommands(accounts: accounts)
        }
        Settings {
            SettingsView(accounts: accounts).environmentObject(preferences)
        }
        Window("Add Account", id: AddAccountWindow.id) {
            AddAccountWindow(accounts: accounts)
                .environmentObject(preferences)
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        Window("Download Thumbnails", id: "thumbnail-download") {
            AccountScoped(accounts: accounts) { context in
                ThumbnailRangeDownloadView()
                    .environment(context.model)
                    .environmentObject(context.thumbnailPreload)
            }
            .environmentObject(preferences)
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        Window("Load Timeline Sections", id: "timeline-section-load") {
            AccountScoped(accounts: accounts) { context in
                TimelineSectionLoadView().environmentObject(context.timelineSectionLoad)
            }
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        UtilityWindow("Info", id: InfoPanelScene.id) {
            AccountScoped(accounts: accounts) { context in
                InfoPanelView()
                    .environment(context.model)
                    .environmentObject(context.infoPanel)
            }
            .environmentObject(preferences)
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The open account, whose session's transfers quitting would cancel.
    weak var accounts: AccountController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // One library window; tabs only duplicate it.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmStoppingDownloads(accounts?.context?.model.session) ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
