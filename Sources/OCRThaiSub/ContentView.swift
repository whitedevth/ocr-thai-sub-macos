import SubtitleCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var capture: CaptureService
    @ObservedObject var apple: AppleTranslationBridge
    @State private var showSettings = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Everything inside shares the video's rect (its real aspect ratio), so ROI and overlay line up with the picture.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    VideoView(renderer: model.renderer)
                    Group {
                        switch model.settings.mode {
                        case .subtitle:
                            if model.settings.showROI {
                                roiOutline(in: geo.size)
                            }
                            subtitleOverlay(in: geo.size)
                        case .fullScreen:
                            screenOverlay(in: geo.size)
                        }
                    }
                    // Translations swap instantly: no fades or slides.
                    .transaction { $0.animation = nil }
                }
            }
            .aspectRatio(model.videoAspect, contentMode: .fit)

            if !capture.isRunning {
                idlePlaceholder
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .toolbar { toolbar }
        // Keeps Apple's on-device translation session alive for the whole window.
        .translationTask(apple.configuration) { session in
            await apple.serve(session)
        }
        .onAppear {
            if model.settings.quickApple { apple.activate() }
            model.runSelfTestIfRequested()
            model.runDemoFeedIfRequested()
        }
        .onChange(of: model.settings.quickApple) { _, on in
            if on { apple.activate() }
        }
        .inspector(isPresented: $showSettings) {
            SettingsPanel(capture: capture)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .alert("เกิดข้อผิดพลาด", isPresented: Binding(
            get: { capture.errorMessage != nil },
            set: { if !$0 { capture.errorMessage = nil } }
        )) {
            Button("ตกลง") { capture.errorMessage = nil }
        } message: {
            Text(capture.errorMessage ?? "")
        }
    }

    /// Thai in the original text's colour, with « » highlights in their own colours (markers removed).
    private func thaiText(_ thai: String, colors: TextColors?, highlights: [TextColors]) -> Text {
        let base = colors.map { Color($0.fill) } ?? .white
        var out = AttributedString()
        for (segment, index) in ColorAnnotator.segments(thai) {
            var part = AttributedString(segment)
            if let index, highlights.indices.contains(index) {
                part.foregroundColor = Color(highlights[index].fill)
            } else {
                part.foregroundColor = base
            }
            out += part
        }
        return Text(out)
    }

    /// Font size whose letters are as big as the original's, from the OCR line height.
    /// Measured with Vision: point size ≈ box height × 0.9 for lines with descenders (g, j, p, q, y),
    /// × 1.1 for lines without (the box then stops at the baseline).
    private func thaiFontSize(lineHeight: CGFloat, english: String, minimum: CGFloat) -> CGFloat {
        let descenders = english.contains { "gjpqy,;".contains($0) }
        return max(lineHeight * (descenders ? 0.9 : 1.1) * model.settings.thaiSizeScale, minimum)
    }

    private func rect(for roi: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: roi.minX * size.width, y: roi.minY * size.height,
               width: roi.width * size.width, height: roi.height * size.height)
    }

    private func roiOutline(in size: CGSize) -> some View {
        let r = rect(for: model.settings.roi, in: size)
        return Rectangle()
            .strokeBorder(Color.yellow.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func subtitleOverlay(in size: CGSize) -> some View {
        if !model.thaiText.isEmpty || (model.settings.showOriginal && !model.originalText.isEmpty) {
            let roi = rect(for: model.settings.roi, in: size)
            // Scale font with the window so it looks the same at any size (fontSize is at 1280px wide).
            let scale = size.height / 720  // font sizes are tuned for a 1280x720 view
            let erase = model.settings.eraseOriginal
            let cover = model.settings.coverOriginal
            // Erased: write where the English was. Boxed: cover the ROI or sit above it.
            let target = erase ? (model.subtitleBox.map { rect(for: $0, in: size) } ?? roi) : roi
            VStack(spacing: 4 * scale) {
                if !model.thaiText.isEmpty {
                    // Erased: match the original subtitle's size. Boxed: the size slider.
                    let autoSize = erase ? model.subtitleLineHeight.map {
                        thaiFontSize(lineHeight: $0 * size.height, english: model.originalText, minimum: 12 * scale)
                    } : nil
                    thaiText(model.thaiText, colors: erase ? model.subtitleColors : nil,
                             highlights: erase ? model.subtitleHighlightColors : [])
                        .font(.system(size: autoSize ?? model.settings.fontSize * scale, weight: .semibold))
                }
                if model.settings.showOriginal, !model.originalText.isEmpty {
                    Text(ColorAnnotator.plain(model.originalText))
                        .font(.system(size: model.settings.fontSize * 0.55 * scale))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .multilineTextAlignment(.center)
            .modifier(GameTextOutline(scale: scale, enabled: erase, colors: model.subtitleColors))
            .shadow(color: erase ? .clear : .black, radius: 2, x: 0, y: 1)
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 8 * scale)
            .frame(width: erase ? max(target.width + 120 * scale, roi.width) : (cover ? roi.width : size.width * 0.9))
            .frame(minHeight: !erase && cover ? roi.height : 0)
            .background(.black.opacity(erase ? 0 : (cover ? 0.85 : 0.55)), in: RoundedRectangle(cornerRadius: 8 * scale))
            .position(
                x: erase || cover ? target.midX : size.width / 2,
                y: erase || cover ? target.midY : max(roi.minY - 60 * scale, 40 * scale)
            )
            .allowsHitTesting(false)
        }
    }

    /// Full-screen mode: each Thai translation drawn over the English it replaces.
    private func screenOverlay(in size: CGSize) -> some View {
        let scale = size.height / 720
        return ForEach(model.screenBlocks) { block in
            let r = rect(for: block.box, in: size)
            if let thai = block.thai {
                VStack(spacing: 2 * scale) {
                    thaiText(thai, colors: model.settings.eraseOriginal ? block.colors : nil,
                             highlights: model.settings.eraseOriginal ? block.highlightColors : [])
                        .font(.system(size: thaiFontSize(lineHeight: r.height / CGFloat(block.lineCount), english: block.english, minimum: 10 * scale), weight: .medium))
                        // Quick (Apple) text is slightly dimmer until the main translation replaces it.
                        .opacity(block.isFinal ? 1 : 0.85)
                    if model.settings.showOriginal {
                        Text(ColorAnnotator.plain(block.english))
                            .font(.system(size: 10 * scale))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .minimumScaleFactor(0.5)
                // Centred in the English text's box, so a shorter Thai line sits in the middle of it.
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4 * scale)
                .frame(minWidth: r.width, minHeight: r.height, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: max(r.width, 120 * scale))
                .modifier(GameTextOutline(scale: scale, enabled: model.settings.eraseOriginal, colors: block.colors))
                .background(.black.opacity(model.settings.eraseOriginal ? 0 : 0.82), in: RoundedRectangle(cornerRadius: 4 * scale))
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
            } else if model.settings.showROI {
                // Detected but not translated yet.
                Rectangle()
                    .strokeBorder(Color.yellow.opacity(0.6), lineWidth: 1)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    private var idlePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48))
            Text(capture.videoDevices.isEmpty
                 ? "ไม่พบ capture card — ต่อสายแล้วกด รีเฟรชอุปกรณ์"
                 : "เลือก capture card แล้วกด เริ่ม")
            Button("เริ่ม") { model.start() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.selectedVideoDevice == nil)
        }
        .foregroundStyle(.secondary)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("อุปกรณ์", selection: Binding(
                get: { model.settings.videoDeviceID ?? "" },
                set: { model.settings.videoDeviceID = $0 }
            )) {
                if capture.videoDevices.isEmpty {
                    Text("ไม่พบอุปกรณ์").tag("")
                }
                ForEach(capture.videoDevices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
            .frame(minWidth: 200)
        }
        ToolbarItem {
            Button { capture.refreshDevices() } label: {
                Label("รีเฟรชอุปกรณ์", systemImage: "arrow.clockwise")
            }
        }
        ToolbarItem {
            if capture.isRunning {
                Button { model.stop() } label: { Label("หยุด", systemImage: "stop.fill") }
            } else {
                Button { model.start() } label: { Label("เริ่ม", systemImage: "play.fill") }
                    .disabled(model.selectedVideoDevice == nil)
            }
        }
        ToolbarItem {
            Button { showSettings.toggle() } label: { Label("ตั้งค่า", systemImage: "sidebar.right") }
        }
    }
}

/// Outline like the original: a hard outline in its colour when the game draws one, otherwise just a
/// soft contrasting shadow. So Thai reads on any background without a box.
struct GameTextOutline: ViewModifier {
    let scale: CGFloat
    let enabled: Bool
    var colors: TextColors?

    func body(content: Content) -> some View {
        if enabled {
            let d = max(1, 1.4 * scale)
            let outline = colors.map { Color($0.outline) } ?? .black
            if colors?.hasOutline ?? true {
                content
                    .shadow(color: outline, radius: 0, x: d, y: d)
                    .shadow(color: outline, radius: 0, x: -d, y: -d)
                    .shadow(color: outline, radius: 0, x: d, y: -d)
                    .shadow(color: outline, radius: 0, x: -d, y: d)
                    .shadow(color: outline.opacity(0.6), radius: 3 * scale, x: 0, y: 1)
            } else {
                content
                    .shadow(color: outline.opacity(0.55), radius: 2 * scale, x: 0, y: 1)
            }
        } else {
            content
        }
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}
