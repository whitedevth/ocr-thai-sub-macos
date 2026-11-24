import CoreGraphics
import Foundation

/// A piece of on-screen text (one or more lines that belong together) and its translation.
public struct ScreenBlock: Identifiable, Equatable, Sendable {
    public let id: Int
    /// Normalised 0...1, origin top-left of the frame.
    public var box: CGRect
    public var english: String
    public var thai: String?
    public var lineCount: Int = 1
    /// false while showing a quick first translation that a better one will replace.
    public var isFinal = false
    /// Colours of the original text, and of each « » highlight in `english`.
    public var colors: TextColors?
    public var highlightColors: [TextColors] = []
    /// Background colour around the text when flat (exact erase), else nil.
    public var flatBackground: RGB?
}

public struct TranslationJob: Equatable, Sendable {
    public let blockID: Int
    public let english: String
}

/// Full-screen mode: tracks every text block on screen separately so that only blocks whose text
/// actually changed are translated, and each translation can be drawn where its English was.
public struct ScreenTextTracker: Sendable {
    public var requiredStableReads: Int
    public var removeAfterMissedReads: Int
    public var sameTextSimilarity: Double

    private struct Tracked {
        var block: ScreenBlock
        var key: String
        var stableCount: Int
        var missed: Int
        /// Key of the text the current `thai` belongs to (or that is being translated).
        var requestedKey: String?
        /// Key of the text the final translation belongs to.
        var finalKey: String?
    }

    private var tracked: [Tracked] = []
    private var nextID = 1

    public init(requiredStableReads: Int = 2, removeAfterMissedReads: Int = 3, sameTextSimilarity: Double = 0.88) {
        self.requiredStableReads = requiredStableReads
        self.removeAfterMissedReads = removeAfterMissedReads
        self.sameTextSimilarity = sameTextSimilarity
    }

    /// Blocks currently on screen (including ones not translated yet).
    public var blocks: [ScreenBlock] { tracked.map(\.block) }

    /// Feed one frame of OCR lines; returns the blocks that now need translating.
    public mutating func ingest(_ lines: [OCRLine]) -> [TranslationJob] {
        let detected = Self.group(lines).filter { Self.isTranslatable($0.text) }
        var matched = Set<Int>()
        var jobs: [TranslationJob] = []

        for det in detected {
            let key = SubtitleTracker.normalize(det.text)
            // Same place on screen, or the same text that moved a little.
            let index = tracked.indices
                .filter { !matched.contains($0) }
                .max { score(tracked[$0], det.box, key) < score(tracked[$1], det.box, key) }
                .flatMap { score(tracked[$0], det.box, key) > 0 ? $0 : nil }

            if let i = index {
                matched.insert(i)
                tracked[i].missed = 0
                // One line of a multi-line block missed for a frame: keep the whole block as it was
                // instead of shrinking it and re-translating half the text.
                if Self.isPartialRead(det, of: tracked[i].block, key: key, trackedKey: tracked[i].key) { continue }
                let sameText = SubtitleTracker.similarity(key, tracked[i].key) >= sameTextSimilarity
                // OCR boxes wobble a few pixels every frame. Keep the overlay still unless the text
                // changed or really moved/resized, otherwise the Thai text jitters on screen.
                if !sameText || Self.reallyMoved(from: tracked[i].block.box, to: det.box) {
                    tracked[i].block.box = det.box
                    tracked[i].block.lineCount = det.lineCount
                }
                if sameText {
                    tracked[i].stableCount += 1
                    if det.text.count > tracked[i].block.english.count {
                        tracked[i].block.english = det.text
                        tracked[i].block.highlightColors = det.highlightColors
                    }
                    if tracked[i].block.colors == nil { tracked[i].block.colors = det.colors }
                    tracked[i].block.flatBackground = det.flatBackground
                } else {
                    tracked[i].key = key
                    tracked[i].block.english = det.text
                    tracked[i].block.colors = det.colors
                    tracked[i].block.highlightColors = det.highlightColors
                    tracked[i].block.flatBackground = det.flatBackground
                    tracked[i].stableCount = 1
                }
                if tracked[i].stableCount >= requiredStableReads,
                   tracked[i].requestedKey.map({ SubtitleTracker.similarity($0, key) < sameTextSimilarity }) ?? true {
                    // Text changed (or is new and has settled): translate it. Old Thai stays until the new arrives.
                    tracked[i].requestedKey = key
                    jobs.append(TranslationJob(blockID: tracked[i].block.id, english: tracked[i].block.english))
                }
            } else {
                var block = ScreenBlock(id: nextID, box: det.box, english: det.text, thai: nil, lineCount: det.lineCount)
                block.colors = det.colors
                block.highlightColors = det.highlightColors
                block.flatBackground = det.flatBackground
                nextID += 1
                tracked.append(Tracked(block: block, key: key, stableCount: 1, missed: 0, requestedKey: nil, finalKey: nil))
                matched.insert(tracked.count - 1)
                if requiredStableReads <= 1 {
                    tracked[tracked.count - 1].requestedKey = key
                    jobs.append(TranslationJob(blockID: block.id, english: block.english))
                }
            }
        }

        for i in tracked.indices where !matched.contains(i) {
            tracked[i].missed += 1
        }
        tracked.removeAll { $0.missed >= removeAfterMissedReads }
        return jobs
    }

