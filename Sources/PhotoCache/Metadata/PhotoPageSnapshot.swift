import Foundation
import SynologyAPI

public struct PhotoItemSlot: Sendable {
    public let itemID: Int64
    public let item: PhotoItem?
    public let verified: Bool
    public init(itemID: Int64, item: PhotoItem?, verified: Bool) {
        precondition(item == nil || item?.id == itemID)
        self.itemID = itemID; self.item = item; self.verified = verified && item != nil
    }
}

/// Ordered membership is independent of evictable canonical details.
public struct PhotoPageSnapshot: Sendable {
    public let address: DayPageAddress
    public let membershipRevision: UInt64
    public let membershipVerified: Bool
    public let slots: [PhotoItemSlot]
    public func slot(at offset: Int) -> PhotoItemSlot? {
        slots.indices.contains(offset) ? slots[offset] : nil
    }
    /// Complete materialization only; positional consumers must use slots.
    public var completeItems: [PhotoItem]? {
        var items: [PhotoItem] = []
        items.reserveCapacity(slots.count)
        for slot in slots {
            guard let item = slot.item else { return nil }
            items.append(item)
        }
        return items
    }
    public var verified: Bool { membershipVerified && !slots.isEmpty && slots.allSatisfy(\.verified) }
    public init(address: DayPageAddress, membershipRevision: UInt64,
                membershipVerified: Bool, slots: [PhotoItemSlot]) {
        precondition(slots.count <= address.capacity)
        self.address = address; self.membershipRevision = membershipRevision
        self.membershipVerified = membershipVerified; self.slots = slots
    }
}
