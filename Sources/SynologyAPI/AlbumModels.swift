import Foundation

/// An incoming album and the recipient's current server-reported capabilities.
/// The reference is session-only and this type deliberately does not encode.
public struct IncomingAlbum: Decodable, Sendable {
    public let summary: AlbumSummary
    public let sharingReference: String
    public let access: AlbumAccessPermission

    private enum CodingKeys: String, CodingKey { case passphrase, additional }
    private struct Additional: Decodable { let accessPermission: AlbumAccessPermission
        enum CodingKeys: String, CodingKey { case accessPermission = "access_permission" }
    }

    public init(from decoder: Decoder) throws {
        let decoded = try AlbumSummary(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sharingReference = try container.decode(String.self, forKey: .passphrase)
        guard !sharingReference.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .passphrase, in: container, debugDescription: "Missing sharing reference")
        }
        let permission = try container.decode(Additional.self, forKey: .additional).accessPermission
        access = permission
        summary = decoded.asIncoming(canUpload: permission.upload, canDownload: permission.download)
    }
}

public struct AlbumAccessPermission: Decodable, Sendable, Equatable {
    public let view: Bool
    public let download: Bool
    public let upload: Bool
    public let manage: Bool
    public let own: Bool

    private enum CodingKeys: String, CodingKey { case view, download, upload, manage, own }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        view = try values.decodeIfPresent(Bool.self, forKey: .view) ?? false
        download = try values.decodeIfPresent(Bool.self, forKey: .download) ?? false
        upload = try values.decodeIfPresent(Bool.self, forKey: .upload) ?? false
        manage = try values.decodeIfPresent(Bool.self, forKey: .manage) ?? false
        own = try values.decodeIfPresent(Bool.self, forKey: .own) ?? false
    }
}

/// A Personal Space album as returned by `SYNO.Foto.Browse.Album method=list`.
public struct AlbumSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let itemCount: Int
    public let createTime: Int64?
    public let startTime: Int64?
    public let endTime: Int64?
    public let sortBy: String?
    public let sortDirection: String?
    public let thumbnail: ThumbnailInfo?
    public let type: String?
    public let ownerUserID: Int64?
    public let shared: Bool
    public let sharingInfo: AlbumSharingInfo?
    public let isIncoming: Bool
    /// Cached capabilities are provisional until the album list is verified.
    public let recipientCanUpload: Bool
    public let recipientCanDownload: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, additional, type, shared, isIncoming, recipientCanUpload, recipientCanDownload
        case ownerUserID = "owner_user_id"
        case itemCount = "item_count"
        case createTime = "create_time"
        case startTime = "start_time"
        case endTime = "end_time"
        case sortBy = "sort_by"
        case sortDirection = "sort_direction"
    }

    private struct Additional: Codable {
        let thumbnail: ThumbnailInfo?
        let sharingInfo: AlbumSharingInfo?
        enum CodingKeys: String, CodingKey { case thumbnail; case sharingInfo = "sharing_info" }
        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(thumbnail: ThumbnailInfo?, sharingInfo: AlbumSharingInfo?) {
            self.thumbnail = thumbnail
            self.sharingInfo = sharingInfo
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.thumbnail), try !container.decodeNil(forKey: .thumbnail) {
                let object = try container.nestedContainer(keyedBy: AnyKey.self, forKey: .thumbnail)
                thumbnail = object.allKeys.isEmpty ? nil : try container.decode(ThumbnailInfo.self, forKey: .thumbnail)
            } else {
                thumbnail = nil
            }
            sharingInfo = try container.decodeIfPresent(AlbumSharingInfo.self, forKey: .sharingInfo)
        }
    }

    public init(id: Int64, name: String, itemCount: Int,
                createTime: Int64? = nil, startTime: Int64? = nil, endTime: Int64? = nil,
                sortBy: String? = nil, sortDirection: String? = nil,
                thumbnail: ThumbnailInfo? = nil, type: String? = nil, ownerUserID: Int64? = nil,
                shared: Bool = false, sharingInfo: AlbumSharingInfo? = nil,
                isIncoming: Bool = false, recipientCanUpload: Bool = false, recipientCanDownload: Bool = false) {
        self.id = id
        self.name = name
        self.itemCount = itemCount
        self.createTime = createTime
        self.startTime = startTime
        self.endTime = endTime
        self.sortBy = sortBy
        self.sortDirection = sortDirection
        self.thumbnail = thumbnail
        self.type = type
        self.ownerUserID = ownerUserID
        self.shared = shared
        self.sharingInfo = sharingInfo
        self.isIncoming = isIncoming
        self.recipientCanUpload = recipientCanUpload
        self.recipientCanDownload = recipientCanDownload
    }

    /// Stable identity for navigation and persistence, excluding sharing credentials.
    public var collection: PhotoCollectionDescriptor? {
        if isIncoming {
            guard let ownerUserID else { return nil }
            return .incomingAlbum(ownerID: ownerUserID, albumID: id)
        }
        return .album(id)
    }

    func asIncoming(canUpload: Bool, canDownload: Bool) -> AlbumSummary {
        AlbumSummary(id: id, name: name, itemCount: itemCount, createTime: createTime,
                     startTime: startTime, endTime: endTime, sortBy: sortBy, sortDirection: sortDirection,
                     thumbnail: thumbnail, type: type, ownerUserID: ownerUserID, shared: shared,
                     sharingInfo: sharingInfo, isIncoming: true, recipientCanUpload: canUpload, recipientCanDownload: canDownload)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        ownerUserID = try container.decodeIfPresent(Int64.self, forKey: .ownerUserID)
        name = try container.decode(String.self, forKey: .name)
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
        createTime = try container.decodeIfPresent(Int64.self, forKey: .createTime)
        startTime = try container.decodeIfPresent(Int64.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Int64.self, forKey: .endTime)
        sortBy = try container.decodeIfPresent(String.self, forKey: .sortBy)
        sortDirection = try container.decodeIfPresent(String.self, forKey: .sortDirection)
        shared = try container.decodeIfPresent(Bool.self, forKey: .shared) ?? false
        isIncoming = try container.decodeIfPresent(Bool.self, forKey: .isIncoming) ?? false
        recipientCanUpload = try container.decodeIfPresent(Bool.self, forKey: .recipientCanUpload) ?? false
        recipientCanDownload = try container.decodeIfPresent(Bool.self, forKey: .recipientCanDownload) ?? false
        let additional = try container.decodeIfPresent(Additional.self, forKey: .additional)
        thumbnail = additional?.thumbnail
        sharingInfo = additional?.sharingInfo
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(ownerUserID, forKey: .ownerUserID)
        try container.encode(name, forKey: .name)
        try container.encode(itemCount, forKey: .itemCount)
        try container.encodeIfPresent(createTime, forKey: .createTime)
        try container.encodeIfPresent(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encodeIfPresent(sortBy, forKey: .sortBy)
        try container.encodeIfPresent(sortDirection, forKey: .sortDirection)
        try container.encode(shared, forKey: .shared)
        if isIncoming { try container.encode(true, forKey: .isIncoming) }
        if isIncoming && recipientCanUpload { try container.encode(true, forKey: .recipientCanUpload) }
        if isIncoming && recipientCanDownload { try container.encode(true, forKey: .recipientCanDownload) }
        if thumbnail != nil || sharingInfo != nil {
            try container.encode(Additional(thumbnail: thumbnail, sharingInfo: sharingInfo), forKey: .additional)
        }
    }
}

