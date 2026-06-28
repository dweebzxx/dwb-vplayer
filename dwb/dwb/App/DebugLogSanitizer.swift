import Foundation

/// Sanitizes formatted debug log text before it leaves the app via copy or export.
///
/// Applied at copy/export time only; the in-app ring buffer is never modified.
/// Redacts two categories of sensitive local identifiers:
/// - Absolute filesystem paths (replaced with [PATH]/<last component>)
/// - User-configured custom prefix values (replaced with [PREFIX])
///
/// Timestamps, log levels, categories, and event ordering are fully preserved.
struct DebugLogSanitizer {

    let prefixesToRedact: [String]

    init(prefixesToRedact: [String] = []) {
        self.prefixesToRedact = prefixesToRedact.filter { !$0.isEmpty }
    }

    func sanitize(_ text: String) -> String {
        var result = text
        result = redactPaths(in: result)
        result = redactPrefixes(in: result)
        return result
    }

    // Matches absolute paths rooted at common macOS filesystem locations.
    // Stops before whitespace and log-format delimiters so safe log tokens are preserved.
    private static let pathPattern: NSRegularExpression = {
        let pattern = #"/(Users|Volumes|private|tmp|var|Library|Applications)/[^\s\n'"<>\\,;:)]+"#
        return try! NSRegularExpression(pattern: pattern) // swiftlint:disable:this force_try
    }()

    private func redactPaths(in text: String) -> String {
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = Self.pathPattern.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }
        var result = text
        // Process in reverse order so earlier ranges stay valid after substitution.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let matched = String(result[range])
            let lastComponent = matched.components(separatedBy: "/").last ?? matched
            result.replaceSubrange(range, with: "[PATH]/\(lastComponent)")
        }
        return result
    }

    private func redactPrefixes(in text: String) -> String {
        // Sort longest-first so a longer prefix is matched before any shorter one it starts with,
        // preventing partial substitution (e.g. "tag_long_" before "tag_").
        let sorted = prefixesToRedact.sorted { $0.count > $1.count }
        var result = text
        for prefix in sorted {
            result = result.replacingOccurrences(of: prefix, with: "[PREFIX]")
        }
        return result
    }
}
