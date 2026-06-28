import Foundation
import AVFoundation
import ImageIO
import VLCKitSPM

extension MediaFileSupport {
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

    // MARK: - Metadata helpers

    /// Returns a human-readable file size string for `url` (e.g. "12.3 MB").

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




}
