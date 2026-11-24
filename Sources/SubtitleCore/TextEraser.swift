import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Removes text from a video frame so a translation can be drawn in its place.
///
/// For each text box it rebuilds the background without the text (morphological opening and closing
/// wipe out strokes thinner than the text height, for light and dark text alike), finds the pixels that
/// differ from that background (the glyphs, their outline and shadow), and replaces only those pixels.
/// Everything else in the box keeps its original texture. Runs on the GPU through Core Image.
/// One text area to erase.
public struct EraseRegion: Equatable, Sendable {
    /// Normalised 0...1, origin top-left.
    public var box: CGRect
    /// The background colour when the area around the text is one flat colour (fills exactly).
    public var flatBackground: RGB?

    public init(box: CGRect, flatBackground: RGB? = nil) {
        self.box = box
        self.flatBackground = flatBackground
    }
}

public struct TextEraser: Sendable {
    /// Extra margin around each box, in text-line heights, to catch outlines and drop shadows.
    public var padding: CGFloat = 0.35
    /// How far a pixel must differ from the rebuilt background to count as text (0...1).
    public var threshold: CGFloat = 0.18

    public init() {}

    /// - Parameter boxes: normalised 0...1, origin top-left (as from `OCRService`).
    public func erase(_ image: CIImage, boxes: [CGRect]) -> CIImage {
        erase(image, regions: boxes.map { EraseRegion(box: $0) })
    }

    public func erase(_ image: CIImage, regions: [EraseRegion]) -> CIImage {
        let extent = image.extent
        var output = image
        for region in regions {
            let box = region.box
            // Top-left normalised -> Core Image pixels (origin bottom-left).
            let line = max(box.height * extent.height, 6)
            let rect = CGRect(x: extent.minX + box.minX * extent.width,
                              y: extent.minY + (1 - box.maxY) * extent.height,
                              width: box.width * extent.width,
                              height: box.height * extent.height)
                .insetBy(dx: -line * padding * 1.2, dy: -line * padding)
                .integral
                .intersection(extent)
            guard rect.width > 4, rect.height > 4 else { continue }
            output = eraseRegion(output, rect: rect, lineHeight: line, flat: region.flatBackground)
        }
        return output
    }

    private func eraseRegion(_ image: CIImage, rect: CGRect, lineHeight: CGFloat, flat: RGB?) -> CIImage {
        // Text strokes are thin; anything up to ~2x this radius wide counts as a stroke.
        let strokeRadius = max(2, lineHeight * 0.2)
        let fillRadius = max(4, lineHeight * 0.45)
        let work = rect.insetBy(dx: -fillRadius * 2, dy: -fillRadius * 2).intersection(image.extent)
        let source = image.cropped(to: work).clampedToExtent()

        // 1. Text mask from top-hats: bright thin strokes (white text) and dark thin strokes (dark text),
        //    kept only where the contrast is strong, then grown to cover the outline and shadow.
        let opened = source.applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": strokeRadius])
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": strokeRadius])
        let closed = source.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": strokeRadius])
            .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": strokeRadius])
        let bright = source.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: source, kCIInputImageKey: opened])
        let dark = closed.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: closed, kCIInputImageKey: source])
        let mask = threshold(bright).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: threshold(dark)])
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": max(1.5, lineHeight * 0.1)])
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 1.0])
            .cropped(to: rect)
            .composited(over: CIImage(color: .black).cropped(to: work))
            .clampedToExtent()

        // 2. Fill. On a flat background (subtitle bar, menu panel, sky) use its exact colour, read
        //    from the pixels around the text. Otherwise average the surrounding non-text pixels
        //    (normalised convolution: blur(image * keep) / blur(keep)), a soft local smudge.
        let filled: CIImage
        if let flat {
            filled = CIImage(color: CIColor(red: flat.r, green: flat.g, blue: flat.b,
                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: work)
        } else {
            let keep = mask.applyingFilter("CIColorInvert")
            let known = source.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .black), kCIInputMaskImageKey: keep,
            ])
            let blurredKnown = known.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": fillRadius])
            filled = blurredKnown.applyingFilter("CIDivideBlendMode", parameters: [
                kCIInputBackgroundImageKey: blurredKnown,
                kCIInputImageKey: keep.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": fillRadius])
                    .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0.02, y: 0.02, z: 0.02, w: 1)]),
            ]).applyingFilter("CIColorClamp")
        }

        // 3. Replace only the text pixels.
        return filled.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: source, kCIInputMaskImageKey: mask,
        ])
        .cropped(to: rect)
        .composited(over: image)
    }

    /// Grey image: 1 where any channel exceeds `threshold`, ramping over a short range.
    private func threshold(_ image: CIImage) -> CIImage {
        let gain: CGFloat = 8
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: gain, z: gain, w: 0),
            "inputGVector": CIVector(x: gain, y: gain, z: gain, w: 0),
            "inputBVector": CIVector(x: gain, y: gain, z: gain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -threshold * 3 * gain, y: -threshold * 3 * gain, z: -threshold * 3 * gain, w: 0),
        ]).applyingFilter("CIColorClamp")
    }
}
