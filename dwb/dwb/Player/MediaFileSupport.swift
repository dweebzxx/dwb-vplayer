import Foundation
import AVFoundation

enum MediaFileSupport {
    struct DurationMetadata {
        let seconds: Double?
        let displayString: String
    }

    /// Extensions recognised by this player, aligned with the VLCKit capability set documented in README.md.
    static let supportedExtensions: Set<String> = [
        "mp4", "mov", "avi", "flv", "wmv", "mkv", "ts", "mpg"
    ]

    static let durationLoadingText = "Loading..."
    static let durationUnknownText = "Unknown"
    private static let stableDurationAttempts = 8
    private static let stableDurationSampleDelayNs: UInt64 = 400_000_000
    private static let stableDurationDeltaTolerance = 0.2

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Recursively enumerate `folder`, collect regular files with supported extensions,
    /// sort the full paths lexicographically (case-sensitive), and return the first one.
    ///
    /// Ordering rule: case-sensitive lexicographic sort of absolute paths.
    /// This is deterministic and reproducible given the same folder contents.
    /// Returns nil when the folder is empty or contains no supported media files.
    static func firstSupportedFile(inFolder folder: URL) -> URL? {
        sortedSupportedFiles(inFolder: folder).first
    }

    /// Returns all supported media files in `folder` (recursive), sorted by absolute path
    /// (case-sensitive lexicographic order). Same ordering rule as `firstSupportedFile`.
    static func sortedSupportedFiles(inFolder folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if isSupported(url) { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: - Metadata helpers

    /// Returns a human-readable file size string for `url` (e.g. "12.3 MB").
    /// Reads `.fileSizeKey` synchronously via URLResourceValues. Returns "–" on failure.
    static func fileSizeString(for url: URL) -> String {
        guard let size = fileSizeBytes(for: url), size > 0 else { return "–" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func fileSizeBytes(for url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0 else { return nil }
        return Int64(size)
    }

    /// MPEG program streams can report provisional durations before indexing settles.
    /// Keep their UI in a loading state until two precise reads agree on the same
    /// displayed duration; otherwise fall back to "Unknown" after a bounded wait.
    static func needsStableDuration(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "mpg"
    }

    /// Asynchronously loads the media duration for `url` via AVFoundation.
    /// The `completion` block is always called on the main queue.
    /// Returns a formatted string like "1:23:45" or "Unknown" on failure.
    static func loadDuration(for url: URL, completion: @escaping (String) -> Void) {
        loadDurationMetadata(for: url) { metadata in
            completion(metadata.displayString)
        }
    }

    static func loadDurationMetadata(for url: URL, completion: @escaping (DurationMetadata) -> Void) {
        if needsStableDuration(url) {
            loadStableDurationMetadata(for: url, completion: completion)
            return
        }

        Task {
            let secs = await loadDurationSeconds(for: url, precise: false)
            let result = DurationMetadata(seconds: secs,
                                          displayString: secs.map(Self.formatDuration) ?? durationUnknownText)
            await MainActor.run { completion(result) }
        }
    }

    private static func loadStableDurationMetadata(for url: URL,
                                                   completion: @escaping (DurationMetadata) -> Void) {
        Task {
            var previous: (seconds: Double, display: String)?
            for _ in 0..<stableDurationAttempts {
                if let secs = await loadDurationSeconds(for: url, precise: true) {
                    let display = Self.formatDuration(secs)
                    if let prior = previous,
                       prior.display == display,
                       abs(prior.seconds - secs) <= stableDurationDeltaTolerance {
                        let result = DurationMetadata(seconds: secs, displayString: display)
                        await MainActor.run { completion(result) }
                        return
                    }
                    previous = (secs, display)
                }
                try? await Task.sleep(nanoseconds: stableDurationSampleDelayNs)
            }
            let result = DurationMetadata(seconds: nil, displayString: durationUnknownText)
            await MainActor.run { completion(result) }
        }
    }

    private static func loadDurationSeconds(for url: URL, precise: Bool) async -> Double? {
        let asset = AVURLAsset(url: url,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: precise])
        do {
            let duration = try await asset.load(.duration)
            let secs = CMTimeGetSeconds(duration)
            return (secs.isFinite && secs > 0) ? secs : nil
        } catch {
            return nil
        }
    }

    /// Formats a duration in seconds to "H:MM:SS" or "M:SS".
    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func formatClockDuration(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        let h = clamped / 3600
        let m = (clamped % 3600) / 60
        let s = clamped % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // MARK: - Neighbor lookup

    /// For a known media file URL, returns the previous and next media files in the same
    /// containing folder using the same lexicographic sort as `sortedSupportedFiles`.
    ///
    /// Returns `(nil, nil)` if the URL is not found among siblings or has no neighbours.
    static func neighbors(of url: URL) -> (prev: URL?, next: URL?) {
        let folder = url.deletingLastPathComponent()
        let files = sortedSupportedFiles(inFolder: folder)
        guard let idx = files.firstIndex(where: { $0.path == url.path }) else {
            return (nil, nil)
        }
        let prev = idx > 0 ? files[idx - 1] : nil
        let next = idx < files.count - 1 ? files[idx + 1] : nil
        return (prev, next)
    }
}
