#if CIRRUS_DISTRIBUTION
import Combine
import Sparkle
import SwiftUI

/// The app's single Sparkle updater, created at launch and shared by the app menu and
/// Settings ▸ About. Distribution builds only: development builds never update themselves.
/// The feed and public key come from the Info.plist (`SUFeedURL`, `SUPublicEDKey`, written by
/// scripts/run.sh); Sparkle asks on the second launch whether to check automatically, and
/// automatic downloading stays off unless the user turns it on.
@MainActor
final class SoftwareUpdater: ObservableObject {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?

    private var updater: SPUUpdater { controller.updater }

    init() {
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
        // lastUpdateCheckDate is not KVO compliant; it changes when a check finishes,
        // which also flips canCheckForUpdates back on.
        $canCheckForUpdates.map { _ in updater.lastUpdateCheckDate }.assign(to: &$lastUpdateCheckDate)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) { updater.automaticallyChecksForUpdates = enabled }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) { updater.automaticallyDownloadsUpdates = enabled }
}

/// App menu ▸ Check for Updates…, after About.
struct SoftwareUpdateCommands: Commands {
    @ObservedObject var updater: SoftwareUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

/// The update controls in Settings ▸ About.
struct SoftwareUpdateSection: View {
    @EnvironmentObject private var updater: SoftwareUpdater

    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticallyChecksForUpdates($0) }))
            Toggle("Automatically download and install updates", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.setAutomaticallyDownloadsUpdates($0) }))
                .disabled(!updater.automaticallyChecksForUpdates)
            LabeledContent {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } label: {
                if let date = updater.lastUpdateCheckDate {
                    Text("Last checked: \(date, format: .relative(presentation: .named))")
                } else {
                    Text("Last checked: Never")
                }
            }
        }
    }
}
#endif
