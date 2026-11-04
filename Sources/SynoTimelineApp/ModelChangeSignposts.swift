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
            signposter.emitEvent("Model change", "\(name, privacy: .public)")
        })
    }

    /// Marks a view body evaluation; call from a view body with `let _ = ...`.
    nonisolated static func body(_ name: StaticString) {
        SynologyDiagnostics.browserSignposts.emitEvent(name)
    }
}
