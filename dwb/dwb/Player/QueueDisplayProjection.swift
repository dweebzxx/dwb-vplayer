import Foundation

/// Pure projection/filter helper for the queue page display.
///
/// Takes plain values and returns plain projected results.
/// Owns no AppKit views, UserDefaults, timers, or playback delegation.
enum QueueDisplayProjection {

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
}
