import Foundation

/// Reads the colour of every word and marks words that stand out (keyword highlights such as
/// "Pick up the «glass top»") so the translation can colour the matching Thai words the same way.
public enum ColorAnnotator {
    /// Fill colours closer than this count as the same colour.
    static let sameColor = 0.2

    public static func annotate(_ lines: [OCRLine], frame: PixelReader) -> [OCRLine] {
        lines.map { annotate($0, frame: frame) }
    }

    static func annotate(_ line: OCRLine, frame: PixelReader) -> OCRLine {
        var out = line
        guard !line.words.isEmpty else {
            out.colors = TextColorSampler.colors(in: frame, box: line.box)
            out.flatBackground = out.colors?.flatBackground
            return out
        }
        let wordColors = line.words.map { TextColorSampler.colors(in: frame, box: $0.box) }
        // Background flatness is judged around the whole line (what gets erased).
        out.flatBackground = TextColorSampler.colors(in: frame, box: line.box)?.flatBackground

        // Main colour: the fill shared by the most characters.
        var best: (TextColors, Int)?
        for (i, c) in wordColors.enumerated() {
            guard let c else { continue }
            let weight = line.words.indices.reduce(0) { sum, j in
                guard let o = wordColors[j], o.fill.distance(c.fill) < sameColor else { return sum }
                return sum + line.words[j].text.count
            }
            if weight > (best?.1 ?? -1) { best = (c, weight) }
            _ = i
        }
        guard let main = best?.0 else { return out }
        out.colors = main

        // Runs of consecutive words in another colour become « » highlights.
        var text = ""
        var highlights: [TextColors] = []
        var open: TextColors?
        for (i, word) in line.words.enumerated() {
            let c = wordColors[i]
            let different = c.map { $0.fill.distance(main.fill) >= sameColor } ?? false
            if different, let c {
                if let o = open, o.fill.distance(c.fill) < sameColor {
                    text += " "
                } else {
                    if open != nil { text += "»" }
                    text += text.isEmpty ? "«" : " «"
                    open = c
                    highlights.append(c)
                }
            } else {
                if open != nil { text += "»"; open = nil }
                if !text.isEmpty { text += " " }
            }
            text += word.text
        }
        if open != nil { text += "»" }
        // Only keep the marking if something actually stands out.
        if !highlights.isEmpty {
            out.text = text
            out.highlightColors = highlights
        }
        return out
    }

    /// Text without « » markers.
    public static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
    }

    /// Splits marked text into (segment, highlight index or nil).
    public static func segments(_ text: String) -> [(String, Int?)] {
        var result: [(String, Int?)] = []
        var current = "", index = -1, inside = false
        for ch in text {
            if ch == "«" {
                if !current.isEmpty { result.append((current, nil)) }
                current = ""; inside = true; index += 1
            } else if ch == "»" {
                if !current.isEmpty { result.append((current, inside ? index : nil)) }
                current = ""; inside = false
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append((current, inside ? index : nil)) }
        return result
    }
}
