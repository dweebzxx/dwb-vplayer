import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import ImageIO

enum MediaFileSupport {
    private static let defaultGIFFrameDelaySeconds = 0.1
    private static let minimumGIFFrameDelaySeconds = 0.02
    private static let fallbackGIFLoopDurationSeconds = 1.0
    private static let maxGIFOverlayDecodedBytes: UInt64 = 180 * 1024 * 1024

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

    static func isLargeGIF(url: URL, source: CGImageSource) -> Bool {
        // Size threshold: 12 MB
        if let size = fileSizeBytes(for: url), size > 12 * 1024 * 1024 {
            return true
        }

        // Frame count threshold: 80 frames
        let count = CGImageSourceGetCount(source)
        if count > 80 {
            return true
        }

        // Dimension threshold: pixel area > 1,000,000 pixels (approx 1000x1000)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Double ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Double ?? 0
            if width * height > 1_000_000 {
                return true
            }
        }

        return false
    }

    static func loadGIFAnimation(for url: URL) -> GIFAnimation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        // Eagerly decode first frame as fallback and cache primer
        guard let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        // Determine if it is a large/high-frame-count GIF
        let isLarge = isLargeGIF(url: url, source: source)

        guard let plan = gifSamplePlan(source: source) else { return nil }

        // Max cache size
        // If large/high-frame-count, bound memory with a small cache (e.g., 5 frames).
        // Otherwise, cache all frames for smooth looping.
        let maxCacheSize = isLarge ? 5 : plan.sampledIndices.count

        return GIFAnimation(source: source,
                            sampledIndices: plan.sampledIndices,
                            frameDurations: plan.frameDurations,
                            loopDurationSeconds: plan.loopDurationSeconds,
                            fallbackFrame: firstFrame,
                            maxCacheSize: maxCacheSize)
    }

    static func loadGIFOverlayAnimation(for url: URL) -> Result<GIFOverlayAnimation, GIFOverlayAnimationLoadFailure> {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let plan = gifSamplePlan(source: source) else {
            return .failure(.invalid)
        }

        let estimatedBytes = estimatedDecodedBytes(source: source, sampledIndices: plan.sampledIndices)
        if estimatedBytes > maxGIFOverlayDecodedBytes {
            return .failure(.decodedFramesTooLarge(estimatedBytes: estimatedBytes,
                                                   limitBytes: maxGIFOverlayDecodedBytes))
        }

        let decodeOptions = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        var frames: [CGImage] = []
        frames.reserveCapacity(plan.sampledIndices.count)
        var decodedBytes: UInt64 = 0

        for originalFrameIndex in plan.sampledIndices {
            guard let frame = CGImageSourceCreateImageAtIndex(source, originalFrameIndex, decodeOptions) else {
                return .failure(.invalid)
            }

            decodedBytes += decodedByteCount(for: frame)
            guard decodedBytes <= maxGIFOverlayDecodedBytes else {
                return .failure(.decodedFramesTooLarge(estimatedBytes: decodedBytes,
                                                       limitBytes: maxGIFOverlayDecodedBytes))
            }
            frames.append(frame)
        }

        guard !frames.isEmpty else { return .failure(.invalid) }

        return .success(GIFOverlayAnimation(frames: frames,
                                            frameDurations: plan.frameDurations,
                                            loopDurationSeconds: plan.loopDurationSeconds,
                                            decodedByteCount: decodedBytes))
    }

    static func firstGIFFrame(for url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
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

    private static func gifSamplePlan(source: CGImageSource) -> GIFSamplePlan? {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var step = 1
        if count > 100 {
            // Keep high-frame-count GIFs bounded while preserving total timing.
            step = Int(ceil(Double(count) / 60.0))
        }

        var sampledIndices: [Int] = []
        var frameDurations: [TimeInterval] = []
        var loopDuration: TimeInterval = 0

        var i = 0
        while i < count {
            sampledIndices.append(i)

            var delay = 0.0
            for j in 0..<step where i + j < count {
                delay += gifFrameDelay(source: source, frameIndex: i + j)
            }
            frameDurations.append(delay)
            loopDuration += delay

            i += step
        }

        guard !sampledIndices.isEmpty, loopDuration > 0 else { return nil }
        return GIFSamplePlan(sampledIndices: sampledIndices,
                             frameDurations: frameDurations,
                             loopDurationSeconds: loopDuration)
    }

    private static func estimatedDecodedBytes(source: CGImageSource, sampledIndices: [Int]) -> UInt64 {
        var total: UInt64 = 0
        for index in sampledIndices {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
                continue
            }
            let width = positiveInteger(from: properties[kCGImagePropertyPixelWidth])
            let height = positiveInteger(from: properties[kCGImagePropertyPixelHeight])
            guard width > 0, height > 0 else { continue }
            total += UInt64(width) * UInt64(height) * 4
        }
        return total
    }

    private static func positiveInteger(from value: Any?) -> Int {
        if let number = value as? NSNumber {
            return max(0, number.intValue)
        }
        if let intValue = value as? Int {
            return max(0, intValue)
        }
        if let doubleValue = value as? Double, doubleValue.isFinite {
            return max(0, Int(doubleValue.rounded()))
        }
        return 0
    }

    private static func decodedByteCount(for image: CGImage) -> UInt64 {
        UInt64(max(0, image.bytesPerRow)) * UInt64(max(0, image.height))
    }

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

    /// Formats a duration in seconds to "H:MM:SS" or "M:SS".
    static func formatDuration(_ seconds: Double) -> String {
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

    private struct FolderScanResult {
        let accepted: [URL]
        let supportedCount: Int
        let excludedCount: Int
    }

    enum MediaKind: Hashable, Sendable {
        case video
        case image
        case gif
    }

    struct DurationMetadata {
        let seconds: Double?
        let displayString: String
    }

    struct ExpansionResult: Sendable {
        let media: [URL]
        let emptyFolderNames: [String]
        let supportedMediaCount: Int
        let excludedMediaCount: Int
    }

    struct GIFPlaybackMetadata {
        let frameCount: Int
        let loopDurationSeconds: Double
        let totalPlaybackDurationSeconds: Double
    }

    struct GIFOverlayAnimation {
        let frames: [CGImage]
        let frameDurations: [TimeInterval]
        let loopDurationSeconds: TimeInterval
        let decodedByteCount: UInt64

        var keyTimes: [NSNumber] {
            guard loopDurationSeconds > 0, !frameDurations.isEmpty else { return [] }
            var keyTimes: [NSNumber] = []
            keyTimes.reserveCapacity(frameDurations.count + 1)
            var elapsed: TimeInterval = 0
            for duration in frameDurations {
                keyTimes.append(NSNumber(value: min(1.0, max(0.0, elapsed / loopDurationSeconds))))
                elapsed += duration
            }
            keyTimes.append(NSNumber(value: 1.0))
            return keyTimes
        }
    }

    enum GIFOverlayAnimationLoadFailure: Error {
        case invalid
        case decodedFramesTooLarge(estimatedBytes: UInt64, limitBytes: UInt64)

        var debugDescription: String {
            switch self {
            case .invalid:
                return "invalid GIF"
            case let .decodedFramesTooLarge(estimatedBytes, limitBytes):
                let estimated = ByteCountFormatter.string(fromByteCount: Int64(estimatedBytes), countStyle: .memory)
                let limit = ByteCountFormatter.string(fromByteCount: Int64(limitBytes), countStyle: .memory)
                return "decoded frames too large: \(estimated) over \(limit) limit"
            }
        }
    }

    private struct GIFSamplePlan {
        let sampledIndices: [Int]
        let frameDurations: [TimeInterval]
        let loopDurationSeconds: TimeInterval
    }

    struct LazyFrameCollection: RandomAccessCollection {
        typealias Element = CGImage
        typealias Index = Int

        private weak var animation: GIFAnimation?
        let count: Int

        init(animation: GIFAnimation?, count: Int) {
            self.animation = animation
            self.count = count
        }

        var startIndex: Int { 0 }
        var endIndex: Int { count }

        subscript(position: Int) -> CGImage {
            guard let animation = animation else {
                return CGImage.makeEmptyFallback()
            }
            return animation.frame(at: position)
        }

        func index(after i: Int) -> Int { i + 1 }
        func index(before i: Int) -> Int { i - 1 }
    }

    class GIFAnimation {
        var frames: LazyFrameCollection {
            LazyFrameCollection(animation: self, count: sampledIndices.count)
        }
        let frameDurations: [TimeInterval]
        let loopDurationSeconds: TimeInterval

        private let source: CGImageSource
        private let sampledIndices: [Int]
        private let fallbackFrame: CGImage
        private let maxCacheSize: Int
        private var cache: [Int: CGImage] = [:]
        private var cacheOrder: [Int] = []
        private let lock = NSRecursiveLock()

        init?(source: CGImageSource,
              sampledIndices: [Int],
              frameDurations: [TimeInterval],
              loopDurationSeconds: Double,
              fallbackFrame: CGImage,
              maxCacheSize: Int) {
            self.source = source
            self.sampledIndices = sampledIndices
            self.frameDurations = frameDurations
            self.loopDurationSeconds = loopDurationSeconds
            self.fallbackFrame = fallbackFrame
            self.maxCacheSize = maxCacheSize

            // Prime the cache with the first frame
            self.cache[0] = fallbackFrame
            self.cacheOrder.append(0)
        }

        func frame(at index: Int) -> CGImage {
            lock.lock()
            defer { lock.unlock() }

            if let cached = cache[index] {
                if let idx = cacheOrder.firstIndex(of: index) {
                    cacheOrder.remove(at: idx)
                }
                cacheOrder.append(index)
                return cached
            }

            guard index >= 0 && index < sampledIndices.count else {
                return fallbackFrame
            }

            let origIndex = sampledIndices[index]
            if let image = CGImageSourceCreateImageAtIndex(source, origIndex, nil) {
                cache[index] = image
                cacheOrder.append(index)

                if cacheOrder.count > maxCacheSize {
                    let oldest = cacheOrder.removeFirst()
                    cache.removeValue(forKey: oldest)
                }
                return image
            }

            return fallbackFrame
        }
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

    static func supportedContentTypes(acceptedKinds: Set<MediaKind>) -> [UTType] {
        supportedExtensions.sorted().compactMap { ext in
            guard let kind = mediaKind(forExtension: ext), acceptedKinds.contains(kind) else { return nil }
            let conformance: UTType = kind == .video ? .movie : .image
            return UTType(filenameExtension: ext, conformingTo: conformance)
                ?? UTType(filenameExtension: ext)
        }
    }

    static func mediaKind(for url: URL) -> MediaKind? {
        mediaKind(forExtension: url.pathExtension)
    }

    static func mediaKind(forExtension pathExtension: String) -> MediaKind? {
        let ext = pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if ext == "gif" { return .gif }
        if imageExtensions.contains(ext) { return .image }
        return nil
    }

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isGIF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gif"
    }

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isAccepted(_ url: URL, acceptedKinds: Set<MediaKind>) -> Bool {
        guard let kind = mediaKind(for: url) else { return false }
        return acceptedKinds.contains(kind)
    }

    static func compareFinderNaturalFilenames(_ lhs: URL, _ rhs: URL) -> ComparisonResult {
        let nameResult = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
        if nameResult != .orderedSame { return nameResult }

        let lhsPath = lhs.standardizedFileURL.path
        let rhsPath = rhs.standardizedFileURL.path
        let pathResult = lhsPath.localizedStandardCompare(rhsPath)
        if pathResult != .orderedSame { return pathResult }
        if lhsPath < rhsPath { return .orderedAscending }
        if lhsPath > rhsPath { return .orderedDescending }
        return .orderedSame
    }

    static func finderNaturalFilenameAscending(_ lhs: URL, _ rhs: URL) -> Bool {
        compareFinderNaturalFilenames(lhs, rhs) == .orderedAscending
    }

    /// Recursively enumerate `folder`, collect regular files with supported extensions,
    /// sort by Finder-style natural display filename order, and return the first one.
    ///
    /// Ordering rule: localized natural compare of `lastPathComponent`, with absolute
    /// path tie-breaks for deterministic ordering of duplicate display names.
    /// Returns nil when the folder is empty or contains no supported media files.
    static func firstSupportedFile(inFolder folder: URL) -> URL? {
        sortedSupportedFiles(inFolder: folder).first
    }

    /// Returns all supported media files in `folder` (recursive), sorted by Finder-style
    /// natural display filename order. Same ordering rule as `firstSupportedFile`.
    static func sortedSupportedFiles(inFolder folder: URL) -> [URL] {
        scanSupportedFiles(inFolder: folder, acceptedKinds: nil).accepted
    }

    static func sortedSupportedFiles(inFolder folder: URL,
                                     acceptedKinds: Set<MediaKind>) -> [URL] {
        scanSupportedFiles(inFolder: folder, acceptedKinds: acceptedKinds).accepted
    }

    static func sortedSupportedFiles(inFolder folder: URL,
                                     acceptedKinds: Set<MediaKind>,
                                     shouldCancel: () -> Bool) throws -> [URL] {
        try scanSupportedFiles(inFolder: folder,
                               acceptedKinds: acceptedKinds,
                               shouldCancel: shouldCancel).accepted
    }

    private static func scanSupportedFiles(inFolder folder: URL,
                                           acceptedKinds: Set<MediaKind>?) -> FolderScanResult {
        (try? scanSupportedFiles(inFolder: folder,
                                 acceptedKinds: acceptedKinds,
                                 shouldCancel: { false }))
            ?? FolderScanResult(accepted: [], supportedCount: 0, excludedCount: 0)
    }

    private static func scanSupportedFiles(inFolder folder: URL,
                                           acceptedKinds: Set<MediaKind>?,
                                           shouldCancel: () -> Bool) throws -> FolderScanResult {
        guard !shouldCancel() else { throw CancellationError() }
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return FolderScanResult(accepted: [], supportedCount: 0, excludedCount: 0) }

        var found: [URL] = []
        var supportedCount = 0
        var excludedCount = 0
        for case let url as URL in enumerator {
            guard !shouldCancel() else { throw CancellationError() }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let kind = mediaKind(for: url) else { continue }
            supportedCount += 1
            if let acceptedKinds, !acceptedKinds.contains(kind) {
                excludedCount += 1
            } else {
                found.append(url)
            }
        }
        guard !shouldCancel() else { throw CancellationError() }
        return FolderScanResult(accepted: found.sorted(by: finderNaturalFilenameAscending),
                                supportedCount: supportedCount,
                                excludedCount: excludedCount)
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
        let result = expandToSupportedMedia(urls, acceptedKinds: [.video, .image, .gif])
        return (result.media, result.emptyFolderNames)
    }

    static func expandToSupportedMedia(_ urls: [URL],
                                       acceptedKinds: Set<MediaKind>) -> ExpansionResult {
        (try? expandToSupportedMedia(urls,
                                     acceptedKinds: acceptedKinds,
                                     shouldCancel: { false }))
            ?? ExpansionResult(media: [],
                               emptyFolderNames: [],
                               supportedMediaCount: 0,
                               excludedMediaCount: 0)
    }

    static func expandToSupportedMedia(_ urls: [URL],
                                       acceptedKinds: Set<MediaKind>,
                                       shouldCancel: () -> Bool) throws -> ExpansionResult {
        var media: [URL] = []
        var emptyFolderNames: [String] = []
        var supportedMediaCount = 0
        var excludedMediaCount = 0
        for url in urls {
            guard !shouldCancel() else { throw CancellationError() }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let scan = try scanSupportedFiles(inFolder: url,
                                                  acceptedKinds: acceptedKinds,
                                                  shouldCancel: shouldCancel)
                supportedMediaCount += scan.supportedCount
                excludedMediaCount += scan.excludedCount
                if scan.supportedCount == 0 {
                    emptyFolderNames.append(url.lastPathComponent)
                } else {
                    media.append(contentsOf: scan.accepted)
                }
            } else if let kind = mediaKind(for: url) {
                supportedMediaCount += 1
                if acceptedKinds.contains(kind) {
                    media.append(url)
                } else {
                    excludedMediaCount += 1
                }
            }
            // Unsupported files are silently skipped.
        }
        return ExpansionResult(media: media,
                               emptyFolderNames: emptyFolderNames,
                               supportedMediaCount: supportedMediaCount,
                               excludedMediaCount: excludedMediaCount)
    }

    // MARK: - Neighbor lookup

    /// For a known media file URL, returns the previous and next media files in the same
    /// containing folder using the same Finder-style natural sort as `sortedSupportedFiles`.
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

    // MARK: - Prefix Rename Planning

    /// Reason a prefix rename preflight cannot proceed for a given target.
    enum PrefixRenameFailure: Error, Equatable {
        case missingSource(filename: String)
        case invalidNewName(original: String)
        case destinationCollision(newName: String)
        case duplicateDestination(newName: String)
    }

    /// A single validated rename that is safe to execute.
    struct PlannedPrefixRename: Equatable {
        let sourceURL: URL
        let destinationURL: URL
    }

    /// Plans a prefix rename operation for the given URLs.
    ///
    /// No-ops (stems already starting with `prefix`) are filtered out silently.
    /// Returns `.success([])` when every target is already prefixed.
    /// Returns `.failure` on the first detected preflight error so the caller
    /// can surface it before mutating any file.
    ///
    /// `fileExistsAtPath` is injectable for deterministic unit testing;
    /// defaults to `FileManager.default.fileExists(atPath:)`.
    static func planPrefixRenames(
        urls: [URL],
        prefix: String,
        fileExistsAtPath: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Result<[PlannedPrefixRename], PrefixRenameFailure> {
        var planned: [PlannedPrefixRename] = []
        var seenDestinationPaths = Set<String>()

        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent
            if stem.hasPrefix(prefix) { continue }

            guard fileExistsAtPath(url.path) else {
                return .failure(.missingSource(filename: url.lastPathComponent))
            }

            let ext = url.pathExtension
            let newName = ext.isEmpty ? "\(prefix)\(stem)" : "\(prefix)\(stem).\(ext)"

            guard !newName.isEmpty,
                  newName != ".", newName != "..",
                  newName.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) == nil,
                  newName.utf8.allSatisfy({ $0 != 0 }) else {
                return .failure(.invalidNewName(original: url.lastPathComponent))
            }

            let destinationURL = url.deletingLastPathComponent()
                .appendingPathComponent(newName, isDirectory: false)

            guard !fileExistsAtPath(destinationURL.path) else {
                return .failure(.destinationCollision(newName: newName))
            }

            let destKey = destinationURL.standardizedFileURL.path
            guard seenDestinationPaths.insert(destKey).inserted else {
                return .failure(.duplicateDestination(newName: newName))
            }

            planned.append(PlannedPrefixRename(sourceURL: url, destinationURL: destinationURL))
        }

        return .success(planned)
    }
}

extension CGImage {
    static func makeEmptyFallback() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let context = CGContext(data: nil,
                                   width: 1,
                                   height: 1,
                                   bitsPerComponent: 8,
                                   bytesPerRow: 4,
                                   space: colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let image = context.makeImage() {
            return image
        }
        fatalError("Failed to create empty fallback CGImage")
    }
}
