import Foundation

/// Turns a noisy stream of per-frame OCR results into discrete "new subtitle" / "subtitle gone" events.
///
/// - A line must read the same on `requiredStableReads` consecutive frames before it is emitted,
///   which skips typewriter animations and fade-ins and avoids translating half-drawn text.
/// - A line that is nearly identical to the one last emitted (OCR jitter) is not emitted again.
/// - After `clearAfterEmptyReads` empty frames the subtitle is considered gone.
public struct SubtitleTracker: Sendable {
    public enum Event: Equatable, Sendable {
        case show(String)
        case clear
    }

    public var requiredStableReads: Int
    public var clearAfterEmptyReads: Int
    public var sameLineSimilarity: Double

    private var candidateKey = ""
    private var candidateText = ""
    private var stableCount = 0
    private var emptyCount = 0
    private var lastEmittedKey = ""
    private var isShowing = false

    public init(requiredStableReads: Int = 2, clearAfterEmptyReads: Int = 3, sameLineSimilarity: Double = 0.88) {
        self.requiredStableReads = requiredStableReads
        self.clearAfterEmptyReads = clearAfterEmptyReads
        self.sameLineSimilarity = sameLineSimilarity
    }

    public mutating func ingest(_ raw: String) -> Event? {
        let key = Self.normalize(raw)

        if key.count < 2 {
            candidateKey = ""
            stableCount = 0
            emptyCount += 1
            if isShowing, emptyCount >= clearAfterEmptyReads {
                isShowing = false
                lastEmittedKey = ""
                return .clear
            }
            return nil
        }
        emptyCount = 0

        if Self.similarity(key, candidateKey) >= sameLineSimilarity {
            stableCount += 1
            // Keep the longest reading of the same line; OCR sometimes drops a trailing word.
            if raw.count > candidateText.count { candidateText = raw }
        } else {
            candidateKey = key
            candidateText = raw
            stableCount = 1
        }

        guard stableCount == requiredStableReads else { return nil }
        if isShowing, Self.similarity(key, lastEmittedKey) >= sameLineSimilarity { return nil }

        lastEmittedKey = key
        isShowing = true
        return .show(candidateText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Lowercased letters and digits only, so punctuation and spacing jitter doesn't count as a change.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// 1 - normalised Levenshtein distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[b.count]) / Double(max(a.count, b.count))
    }
}