    /// Attach a finished translation. Ignored if the block is gone or its text changed meanwhile.
    /// A quick (`final: false`) translation never overwrites the final one for the same text.
    public mutating func setTranslation(_ thai: String, for job: TranslationJob, final: Bool = true) {
        guard let i = tracked.firstIndex(where: { $0.block.id == job.blockID }) else { return }
        let jobKey = SubtitleTracker.normalize(job.english)
        guard SubtitleTracker.similarity(jobKey, tracked[i].requestedKey ?? "") >= sameTextSimilarity else { return }
        if !final, tracked[i].block.isFinal, tracked[i].finalKey == tracked[i].requestedKey { return }
        tracked[i].block.thai = thai
        tracked[i].block.isFinal = final
        if final { tracked[i].finalKey = tracked[i].requestedKey }
    }

    /// Lets a block be retried on the next frame after a failed translation.
    public mutating func translationFailed(for job: TranslationJob) {
        guard let i = tracked.firstIndex(where: { $0.block.id == job.blockID }) else { return }
        tracked[i].requestedKey = nil
    }

    public mutating func reset() {
        tracked.removeAll()
    }

    private func score(_ t: Tracked, _ box: CGRect, _ key: String) -> Double {
        let iou = Self.iou(t.block.box, box)
        let sim = SubtitleTracker.similarity(t.key, key)
        if iou >= 0.3 { return 1 + iou }
        // Same text moved (e.g. a menu scrolled) as long as it is still nearby.
        if sim >= sameTextSimilarity, hypot(t.block.box.midX - box.midX, t.block.box.midY - box.midY) < 0.15 { return sim }
        return 0
    }

    // MARK: - Grouping and filtering

    /// Merges lines that form one paragraph: stacked closely, similar text height, overlapping horizontally.
    public static func group(_ lines: [OCRLine]) -> [OCRLine] {
        var blocks: [(box: CGRect, lines: [OCRLine])] = []
        for line in lines.sorted(by: { $0.box.minY < $1.box.minY }) {
            if let i = blocks.lastIndex(where: { belongsBelow(line, $0.lines.last!) }) {
                blocks[i].lines.append(line)
                blocks[i].box = blocks[i].box.union(line.box)
            } else {
                blocks.append((line.box, [line]))
            }
        }
        return blocks.map { b in
            var merged = OCRLine(box: b.box, text: b.lines.map(\.text).joined(separator: " "), lineCount: b.lines.count)
            // Main colour of the longest line; highlights in reading order.
            merged.colors = b.lines.filter { $0.colors != nil }.max { $0.text.count < $1.text.count }?.colors
            merged.highlightColors = b.lines.flatMap(\.highlightColors)
            // Flat only if every line sits on (nearly) the same flat colour.
            let flats = b.lines.map(\.flatBackground)
            if let first = flats.first ?? nil, flats.allSatisfy({ $0.map { $0.distance(first) < 0.06 } ?? false }) {
                merged.flatBackground = first
            }
            return merged
        }
    }

    private static func belongsBelow(_ line: OCRLine, _ above: OCRLine) -> Bool {
        let a = above.box, b = line.box
        let h = max(a.height, b.height)
        let gap = b.minY - a.maxY
        let heightRatio = min(a.height, b.height) / max(a.height, b.height)
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        // A wrapped paragraph line is long; short stacked lines are separate menu items.
        let aboveWords = above.text.split(separator: " ").count
        return gap > -h * 0.3 && gap < h * 0.6
            && heightRatio > 0.7
            && overlap > min(a.width, b.width) * 0.3
            && aboveWords >= 4
    }

    /// Skips numbers, timers, button glyph labels and other text that needs no translation.
    public static func isTranslatable(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count
        guard letters >= 3 else { return false }
        let nonSpace = text.filter { !$0.isWhitespace }.count
        return Double(letters) / Double(max(nonSpace, 1)) >= 0.5
    }

    static func isPartialRead(_ det: OCRLine, of block: ScreenBlock, key: String, trackedKey: String) -> Bool {
        guard block.lineCount > det.lineCount, key.count < trackedKey.count, trackedKey.contains(key) else { return false }
        let inter = block.box.intersection(det.box)
        guard !inter.isNull else { return false }
        return inter.width * inter.height >= det.box.width * det.box.height * 0.8
    }

    /// True when the box moved by more than half a text line, or its size changed noticeably.
    /// Smaller differences are OCR wobble.
    public static func reallyMoved(from a: CGRect, to b: CGRect) -> Bool {
        let line = max(a.height, 0.001)
        return abs(a.midY - b.midY) > line * 0.5
            || abs(a.midX - b.midX) > max(line, a.width * 0.08)
            || abs(a.width - b.width) > a.width * 0.2
            || abs(a.height - b.height) > a.height * 0.3
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let i = inter.width * inter.height
        let u = a.width * a.height + b.width * b.height - i
        return u > 0 ? Double(i / u) : 0
    }
}