/// Server values are retained verbatim; unfamiliar roles and privacy values confer no authority.
public struct AlbumSharingInfo: Codable, Hashable, Sendable {
    public let privacyType: String?
    public let expiration: Int64?
    public let isExpired: Bool?
    public let enablePassword: Bool?
    public let permission: [AlbumSharingPermission]?
    public let owner: AlbumSharingOwner?
    public let reference: String?
    public let sharingLink: String?
    enum CodingKeys: String, CodingKey {
        case expiration, permission, owner
        case reference = "passphrase", sharingLink = "sharing_link"
        case privacyType = "privacy_type", isExpired = "is_expired", enablePassword = "enable_password"
    }
    // Sharing references and links are read from the NAS on demand and never cached.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(privacyType, forKey: .privacyType)
        try container.encodeIfPresent(expiration, forKey: .expiration)
        try container.encodeIfPresent(isExpired, forKey: .isExpired)
        try container.encodeIfPresent(enablePassword, forKey: .enablePassword)
        try container.encodeIfPresent(permission, forKey: .permission)
        try container.encodeIfPresent(owner, forKey: .owner)
    }
    public init(privacyType: String? = nil, expiration: Int64? = nil, isExpired: Bool? = nil,
                enablePassword: Bool? = nil, permission: [AlbumSharingPermission]? = nil,
                owner: AlbumSharingOwner? = nil, reference: String? = nil, sharingLink: String? = nil) {
        self.privacyType = privacyType; self.expiration = expiration; self.isExpired = isExpired
        self.enablePassword = enablePassword; self.permission = permission
        self.owner = owner; self.reference = reference; self.sharingLink = sharingLink
    }
}

public struct AlbumSharingPermission: Codable, Hashable, Sendable {
    /// Photos identity for profile lookup; distinct from the DSM principal ID.
    public let photosUserID: Int64?
    public let principalID: Int64?
    public let name: String
    public let role: String
    public let type: String
    enum CodingKeys: String, CodingKey { case name, role, type; case photosUserID = "db_id", principalID = "id" }
    public init(photosUserID: Int64?, principalID: Int64?, name: String, role: String, type: String) {
        self.photosUserID = photosUserID; self.principalID = principalID
        self.name = name; self.role = role; self.type = type
    }
}

public struct AlbumSharingOwner: Codable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public init(id: Int64, name: String) { self.id = id; self.name = name }
}

/// A DSM principal; its ID is not the Photos-internal user ID.
public struct SharingPrincipal: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let type: String
    public init(id: Int64, name: String, type: String) { self.id = id; self.name = name; self.type = type }
}

public struct AlbumSharingReference: Decodable, Sendable {
    public let passphrase: String
    public let sharingLink: String
    enum CodingKeys: String, CodingKey { case passphrase; case sharingLink = "sharing_link" }
}

public struct SharingPermissionChange: Codable, Hashable, Sendable {
    public struct Member: Codable, Hashable, Sendable {
        public let type: String
        public let id: Int64?
        public init(type: String, id: Int64? = nil) { self.type = type; self.id = id }
    }
    public let action: String
    public let role: String?
    public let member: Member
    public init(action: String, role: String? = nil, member: Member) {
        self.action = action; self.role = role; self.member = member
    }
}

/// Passwords are write-only and are never part of a persisted sharing snapshot.
public enum SharingPasswordChange: Sendable, Equatable {
    case unchanged
    case set(String)
    case clear
}
