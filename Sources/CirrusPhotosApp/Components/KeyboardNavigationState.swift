import AppKit
import SwiftUI

/// Whether the user is navigating by keyboard in a window: set by Tab, cleared by any
/// pointer click. Controls that should show a focus ring only then read `isActive`.
@MainActor @Observable
final class KeyboardNavigationState {
    var isActive = false

    /// The state after an event: Tab key-down activates, a pointer press deactivates,
    /// everything else leaves it unchanged.
    nonisolated static func isActive(after eventType: NSEvent.EventType, keyCode: UInt16, current: Bool) -> Bool {
        switch eventType {
        case .keyDown: keyCode == 48 ? true : current
        case .leftMouseDown, .rightMouseDown: false
        default: current
        }
    }

    func update(for eventType: NSEvent.EventType, keyCode: UInt16) {
        let next = Self.isActive(after: eventType, keyCode: keyCode, current: isActive)
        if next != isActive { isActive = next }
    }
}

private struct TracksKeyboardNavigation: ViewModifier {
    let initiallyActive: Bool
    @State private var state = KeyboardNavigationState()
    @State private var window: NSWindow?
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .environment(state)
            .onAppear { if initiallyActive { state.isActive = true } }
            .background(WindowReader(window: $window))
            .onChange(of: window, initial: true) { _, window in
                removeMonitor()
                guard let window else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
                    if let eventWindow = event.window,
                       eventWindow === window || eventWindow.sheetParent === window || eventWindow.parent === window {
                        let type = event.type
                        let code = event.type == .keyDown ? event.keyCode : 0
                        MainActor.assumeIsolated { state.update(for: type, keyCode: code) }
                    }
                    return event
                }
            }
            .onDisappear { removeMonitor() }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView { WindowReportingView() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? WindowReportingView)?.onWindow = { window = $0 }
    }

    private final class WindowReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)? { didSet { report() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        private func report() {
            let window = window
            DispatchQueue.main.async { [onWindow] in onWindow?(window) }
        }
    }
}

private struct KeyboardFocusRing: ViewModifier {
    @Environment(KeyboardNavigationState.self) private var state: KeyboardNavigationState?

    func body(content: Content) -> some View {
        content.focusEffectDisabled(!(state?.isActive ?? false))
    }
}

extension View {
    /// Installs keyboard-navigation tracking for this view's window, its sheets and child
    /// windows, and shares its state. `initiallyActive` starts with rings visible.
    func tracksKeyboardNavigation(initiallyActive: Bool = false) -> some View {
        modifier(TracksKeyboardNavigation(initiallyActive: initiallyActive))
    }

    /// Hides every focus ring in this view's window until Tab is pressed, and again after
    /// the next pointer click. `initiallyShowsFocus` is for confirm/deny modals, whose
    /// ring is visible on load.
    func focusRingsOnlyForKeyboardNavigation(initiallyShowsFocus: Bool = false) -> some View {
        keyboardFocusRing().tracksKeyboardNavigation(initiallyActive: initiallyShowsFocus)
    }

    /// Shows the focus ring only after Tab was pressed, until the next pointer click.
    func keyboardFocusRing() -> some View { modifier(KeyboardFocusRing()) }
}
