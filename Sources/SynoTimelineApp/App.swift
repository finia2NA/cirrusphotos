import AppKit
import SwiftUI

@main
struct SynoTimelineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var preferences: AppPreferences
    @StateObject private var model: LibraryModel
    @StateObject private var albumPresentation = AlbumPresentationStore()
    @StateObject private var navigation = NavigationModel()
    @StateObject private var infoPanel = InfoPanelModel()
    @StateObject private var libraryFilter = LibraryFilterModel()
    @StateObject private var timelineSectionLoad = TimelineSectionLoadModel()
    @StateObject private var metadataSync = MetadataSyncModel()

    init() {
        let preferences = AppPreferences()
        _preferences = StateObject(wrappedValue: preferences)
        _model = StateObject(wrappedValue: LibraryModel(session: AppSession(preferences: preferences)))
    }

    var body: some Scene {
        WindowGroup("Cirrus Photos") {
            AppShellView(navigation: navigation, albumPresentation: albumPresentation)
                .environmentObject(model)
                .environmentObject(preferences)
                .environmentObject(infoPanel)
                .environmentObject(libraryFilter)
                .environmentObject(timelineSectionLoad)
                .environmentObject(metadataSync)
                .frame(minWidth: 560, minHeight: 420)
                .task { await model.load() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 860, height: 820)
        .commands {
            LibraryCommands(model: model, preferences: preferences, infoPanel: infoPanel, filter: libraryFilter,
                            timelineSectionLoad: timelineSectionLoad)
        }
        Settings { CacheSettingsView().environmentObject(model).environmentObject(preferences) }
        Window("Download Thumbnails", id: "thumbnail-download") {
            ThumbnailRangeDownloadView().environmentObject(model).environmentObject(preferences)
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        Window("Load Timeline Sections", id: "timeline-section-load") {
            TimelineSectionLoadView().environmentObject(timelineSectionLoad)
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        UtilityWindow("Info", id: InfoPanelScene.id) {
            InfoPanelView()
                .environmentObject(model)
                .environmentObject(preferences)
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmStoppingDownloads() ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
