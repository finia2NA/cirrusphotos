import AppKit
import SwiftUI

@main
struct SynoTimelineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = LibraryModel()
    @StateObject private var navigationRestoration = NavigationRestorationStore()

    var body: some Scene {
        WindowGroup("Cirrus Photos") {
            AppShellView(navigationRestoration: navigationRestoration)
                .environmentObject(model)
                .frame(minWidth: 560, minHeight: 420)
                .task { await model.load() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 860, height: 820)
        .commands { LibraryCommands(model: model) }
        Settings { CacheSettingsView().environmentObject(model) }
        Window("Download Thumbnails", id: "thumbnail-download") {
            ThumbnailRangeDownloadView().environmentObject(model)
        }
        .defaultSize(width: 540, height: 500)
        .commandsRemoved()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
