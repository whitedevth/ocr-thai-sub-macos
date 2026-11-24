import CoreGraphics
import CoreVideo

public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    public func distance(_ o: RGB) -> Double {
        ((r - o.r) * (r - o.r) + (g - o.g) * (g - o.g) + (b - o.b) * (b - o.b)).squareRoot()
    }
    static func mean(_ xs: [RGB]) -> RGB {
        let n = Double(max(xs.count, 1))
        return RGB(r: xs.reduce(0) { $0 + $1.r } / n, g: xs.reduce(0) { $0 + $1.g } / n, b: xs.reduce(0) { $0 + $1.b } / n)
    }
    static func median(_ xs: [RGB]) -> RGB {
        func med(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        return RGB(r: med(xs.map(\.r)), g: med(xs.map(\.g)), b: med(xs.map(\.b)))
    }
}

public struct TextColors: Equatable, Sendable {
    /// The letters' own colour.
    public var fill: RGB
    /// Outline / shadow colour if the text has one, otherwise a contrasting colour.
    public var outline: RGB
    /// Whether the original text has a visible outline.
    public var hasOutline: Bool
    /// The colour around the text, when it is one flat colour (nil on textured backgrounds).
    public var flatBackground: RGB? = nil
}

/// Reads pixels of one video frame (sRGB, 0...1).
public protocol PixelReader {
    var width: Int { get }
    var height: Int { get }
    func pixel(_ x: Int, _ y: Int) -> RGB  // origin top-left
}

/// A locked 32BGRA CVPixelBuffer (what the capture session delivers). Lock before, unlock after.
public struct BGRAPixelReader: PixelReader {
    public let width: Int, height: Int
    private let base: UnsafeRawPointer, rowBytes: Int

    /// Returns nil unless the buffer is 32BGRA and its base address is locked.
    public init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        self.base = UnsafeRawPointer(base)
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    }

    public func pixel(_ x: Int, _ y: Int) -> RGB {
        let p = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
        return RGB(r: Double(p[2]) / 255, g: Double(p[1]) / 255, b: Double(p[0]) / 255)
    }
}

/// Finds the colours of text inside a box, straight from the frame's pixels (no GPU round trip).
///
/// Background = median of the border of a slightly larger area. Pixels clearly different from it split
/// into lighter and darker groups. With two groups (e.g. white letters, black outline), the outline is
/// the one touching the background and the letters are the one inside it.
public enum TextColorSampler {
    public static func colors(in frame: PixelReader, box: CGRect) -> TextColors? {
        let W = Double(frame.width), H = Double(frame.height)
        let line = box.height * H
        guard line >= 5 else { return nil }
        let pad = line * 0.35
        let x0 = max(0, Int(box.minX * W - pad)), x1 = min(frame.width - 1, Int(box.maxX * W + pad))
        let y0 = max(0, Int(box.minY * H - pad)), y1 = min(frame.height - 1, Int(box.maxY * H + pad))
        // ~24 samples per text line keeps this to a few thousand reads however big the text is.
        let step = max(1, Int(line / 24))
        let cols = (x1 - x0) / step + 1, rows = (y1 - y0) / step + 1
        guard cols > 4, rows > 4 else { return nil }

        var grid = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: cols * rows)
        for j in 0..<rows { for i in 0..<cols { grid[j * cols + i] = frame.pixel(x0 + i * step, y0 + j * step) } }

        var border: [RGB] = []
        for i in 0..<cols { border.append(grid[i]); border.append(grid[(rows - 1) * cols + i]) }
        for j in 0..<rows { border.append(grid[j * cols]); border.append(grid[j * cols + cols - 1]) }
        let background = RGB.median(border)
        // Flat when nearly all border pixels are close to the median colour.
        let deviations = border.map { $0.distance(background) }.sorted()
        let flat: RGB? = deviations[Int(Double(deviations.count) * 0.85)] < 0.05 ? background : nil

        // 0 = background, 1 = lighter than it, 2 = darker.
        var kind = [UInt8](repeating: 0, count: grid.count)
        for k in grid.indices where grid[k].distance(background) > 0.22 {
            kind[k] = grid[k].luminance >= background.luminance ? 1 : 2
        }
        let m = Int(pad) / step  // only the original box counts, not the padding
        var light: [(RGB, Double)] = [], dark: [(RGB, Double)] = []
        var lightTouching = 0, darkTouching = 0
        for j in m..<max(m + 1, rows - m) {
            for i in m..<max(m + 1, cols - m) {
                let k = j * cols + i
                guard kind[k] != 0 else { continue }
                let touches = [k - 1, k + 1, k - cols, k + cols].contains { $0 >= 0 && $0 < kind.count && kind[$0] == 0 }
                if kind[k] == 1 {
                    light.append((grid[k], grid[k].distance(background)))
                    if touches { lightTouching += 1 }
                } else {
                    dark.append((grid[k], grid[k].distance(background)))
                    if touches { darkTouching += 1 }
                }
            }
        }
        guard light.count + dark.count >= 6 else { return nil }

        func core(_ g: [(RGB, Double)]) -> RGB {
            let sorted = g.sorted { $0.1 > $1.1 }
            return RGB.mean(sorted.prefix(max(1, sorted.count / 2)).map(\.0))
        }
        let minor = min(light.count, dark.count), major = max(light.count, dark.count)
        if minor >= max(6, major / 8) {
            // Two layers: the letters are the group that touches the background less.
            let lightRatio = Double(lightTouching) / Double(light.count)
            let darkRatio = Double(darkTouching) / Double(dark.count)
            let (fill, outline) = lightRatio <= darkRatio ? (light, dark) : (dark, light)
            return TextColors(fill: core(fill), outline: core(outline), hasOutline: true, flatBackground: flat)
        }
        let fill = core(light.count >= dark.count ? light : dark)
        let contrast = fill.luminance > 0.5 ? RGB(r: 0, g: 0, b: 0) : RGB(r: 1, g: 1, b: 1)
        return TextColors(fill: fill, outline: contrast, hasOutline: false, flatBackground: flat)
    }
}
