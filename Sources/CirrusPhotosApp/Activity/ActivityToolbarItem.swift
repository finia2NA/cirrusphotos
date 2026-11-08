import SynologyAPI
import AppKit
import PhotoCache
import SwiftUI

/// The NAS connection as the toolbar and Activity panel describe it.
enum ConnectionState: Equatable {
    case connecting(String)
    case connected
    /// Signed in, but the library or the last Refresh failed; cached content is shown.
    case degraded(label: String, detail: String)
    case failed(label: String, detail: String)

    var label: String {
        switch self {
        case .connecting(let label): label
        case .connected: "Connected"
        case .degraded(let label, _), .failed(let label, _): label
        }
    }

    var detail: String? {
        switch self {
        case .connecting, .connected: nil
        case .degraded(_, let detail), .failed(_, let detail): detail
        }
    }

    /// The outline symbol; the toolbar uses its `.fill` variant while the panel is open.
    var symbol: String {
        switch self {
        case .connecting, .connected: "icloud"
        case .degraded, .failed: "icloud.slash"
        }
    }

    static let syncingSymbol = "arrow.trianglehead.2.clockwise.rotate.90.icloud"
}

extension LibraryModel {
    var connectionState: ConnectionState {
        let libraryError = error(for: .library(.personal))
        switch authenticationStatus {
        case .notStarted:
            if let libraryError { return .failed(label: "Library unavailable", detail: libraryError) }
            return .connecting("Opening library…")
        case .loggingIn:
            return .connecting("Logging in…")
        case .signedIn:
            if let libraryError { return .degraded(label: "Metadata unavailable", detail: libraryError) }
            if let refreshFailure { return .degraded(label: "Refresh failed", detail: refreshFailure) }
            return .connected
        case .failed(let message):
            return .failed(label: "Login failed", detail: message)
        case .unreachable(let message):
            return .failed(label: "NAS unreachable", detail: message)
        case .needsSignIn(let message):
            return .failed(label: "Sign-in required", detail: message)
        case .untrustedCertificate:
            return .failed(label: "Certificate not trusted",
                           detail: SynologyAPIError.untrustedCertificate(sha256: "").localizedDescription)
        }
    }
}

/// One toolbar item for connection state, running work and unseen failures. It opens the
/// Activity panel.
struct ActivityToolbarItem: View {
    @Environment(LibraryModel.self) private var library
    @Bindable var activity: ActivityCenter

    var body: some View {
        let state = library.connectionState
        Button { activity.togglePresented() } label: {
            ActivityGlyph(state: state,
                          running: activity.runningCount > 0 || library.isRefreshing || library.isLoading,
                          fraction: activity.singleTransferFraction,
                          failures: !activity.attention.isEmpty,
                          unseenFailure: !activity.unseenFailureIDs.isEmpty,
                          open: activity.isPresented)
        }
        .help(helpText(state))
        .accessibilityLabel("Activity")
        .accessibilityValue(helpText(state))
        .popover(isPresented: $activity.isPresented, arrowEdge: .bottom) {
            ActivityPanelView(activity: activity).environment(library)
                .focusRingsOnlyForKeyboardNavigation()
        }
        // Native full screen hides the toolbar that anchors the panel; failures then only mark
        // the icon.
        .background(FullScreenObserver { fullScreen in
            if activity.canAutoPresent == fullScreen { activity.canAutoPresent = !fullScreen }
        })
    }

    private func helpText(_ state: ConnectionState) -> String {
        var parts = [state.label]
        let running = activity.runningCount
        if running > 0 { parts.append("\(running) running") }
        let failed = activity.attention.count
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}

/// A turning sync symbol while work runs; otherwise the connection symbol, or a cloud with an
/// exclamation mark while failures remain in the Activity tab. Filled while the panel is open.
/// A ring shows byte progress when one transfer reports it, and a dot unseen failures.
private struct ActivityGlyph: View {
    let state: ConnectionState
    let running: Bool
    let fraction: Double?
    let failures: Bool
    let unseenFailure: Bool
    let open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Separate branches give the rotating symbol its own identity. On one shared Image,
            // ending the rotate effect lets the current turn finish on the replacement symbol.
            if running {
                symbol(ConnectionState.syncingSymbol)
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: !reduceMotion)
            } else {
                symbol(idleSymbol)
                    .foregroundStyle(isConnecting ? .secondary : .primary)
            }
            if running, let fraction { ring(fraction) }
            if unseenFailure {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                    .offset(x: 10, y: -10)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var idleSymbol: String {
        switch state {
        case .degraded, .failed: state.symbol
        case .connecting, .connected: failures ? "exclamationmark.icloud" : state.symbol
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: open ? name + ".fill" : name)
            .font(.system(size: 14))
    }

    private var isConnecting: Bool {
        if case .connecting = state { return true }
        return false
    }

    private func ring(_ fraction: Double) -> some View {
        Circle()
            .trim(from: 0, to: max(0.02, min(fraction, 1)))
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 26, height: 26)
    }
}

/// Reports whether the hosting window is in native full screen.
private struct FullScreenObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.onChange = onChange }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observations: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.forEach(NotificationCenter.default.removeObserver)
            observations = []
            guard let window else { return }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        private func report() {
            onChange?(window?.styleMask.contains(.fullScreen) == true)
        }

        isolated deinit {
            observations.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
