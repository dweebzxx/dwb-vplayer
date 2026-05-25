import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import VLCKitSPM

enum MediaFileSupport {
    struct DurationMetadata {
        let seconds: Double?
        let displayString: String
    }

    struct GIFPlaybackMetadata {
        let frameCount: Int
        let loopDurationSeconds: Double
        let totalPlaybackDurationSeconds: Double
    }

    struct GIFAnimation {
        let frames: [CGImage]
        let frameDurations: [TimeInterval]
        let loopDurationSeconds: TimeInterval
    }

    /// Video-only extensions backed by VLCKit.
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "avi", "flv", "f4v", "wmv", "asf", "mkv",
        "ts", "mts", "m2ts", "m2t", "mpg", "3gp", "3g2", "vob",
        "ogv", "ogm"
    ]

    /// Image extensions displayed as slideshow items via NSImage/AppKit.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jfif", "png", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp"
    ]

    /// All supported extensions: videos and images.
    static let supportedExtensions: Set<String> = videoExtensions.union(imageExtensions)

    /// Content types used by file-picking UI. Extension checks remain the
    /// canonical ingestion filter so custom/legacy containers keep working.
    static var supportedContentTypes: [UTType] {
        supportedExtensions.sorted().compactMap { ext in
            let conformance: UTType = videoExtensions.contains(ext) ? .movie : .image
            return UTType(filenameExtension: ext, conformingTo: conformance)
                ?? UTType(filenameExtension: ext)
        }
    }

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isGIF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gif"
    }

    static let durationLoadingText = "Loading..."
    static let durationUnknownText = "--:--"
    private static let stableDurationAttempts = 8
    private static let stableDurationSampleDelayNs: UInt64 = 400_000_000
    private static let stableDurationDeltaTolerance = 0.2
    private static let vlcDurationFallbackExtensions: Set<String> = [
        "avi", "flv", "f4v", "mkv", "mpg", "mpeg", "wmv", "asf",
        "mts", "m2ts", "m2t", "vob", "3gp", "3g2", "ogv", "ogm"
    ]
    private static let vlcDurationParseTimeoutMs: Int32 = 2_000
    private static let defaultGIFFrameDelaySeconds = 0.1
    private static let minimumGIFFrameDelaySeconds = 0.02
    private static let fallbackGIFLoopDurationSeconds = 1.0

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
    /// Reads `.fileSizeKey` synchronously via URLResourceValues. Returns "--" on failure.
    static func fileSizeString(for url: URL) -> String {
        guard let size = fileSizeBytes(for: url), size > 0 else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func fileSizeBytes(for url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0 else { return nil }
        return Int64(size)
    }

    /// MPEG program streams can report provisional durations before indexing settles.
    /// Keep their UI in a loading state until two precise reads agree on the same
    /// displayed duration; otherwise fall back to "--:--" after a bounded wait.
    static func needsStableDuration(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "mpg"
    }

    /// Asynchronously loads the media duration for `url` via AVFoundation.
    /// The `completion` block is always called on the main queue.
    /// Returns a formatted string like "1:23:45" or "--:--" on failure.
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
            let avSeconds = await loadDurationSeconds(for: url, precise: false)
            let secs: Double?
            if let avSeconds {
                secs = avSeconds
            } else {
                secs = await loadVLCDurationSecondsIfNeeded(for: url)
            }
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
            let secs = await loadVLCDurationSecondsIfNeeded(for: url)
            let result = DurationMetadata(seconds: secs,
                                          displayString: secs.map(Self.formatDuration) ?? durationUnknownText)
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

    private static func loadVLCDurationSecondsIfNeeded(for url: URL) async -> Double? {
        let ext = url.pathExtension.lowercased()
        guard vlcDurationFallbackExtensions.contains(ext) else { return nil }

        let seconds = await loadVLCDurationSeconds(for: url)
        let outcome = seconds.map { "resolved \(Self.formatDuration($0))" } ?? "unresolved"
        await MainActor.run {
            DebugConsoleController.log("metadata", "durationFallback: ext=\(ext) via=vlc \(outcome)")
        }
        return seconds
    }

    private static func loadVLCDurationSeconds(for url: URL) async -> Double? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let media = VLCMedia(url: url)
                let parseResult = media.parse(options: VLCMediaParsingOptions(rawValue: 0),
                                              timeout: vlcDurationParseTimeoutMs)
                guard parseResult == 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                let deadline = Date(timeIntervalSinceNow: Double(vlcDurationParseTimeoutMs) / 1_000.0)
                let length = media.lengthWait(until: deadline)
                let milliseconds = length.value?.doubleValue ?? 0
                media.parseStop()
                let seconds = milliseconds / 1_000.0
                continuation.resume(returning: seconds.isFinite && seconds > 0 ? seconds : nil)
            }
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

    static func formatPlaybackDuration(_ seconds: Double) -> String {
        formatDuration(seconds)
    }

    static func formatClockDuration(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        let h = clamped / 3600
        let m = (clamped % 3600) / 60
        let s = clamped % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Formats seconds as "M:SS" (or "H:MM:SS" for ≥1 hour). Used for image duration display.
    static func formatShortDuration(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let h = clamped / 3600
        let m = (clamped % 3600) / 60
        let s = clamped % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func configuredImageDurationMetadata(for url: URL,
                                                stillImageDurationSeconds: Int,
                                                gifLoopCount: Int) -> DurationMetadata {
        if isGIF(url) {
            if let metadata = gifPlaybackMetadata(for: url, loopCount: gifLoopCount) {
                return DurationMetadata(seconds: metadata.totalPlaybackDurationSeconds,
                                        displayString: formatPlaybackDuration(metadata.totalPlaybackDurationSeconds))
            }
            let fallback = fallbackGIFPlaybackDurationSeconds(loopCount: gifLoopCount)
            return DurationMetadata(seconds: fallback,
                                    displayString: formatPlaybackDuration(fallback))
        }

        let clamped = max(0, stillImageDurationSeconds)
        return DurationMetadata(seconds: Double(clamped),
                                displayString: formatShortDuration(clamped))
    }

    static func fallbackGIFPlaybackDurationSeconds(loopCount: Int) -> Double {
        fallbackGIFLoopDurationSeconds * Double(max(1, loopCount))
    }

    static func gifPlaybackMetadata(for url: URL, loopCount: Int) -> GIFPlaybackMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return gifPlaybackMetadata(from: source, loopCount: loopCount)
    }

    static func loadGIFAnimation(for url: URL) -> GIFAnimation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { return nil }

        var frames: [CGImage] = []
        var frameDurations: [TimeInterval] = []
        frames.reserveCapacity(frameCount)
        frameDurations.reserveCapacity(frameCount)

        var loopDuration: TimeInterval = 0
        for frameIndex in 0..<frameCount {
            guard let frame = CGImageSourceCreateImageAtIndex(source, frameIndex, nil) else { return nil }
            let delay = gifFrameDelay(source: source, frameIndex: frameIndex)
            frames.append(frame)
            frameDurations.append(delay)
            loopDuration += delay
        }

        guard !frames.isEmpty, loopDuration > 0 else { return nil }
        return GIFAnimation(frames: frames,
                            frameDurations: frameDurations,
                            loopDurationSeconds: loopDuration)
    }

    private static func gifPlaybackMetadata(from source: CGImageSource,
                                            loopCount: Int) -> GIFPlaybackMetadata? {
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { return nil }

        var loopDuration = 0.0
        for frameIndex in 0..<frameCount {
            loopDuration += gifFrameDelay(source: source, frameIndex: frameIndex)
        }

        guard loopDuration > 0 else { return nil }
        let loops = max(1, loopCount)
        return GIFPlaybackMetadata(frameCount: frameCount,
                                   loopDurationSeconds: loopDuration,
                                   totalPlaybackDurationSeconds: loopDuration * Double(loops))
    }

    private static func gifFrameDelay(source: CGImageSource, frameIndex: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any],
              let gifProps = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return defaultGIFFrameDelaySeconds
        }

        let unclamped = (gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
        let clamped = (gifProps[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        let rawDelay = unclamped ?? clamped

        guard let rawDelay, rawDelay.isFinite, rawDelay > 0 else {
            return defaultGIFFrameDelaySeconds
        }
        return max(rawDelay, minimumGIFFrameDelaySeconds)
    }

    // MARK: - Mixed URL expansion

    /// Expands a mixed array of file and directory URLs into supported media file URLs.
    ///
    /// - Files with supported extensions are passed through directly.
    /// - Unsupported files are silently skipped (same as existing filter behavior).
    /// - Directories are expanded to `sortedSupportedFiles(inFolder:)` in-place,
    ///   preserving top-level selection order with folder contents sorted internally.
    ///
    /// Returns the expanded list and the names of any folders that contained no supported media.
    static func expandToSupportedMedia(_ urls: [URL]) -> (media: [URL], emptyFolderNames: [String]) {
        var media: [URL] = []
        var emptyFolderNames: [String] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let files = sortedSupportedFiles(inFolder: url)
                if files.isEmpty {
                    emptyFolderNames.append(url.lastPathComponent)
                } else {
                    media.append(contentsOf: files)
                }
            } else if isSupported(url) {
                media.append(url)
            }
            // Unsupported files are silently skipped.
        }
        return (media, emptyFolderNames)
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
