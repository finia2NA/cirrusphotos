import AppKit
import SwiftUI

@main
struct SynoTimelineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var preferences: AppPreferences
    @State private var model: LibraryModel
    @StateObject private var albumPresentation = AlbumPresentationStore()
    @StateObject private var navigation = NavigationModel()
    @StateObject private var infoPanel = InfoPanelModel()
    @StateObject private var libraryFilter = LibraryFilterModel()
    @StateObject private var timelineSectionLoad = TimelineSectionLoadModel()
    /// Held without observing: the scene never reads sync progress, and observing it here
    /// re-evaluated the whole scene (window and menu bar) for every synced section.
    @State private var metadataSync = MetadataSyncModel()

    init() {
        let preferences = AppPreferences()
        _preferences = StateObject(wrappedValue: preferences)
        _model = State(initialValue: LibraryModel(session: AppSession(preferences: preferences)))
    }

    var body: some Scene {
        WindowGroup("Cirrus Photos") {
            AppShellView(navigation: navigation, albumPresentation: albumPresentation)
                .environment(model)
                .environmentObject(preferences)
                .environmentObject(infoPanel)
                .environmentObject(libraryFilter)
                .environmentObject(timelineSectionLoad)
                .environmentObject(metadataSync)
                .environment(\.metadataSyncModel, metadataSync)
                .frame(minWidth: 560, minHeight: 420)
                .task {
                    let signposts = ModelChangeSignposts.shared
                    signposts.observe(preferences, name: "AppPreferences")
                    signposts.observe(albumPresentation, name: "AlbumPresentationStore")
                    signposts.observe(navigation, name: "NavigationModel")
                    signposts.observe(infoPanel, name: "InfoPanelModel")
                    signposts.observe(libraryFilter, name: "LibraryFilterModel")
                    signposts.observe(timelineSectionLoad, name: "TimelineSectionLoadModel")
                    signposts.observe(metadataSync, name: "MetadataSyncModel")
                    delegate.model = model
                    await model.load()
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 860, height: 820)
        .commands {
            LibraryCommands(model: model, activity: model.activity, preferences: preferences, infoPanel: infoPanel, filter: libraryFilter,
                            timelineSectionLoad: timelineSectionLoad)
        }
        Settings { CacheSettingsView().environment(model).environmentObject(preferences) }
        Window("Download Thumbnails", id: "thumbnail-download") {
            ThumbnailRangeDownloadView().environment(model).environmentObject(preferences)
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
                .environment(model)
                .environmentObject(preferences)
                .environmentObject(infoPanel)
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The open library, whose session's transfers quitting would cancel.
    weak var model: LibraryModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmStoppingDownloads(model?.session) ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
