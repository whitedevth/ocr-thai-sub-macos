import AppKit
import CoreImage
import Metal
import QuartzCore
import SubtitleCore
import SwiftUI

/// Draws every capture-card frame with Metal through Core Image, erasing the game's own text first
/// (replaces AVCaptureVideoPreviewLayer, which can't modify the picture).
final class VideoRenderer: @unchecked Sendable {
    let layer = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let eraser = TextEraser()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private let lock = NSLock()
    private var _regions: [EraseRegion] = []
    private var _eraseEnabled = true
    private var _drawableSize = CGSize.zero
    private var renderTimes: [Double] = []
    private var lastFrame: CVPixelBuffer?
    private var lastAspect: CGFloat = 0
    /// Called (on the capture queue) when the video's width/height ratio changes, so the overlay can match it.
    var onAspectChange: ((CGFloat) -> Void)?

    init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false  // Core Image writes into the drawable
        layer.isOpaque = true
        layer.colorspace = colorSpace
        layer.backgroundColor = NSColor.black.cgColor
        layer.maximumDrawableCount = 3
    }

    /// Text areas to erase (normalised, top-left origin), updated from OCR.
    func setEraseRegions(_ regions: [EraseRegion]) { lock.withLock { _regions = regions } }
    func setEraseEnabled(_ on: Bool) { lock.withLock { _eraseEnabled = on } }
    func setDrawableSize(_ size: CGSize) {
        lock.withLock { _drawableSize = size }
        layer.drawableSize = size
    }

    /// Average CPU-side time to build and submit a frame, in ms (for the status line).
    var averageRenderMilliseconds: Double {
        lock.withLock { renderTimes.isEmpty ? 0 : renderTimes.reduce(0, +) / Double(renderTimes.count) }
    }

    /// The latest frame as drawn (text erased), full resolution. Development aid.
    func snapshot() -> CGImage? {
        let (frame, regions, erase) = lock.withLock { (lastFrame, _regions, _eraseEnabled) }
        guard let frame else { return nil }
        var image = CIImage(cvPixelBuffer: frame)
        if erase { image = eraser.erase(image, regions: regions) }
        return context.createCGImage(image, from: image.extent)
    }

    /// Called on the capture queue for every frame.
    func render(_ pixelBuffer: CVPixelBuffer) {
        let start = CACurrentMediaTime()
        let frameW = CVPixelBufferGetWidth(pixelBuffer), frameH = CVPixelBufferGetHeight(pixelBuffer)
        let aspect = frameH > 0 ? CGFloat(frameW) / CGFloat(frameH) : 0
        let (regions, erase, size, aspectChanged) = lock.withLock { () -> ([EraseRegion], Bool, CGSize, Bool) in
            lastFrame = pixelBuffer
            let changed = aspect > 0 && abs(aspect - lastAspect) > 0.001
            if changed { lastAspect = aspect }
            return (_regions, _eraseEnabled, _drawableSize, changed)
        }
        if aspectChanged { onAspectChange?(aspect) }
        guard size.width > 0, size.height > 0,
              let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if erase, !regions.isEmpty {
            image = eraser.erase(image, regions: regions)
        }
        // Aspect-fit into the drawable on black.
        let extent = image.extent
        let scale = min(size.width / extent.width, size.height / extent.height)
        let x = (size.width - extent.width * scale) / 2, y = (size.height - extent.height * scale) / 2
        image = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: x, y: y)))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))

        context.render(image, to: drawable.texture, commandBuffer: commandBuffer,
                       bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()

        let ms = (CACurrentMediaTime() - start) * 1000
        lock.withLock {
            renderTimes.append(ms)
            if renderTimes.count > 120 { renderTimes.removeFirst() }
        }
    }
}

/// Hosts the renderer's Metal layer in SwiftUI.
struct VideoView: NSViewRepresentable {
    let renderer: VideoRenderer

    func makeNSView(context: Context) -> HostView {
        HostView(renderer: renderer)
    }

    func updateNSView(_ nsView: HostView, context: Context) {}

    final class HostView: NSView {
        let renderer: VideoRenderer

        init(renderer: VideoRenderer) {
            self.renderer = renderer
            super.init(frame: .zero)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func makeBackingLayer() -> CALayer { renderer.layer }

        override func layout() {
            super.layout()
            updateSize()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateSize()
        }

        private func updateSize() {
            let scale = window?.backingScaleFactor ?? 2
            renderer.layer.contentsScale = scale
            renderer.setDrawableSize(CGSize(width: bounds.width * scale, height: bounds.height * scale))
        }
    }
}
