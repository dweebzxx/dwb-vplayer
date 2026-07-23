import Foundation

/// Pure projection/filter helper for the queue page display.
///
/// Takes plain values and returns plain projected results.
/// Owns no AppKit views, UserDefaults, timers, or playback delegation.
enum QueueDisplayProjection {

    enum Row: Equatable {
        case section(String)
        case item(displayIndex: Int)

        var displayIndex: Int? {
            guard case let .item(displayIndex) = self else { return nil }
            return displayIndex
        }
    }

    struct DeletionPlan: Equatable {
        let descendingDisplayIndices: [Int]
        let resultingCurrentDisplayIndex: Int
        let removesCurrentItem: Bool
    }

    /// Returns (displayIndex, element) pairs from `items` that pass the search
    /// and bookmark filter, preserving original index ordering.
    ///
    /// - Parameters:
    ///   - items: The full ordered item collection.
    ///   - displayName: Extracts the filterable display name from an item.
    ///   - urlPath: Extracts the standardized file path used for bookmark matching.
    ///   - query: Current search text; empty string means all items match the search.
    ///   - bookmarkedPaths: Set of standardized file paths the user has bookmarked.
    ///   - bookmarkFilterEnabled: When true, only bookmarked items are included.
    static func filteredPairs<T>(
        from items: [T],
        displayName: (T) -> String,
        urlPath: (T) -> String,
        query: String,
        bookmarkedPaths: Set<String>,
        bookmarkFilterEnabled: Bool
    ) -> [(Int, T)] {
        var result: [(Int, T)] = []
        for (offset, item) in items.enumerated() {
            let matchesSearch = query.isEmpty
                || displayName(item).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            let matchesBookmark = !bookmarkFilterEnabled
                || bookmarkedPaths.contains(urlPath(item))
            if matchesSearch && matchesBookmark {
                result.append((offset, item))
            }
        }
        return result
    }

    /// Returns whether drag-reorder is permitted given the current sort and filter state.
    ///
    /// Manual reorder is only allowed when the sort mode is manual and no search
    /// query or bookmark filter is active, because filtered views omit rows whose
    /// display indices the caller still owns — reordering into them would be ambiguous.
    static func allowsManualReorder(
        isManualSort: Bool,
        query: String,
        bookmarkFilterEnabled: Bool
    ) -> Bool {
        isManualSort && query.isEmpty && !bookmarkFilterEnabled
    }

    /// Builds the sectioned Queue Page row projection while retaining the original
    /// display indices used by controller commands.
    static func sectionedRows(
        displayIndices: [Int],
        currentDisplayIndex: Int,
        filterActive: Bool
    ) -> [Row] {
        guard !displayIndices.isEmpty else { return [] }
        var rows: [Row] = []

        if !filterActive && currentDisplayIndex >= 0 {
            let previous = displayIndices.filter { $0 < currentDisplayIndex }
            rows.append(.section("PREVIOUS"))
            if previous.isEmpty {
                rows.append(.section("No previous"))
            } else {
                rows.append(contentsOf: previous.map(Row.item))
            }
        }

        if displayIndices.contains(currentDisplayIndex) {
            rows.append(.section("NOW PLAYING"))
            rows.append(.item(displayIndex: currentDisplayIndex))
        }

        let upcoming = filterActive
            ? displayIndices.filter { $0 != currentDisplayIndex }
            : displayIndices.filter { $0 > currentDisplayIndex }
        if !upcoming.isEmpty {
            rows.append(.section("UP NEXT"))
            rows.append(contentsOf: upcoming.map(Row.item))
        }
        return rows
    }

    static func displayIndices(forVisibleRows selectedRows: IndexSet, in rows: [Row]) -> [Int] {
        selectedRows.compactMap { row in
            guard rows.indices.contains(row) else { return nil }
            return rows[row].displayIndex
        }
    }

    /// AppKit hardware key codes accepted by the Queue Page removal command.
    /// 51 is Delete/Backspace and 117 is Forward Delete.
    static func isDeletionKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == 51 || keyCode == 117
    }

    static func nearestSelectableRow(anchor: Int, in rows: [Row]) -> Int? {
        guard !rows.isEmpty else { return nil }
        let clampedAnchor = min(max(0, anchor), rows.count - 1)
        if rows[clampedAnchor].displayIndex != nil { return clampedAnchor }

        for distance in 1..<rows.count {
            let after = clampedAnchor + distance
            if rows.indices.contains(after), rows[after].displayIndex != nil { return after }
            let before = clampedAnchor - distance
            if rows.indices.contains(before), rows[before].displayIndex != nil { return before }
        }
        return nil
    }

    /// Mirrors the controller's established descending, one-at-a-time removal policy.
    static func deletionPlan(
        itemCount: Int,
        currentDisplayIndex: Int,
        requestedDisplayIndices: [Int]
    ) -> DeletionPlan {
        let descending = Array(Set(requestedDisplayIndices.filter { $0 >= 0 && $0 < itemCount })).sorted(by: >)
        var count = itemCount
        var current = currentDisplayIndex
        var removesCurrent = false

        for index in descending {
            guard index < count else { continue }
            if index == current {
                removesCurrent = true
                count -= 1
                current = count == 0 ? -1 : min(index, count - 1)
            } else {
                count -= 1
                if index < current {
                    current -= 1
                } else if current >= count {
                    current = count - 1
                }
            }
        }

        return DeletionPlan(
            descendingDisplayIndices: descending,
            resultingCurrentDisplayIndex: current,
            removesCurrentItem: removesCurrent
        )
    }
}
