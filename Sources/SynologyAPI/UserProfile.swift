import Foundation

public struct PhotosUserProfile: Decodable, Sendable {
    public let id: Int64
    public let uid: Int64
    public let name: String
    public let enabled: Bool
    public let profile: Profile?
    public struct Profile: Decodable, Sendable {
        public let photo: String?
    }
}
