import Foundation

public enum LibrarySelectionDirection: Sendable {
    case left, right, up, down
}

/// Collection-ordinal selection. `IndexSet` stores normalized disjoint ranges, so large
/// keyboard ranges do not retain item metadata or grow one entry per selected photo.
public struct LibrarySelection: Equatable, Sendable {
    public private(set) var indexes = IndexSet()
    public private(set) var generation: String?
    public private(set) var extensionBorder: Int?
    public private(set) var extensionCursor: Int?
    public private(set) var extensionBaseline: IndexSet?

    public init() {}
    public var count: Int { indexes.count }
    public var first: Int? { indexes.first }
    public var last: Int? { indexes.last }
    public func contains(_ ordinal: Int) -> Bool { indexes.contains(ordinal) }

    public mutating func bind(to generation: String) {
        guard self.generation != generation else { return }
        self.generation = generation
        indexes.removeAll()
        endExtension()
    }

    public mutating func invalidate() {
        generation = nil
        indexes.removeAll()
        endExtension()
    }

    public mutating func replace(with ordinal: Int?) {
        indexes.removeAll()
        if let ordinal { indexes.insert(ordinal) }
        endExtension()
    }

    public mutating func add(_ ordinal: Int) {
        indexes.insert(ordinal)
        endExtension()
    }

    public mutating func toggle(_ ordinal: Int) {
        if indexes.contains(ordinal) { indexes.remove(ordinal) }
        else { indexes.insert(ordinal) }
        endExtension()
    }

    /// Adds the inclusive reading-order range from the selected item nearest to
    /// `ordinal`. If there is no existing selection, the target becomes selected.
    public mutating func addRangeFromClosestSelection(to ordinal: Int) {
        guard !indexes.isEmpty else {
            add(ordinal)
            return
        }
        if indexes.contains(ordinal) {
            endExtension()
            return
        }
        let lower = indexes.integerLessThan(ordinal)
        let upper = indexes.integerGreaterThan(ordinal)
        let anchor: Int
        switch (lower, upper) {
        case let (lower?, upper?):
            anchor = ordinal - lower <= upper - ordinal ? lower : upper
        case let (lower?, nil):
            anchor = lower
        case let (nil, upper?):
            anchor = upper
        case (nil, nil):
            anchor = ordinal
        }
        indexes.insert(integersIn: min(anchor, ordinal)...max(anchor, ordinal))
        endExtension()
    }

    public mutating func selectAll(count: Int) {
        indexes = count > 0 ? IndexSet(integersIn: 0..<count) : IndexSet()
        endExtension()
    }

    public mutating func replace(with values: IndexSet) {
        indexes = values
        endExtension()
    }

    public mutating func toggle(_ hits: IndexSet, against baseline: IndexSet) {
        var result = baseline
        result.formSymmetricDifference(hits)
        indexes = result
        endExtension()
    }

    @discardableResult
    public mutating func move(_ direction: LibrarySelectionDirection, extending: Bool,
                              in index: LibraryIndex, columns: Int, groupsByDay: Bool,
                              firstVisible: Int?) -> Int? {
        if indexes.isEmpty {
            guard let start = firstVisible ?? (index.totalCount > 0 ? 0 : nil) else { return nil }
            indexes.insert(start)
            if extending {
                extensionBorder = start
                extensionCursor = start
                extensionBaseline = indexes
            }
            return start
        }
        if !extending {
            endExtension()
            let border = (direction == .left || direction == .up) ? indexes.first : indexes.last
            guard let border else { return nil }
            let destination = index.destination(from: border, direction: direction,
                                                columns: columns, groupsByDay: groupsByDay) ?? border
            indexes = IndexSet(integer: destination)
            return destination
        }
        if extensionBorder == nil {
            extensionBorder = (direction == .left || direction == .up) ? indexes.first : indexes.last
            extensionCursor = extensionBorder
            extensionBaseline = indexes
        }
        guard let border = extensionBorder, let cursor = extensionCursor,
              let destination = index.destination(from: cursor, direction: direction,
                                                   columns: columns, groupsByDay: groupsByDay) else { return extensionCursor }
        extensionCursor = destination
        var result = extensionBaseline ?? indexes
        result.insert(integersIn: min(border, destination)...max(border, destination))
        indexes = result
        return destination
    }

    public mutating func endExtension() {
        extensionBorder = nil
        extensionCursor = nil
        extensionBaseline = nil
    }
}
