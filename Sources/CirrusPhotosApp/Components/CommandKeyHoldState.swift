import AppKit
import Observation

/// Whether Command alone has been held briefly with no other key, which reveals the sidebar
/// album shortcuts. The delay keeps badges from flashing during ordinary Command shortcuts.
@MainActor @Observable
final class CommandKeyHoldState {
    private(set) var isShowingShortcuts = false
    @ObservationIgnored var delay: TimeInterval = 0.25
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pending: DispatchWorkItem?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(type: event.type, flags: event.modifierFlags,
                         characters: event.type == .keyDown ? event.charactersIgnoringModifiers : nil)
            return event
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reset() }
            })
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        reset()
    }

    /// A sidebar album shortcut (Command-1 to 9) keeps the badges up so several can follow.
    func handle(type: NSEvent.EventType, flags: NSEvent.ModifierFlags, characters: String? = nil) {
        let modifiers = flags.intersection([.command, .option, .control, .shift, .function])
        if type == .keyDown, modifiers == .command, isShowingShortcuts,
           let characters, characters.count == 1, ("1"..."9").contains(characters) { return }
        guard type == .flagsChanged, modifiers == .command else { reset(); return }
        guard pending == nil, !isShowingShortcuts else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pending != nil else { return }
            self.pending = nil
            self.isShowingShortcuts = true
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func reset() {
        pending?.cancel()
        pending = nil
        if isShowingShortcuts { isShowingShortcuts = false }
    }
}
