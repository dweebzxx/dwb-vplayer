import Foundation

extension Notification.Name {
    static let bookmarkDidChange = Notification.Name("com.dwb.dwb.bookmarkDidChange")
}

/// Persistent bookmark store backed by UserDefaults.
/// Bookmarks are keyed by standardized file path; all media types are supported.
/// All methods must be called on the main thread.
final class BookmarkStore {

    static let shared = BookmarkStore()

    private let defaultsKey = "com.dwb.bookmarkedPaths"

    private var pathSet: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: defaultsKey)
        }
    }

    private init() {}

    // MARK: - Public API

    func isBookmarked(url: URL) -> Bool {
        pathSet.contains(url.standardizedFileURL.path)
    }

    func toggleBookmark(url: URL) {
        let path = url.standardizedFileURL.path
        var current = pathSet
        if current.contains(path) {
            current.remove(path)
        } else {
            current.insert(path)
        }
        pathSet = current
        NotificationCenter.default.post(name: .bookmarkDidChange, object: nil)
    }

    func bookmarkedPaths() -> Set<String> {
        pathSet
    }
}
