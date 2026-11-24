import CoreGraphics
import CoreVideo
import Vision

/// Reads subtitle text from a video frame with Apple's on-device Vision OCR.
public struct OCRService: Sendable {
    public var languages: [String]
    /// Lines whose best candidate is below this confidence are dropped (HUD noise, partial glyphs).
    public var minConfidence: Float
    /// Lines shorter than this, relative to the ROI height, are ignored (small HUD text).
    public var minTextHeight: Float

    /// Also return each word's box (needed to read per-word colour).
    public var wantWordBoxes: Bool

    public init(languages: [String] = ["en-US"], minConfidence: Float = 0.4, minTextHeight: Float = 0.08,
                wantWordBoxes: Bool = false) {
        self.languages = languages
        self.minConfidence = minConfidence
        self.minTextHeight = minTextHeight
        self.wantWordBoxes = wantWordBoxes
    }

    /// Subtitle mode: all text in `roi` as one string, top-to-bottom.
    /// - Parameter roi: region to read, normalised 0...1 with the origin at the **top-left** of the frame.
    public func recognize(pixelBuffer: CVPixelBuffer, roi: CGRect) -> String {
        Self.join(recognizeLines(pixelBuffer: pixelBuffer, roi: roi))
    }

    public func recognize(cgImage: CGImage, roi: CGRect) -> String {
        Self.join(recognizeLines(cgImage: cgImage, roi: roi))
    }

    /// Full-screen mode: each recognised line with its box (top-left origin, normalised to the frame).
    public func recognizeLines(pixelBuffer: CVPixelBuffer, roi: CGRect) -> [OCRLine] {
        perform(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up), roi: roi)
    }

    public func recognizeLines(cgImage: CGImage, roi: CGRect) -> [OCRLine] {
        perform(VNImageRequestHandler(cgImage: cgImage, orientation: .up), roi: roi)
    }

    public static func join(_ lines: [OCRLine]) -> String {
        // A two-line subtitle is usually one sentence, so join with a space.
        lines.map(\.text).joined(separator: " ")
    }

    private func perform(_ handler: VNImageRequestHandler, roi: CGRect) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        request.minimumTextHeight = minTextHeight
        // Vision's normalised space has its origin at the bottom-left.
        let clamped = roi.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0.01, clamped.height > 0.01 else { return [] }
        request.regionOfInterest = CGRect(x: clamped.minX, y: 1 - clamped.maxY,
                                          width: clamped.width, height: clamped.height)
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let lines: [OCRLine] = (request.results ?? []).compactMap { obs in
            guard let best = obs.topCandidates(1).first, best.confidence >= minConfidence else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.filter(\.isLetter).count >= 2 else { return nil }
            // boundingBox is relative to the ROI, bottom-left origin -> frame-relative, top-left origin.
            func toFrame(_ b: CGRect) -> CGRect {
                CGRect(x: clamped.minX + b.minX * clamped.width,
                       y: clamped.minY + (1 - b.maxY) * clamped.height,
                       width: b.width * clamped.width,
                       height: b.height * clamped.height)
            }
            var line = OCRLine(box: toFrame(obs.boundingBox), text: text)
            if wantWordBoxes {
                // Per-word boxes, so colour can be read word by word (highlighted keywords).
                let full = best.string
                var start: String.Index?
                var i = full.startIndex
                while i <= full.endIndex {
                    let atSpace = i == full.endIndex || full[i].isWhitespace
                    if atSpace, let s0 = start {
                        let range = s0..<i
                        if let wb = try? best.boundingBox(for: range)?.boundingBox {
                            line.words.append(OCRWord(text: String(full[range]), box: toFrame(wb)))
                        }
                        start = nil
                    } else if !atSpace, start == nil {
                        start = i
                    }
                    if i == full.endIndex { break }
                    i = full.index(after: i)
                }
            }
            return line
        }

        // Top-to-bottom, then left-to-right on the same row.
        return lines.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > min(a.box.height, b.box.height) * 0.5 {
                return a.box.midY < b.box.midY
            }
            return a.box.minX < b.box.minX
        }
    }
}

public struct OCRLine: Equatable, Sendable {
    /// Normalised 0...1, origin top-left of the frame.
    public var box: CGRect
    /// Words whose colour differs from the rest are wrapped in « » after `ColorAnnotator` runs.
    public var text: String
    /// How many OCR lines were merged into this one (1 for a raw line).
    public var lineCount: Int
    public var words: [OCRWord] = []
    /// Main text colours, and the colours of each « » highlight in order.
    public var colors: TextColors?
    public var highlightColors: [TextColors] = []
    /// Background colour around the line when it is flat (exact erase fill).
    public var flatBackground: RGB?

    public init(box: CGRect, text: String, lineCount: Int = 1) {
        self.box = box
        self.text = text
        self.lineCount = lineCount
    }
}

public struct OCRWord: Equatable, Sendable {
    public var text: String
    public var box: CGRect
}
