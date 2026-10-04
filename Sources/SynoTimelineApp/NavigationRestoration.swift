import Foundation
import SynologyAPI

struct PhotoTimelineRestorationAnchor: Codable, Equatable {
    let itemID: Int64?
    let dayID: String
    let sectionOffsetHint: Int?
    let localOffset: Double
    let sectionFraction: Double
}

enum RestorableNavigationAnchor: Codable, Equatable {
    case photoTimeline(PhotoTimelineRestorationAnchor)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case photoTimeline }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .photoTimeline:
            self = .photoTimeline(try container.decode(PhotoTimelineRestorationAnchor.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .photoTimeline(let anchor):
            try container.encode(Kind.photoTimeline, forKey: .kind)
            try container.encode(anchor, forKey: .value)
        }
    }
}

struct RestorableAppNavigationState: Codable, Equatable {
    static let currentVersion = 1

    var version = currentVersion
    var selectedDestinationID = PhotoCollectionDescriptor.personalLibrary.restorationID
    var anchorsByDestinationID: [String: RestorableNavigationAnchor] = [:]

    private enum CodingKeys: String, CodingKey {
        case version, selectedDestinationID, anchorsByDestinationID
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        selectedDestinationID = try container.decodeIfPresent(String.self, forKey: .selectedDestinationID)
            ?? PhotoCollectionDescriptor.personalLibrary.restorationID
        anchorsByDestinationID = [:]
        if let anchors = try? container.nestedContainer(
            keyedBy: DestinationCodingKey.self,
            forKey: .anchorsByDestinationID
        ) {
            for key in anchors.allKeys {
                // A removed or future anchor kind must not prevent the remaining destinations from restoring.
                if let anchor = try? anchors.decode(RestorableNavigationAnchor.self, forKey: key) {
                    anchorsByDestinationID[key.stringValue] = anchor
                }
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(selectedDestinationID, forKey: .selectedDestinationID)
        var anchors = container.nestedContainer(
            keyedBy: DestinationCodingKey.self,
            forKey: .anchorsByDestinationID
        )
        for (destination, anchor) in anchorsByDestinationID {
            try anchors.encode(anchor, forKey: DestinationCodingKey(destination))
        }
    }
}

private struct DestinationCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

extension PhotoCollectionDescriptor {
    var restorationID: String {
        switch self {
        case .personalLibrary: "personal-library"
        case .favorites: "favorites"
        }
    }

    init?(restorationID: String) {
        switch restorationID {
        case "personal-library": self = .personalLibrary
        case "favorites": self = .favorites
        default: return nil
        }
    }
}

@MainActor
final class NavigationRestorationStore: ObservableObject {
    static let defaultsKey = "appNavigationState"

    private let defaults: UserDefaults
    private let key: String
    private(set) var state: RestorableAppNavigationState

    init(defaults: UserDefaults = .standard, key: String = defaultsKey) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(RestorableAppNavigationState.self, from: data),
           decoded.version <= RestorableAppNavigationState.currentVersion {
            state = decoded
        } else {
            state = RestorableAppNavigationState()
        }
    }

    var selectedCollection: PhotoCollectionDescriptor {
        PhotoCollectionDescriptor(restorationID: state.selectedDestinationID) ?? .personalLibrary
    }

    func select(_ collection: PhotoCollectionDescriptor) {
        state.selectedDestinationID = collection.restorationID
        save()
    }

    func timelineAnchor(for collection: PhotoCollectionDescriptor) -> PhotoTimelineRestorationAnchor? {
        guard case .photoTimeline(let anchor) = state.anchorsByDestinationID[collection.restorationID] else {
            return nil
        }
        return anchor
    }

    func setTimelineAnchor(_ anchor: PhotoTimelineRestorationAnchor,
                           for collection: PhotoCollectionDescriptor) {
        state.anchorsByDestinationID[collection.restorationID] = .photoTimeline(anchor)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
