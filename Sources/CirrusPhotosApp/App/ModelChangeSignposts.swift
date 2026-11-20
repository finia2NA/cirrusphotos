import Darwin
import MachO
import Combine
import OSLog
import SynologyAPI

/// Emits a "Model change" signpost event whenever an app-wide model announces a change,
/// so a trace shows which model caused window-wide SwiftUI updates (`make profile`).
@MainActor
final class ModelChangeSignposts {
    static let shared = ModelChangeSignposts()
    private var observed: Set<ObjectIdentifier> = []
    private var subscriptions: [AnyCancellable] = []

    func observe<Model: ObservableObject>(_ model: Model, name: String) where Model.ObjectWillChangePublisher == ObservableObjectPublisher {
        guard observed.insert(ObjectIdentifier(model)).inserted else { return }
        let signposter = SynologyDiagnostics.browserSignposts
        subscriptions.append(model.objectWillChange.sink { _ in
            // Only while a tool records: include the app frames that triggered the change
            // (the property setter and its callers) as binary offsets.
            guard signposter.isEnabled else { return }
            signposter.emitEvent("Model change", "\(name, privacy: .public) \(Self.appFrames(), privacy: .public)")
        })
    }

    /// The app binary's load address and `__TEXT` range, looked up once. Per-frame `dladdr`
    /// searched the symbol table and cost milliseconds of main thread per event.
    private static let appText: (base: UInt, text: Range<UInt>) = {
        let base = UInt(bitPattern: #dsohandle)
        var size: UInt = 0
        guard let start = getsegmentdata(#dsohandle.assumingMemoryBound(to: mach_header_64.self), "__TEXT", &size)
        else { return (base, base..<base) }
        let text = UInt(bitPattern: start)
        return (base, text..<text + size)
    }()

    /// Offsets of the first app-binary frames on the stack (innermost first), resolvable
    /// with `atos -o <binary> -l 0x100000000 <0x100000000 + offset>` against the same build.
    /// The app's Swift symbols are not exported, so `callStackSymbols` cannot name them.
    private static func appFrames(limit: Int = 8) -> String {
        let (base, text) = appText
        var frames: [String] = []
        for address in Thread.callStackReturnAddresses {
            let value = address.uintValue
            guard text.contains(value) else { continue }
            frames.append("0x" + String(value - base, radix: 16))
            if frames.count == limit { break }
        }
        return frames.joined(separator: ",")
    }

    /// Marks a view body evaluation; call from a view body with `let _ = ...`.
    nonisolated static func body(_ name: StaticString) {
        SynologyDiagnostics.browserSignposts.emitEvent(name)
    }
}
