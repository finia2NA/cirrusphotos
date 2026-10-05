import AppKit
import SwiftUI

@main
struct SynoTimelineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = LibraryModel()
    @StateObject private var navigationRestoration = NavigationRestorationStore()
    @StateObject private var infoPanel = InfoPanelModel()

    var body: some Scene {
        WindowGroup("Cirrus Photos") {
            AppShellView(navigationRestoration: navigationRestoration)
                .environmentObject(model)
                .environmentObject(infoPanel)
                .frame(minWidth: 560, minHeight: 420)
                .task { await model.load() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 860, height: 820)
        .commands { LibraryCommands(model: model, infoPanel: infoPanel) }
        Settings { CacheSettingsView().environmentObject(model) }
        Window("Download Thumbnails", id: "thumbnail-download") {
            ThumbnailRangeDownloadView().environmentObject(model)
        }
        .defaultSize(width: 540, height: 500)
        .commandsRemoved()
        UtilityWindow("Info", id: InfoPanelScene.id) {
            InfoPanelView()
                .environmentObject(model)
                .environmentObject(infoPanel)
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
