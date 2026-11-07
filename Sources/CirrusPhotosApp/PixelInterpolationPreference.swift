import AppKit

enum PixelInterpolationPreference: String, CaseIterable, Hashable {
    case always
    case thumbnailsOnly
    case off

    var displayName: String {
        switch self {
        case .always: "Always"
        case .thumbnailsOnly: "Thumbnails Only"
        case .off: "Off"
        }
    }

    func imageInterpolation(isFullResolution: Bool) -> NSImageInterpolation {
        switch self {
        case .always:
            .high
        case .thumbnailsOnly:
            isFullResolution ? .none : .high
        case .off:
            .none
        }
    }
}
