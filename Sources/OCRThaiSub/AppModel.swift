import AppKit
import AVFoundation
import Foundation
import SubtitleCore

enum OCRMode: String, Codable, CaseIterable {
    /// Read only the subtitle box and show one translated line.
    case subtitle
    /// Read the whole screen and translate every text block in place.
    case fullScreen
}

struct Settings: Codable, Equatable {
    var mode = OCRMode.subtitle
    /// Subtitle region, normalised 0...1 from the top-left of the video.
    var roiLeft = 0.10
    var roiRight = 0.90
    var roiTop = 0.74
    var roiBottom = 0.96
    var ocrPerSecond = 4.0
    var fontSize = 34.0
    var coverOriginal = true
    var showOriginal = false
    var showROI = true
    var playAudio = true
    var volume = 1.0
    var backend = TranslatorBackend.claude
    var model = "claude-opus-5-5"
    var ollamaModel = "gemma3:12b"
    var ollamaURL = "http://localhost:11434"
    var gameContext = ""
    var videoDeviceID: String?
    /// Show Apple's on-device translation immediately.
    var quickApple = true
    /// Then replace it with the main translator (Claude or Ollama).
    var refine = true
    /// Erase the game's English text from the picture and draw Thai in its place (vs. a dark box).
    var eraseOriginal = true
    /// Thai size relative to the original text's size (1 = same size).
    var thaiSizeScale = 1.0
    /// Capture resolution and frame rate; 0 = let the device/session choose.
    var captureWidth = 0
    var captureHeight = 0
    var captureFPS = 0.0

    var roi: CGRect {
        let l = min(roiLeft, roiRight), r = max(roiLeft, roiRight)
        let t = min(roiTop, roiBottom), b = max(roiTop, roiBottom)
        return CGRect(x: l, y: t, width: r - l, height: b - t)
    }

    static let storageKey = "settings.v1"

    init() {}

    /// Missing keys (settings saved by an older version) fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        mode = v(.mode, d.mode)
        roiLeft = v(.roiLeft, d.roiLeft); roiRight = v(.roiRight, d.roiRight)
        roiTop = v(.roiTop, d.roiTop); roiBottom = v(.roiBottom, d.roiBottom)
        ocrPerSecond = v(.ocrPerSecond, d.ocrPerSecond); fontSize = v(.fontSize, d.fontSize)
        coverOriginal = v(.coverOriginal, d.coverOriginal); showOriginal = v(.showOriginal, d.showOriginal)
        showROI = v(.showROI, d.showROI); playAudio = v(.playAudio, d.playAudio); volume = v(.volume, d.volume)
        backend = v(.backend, d.backend); model = v(.model, d.model)
        ollamaModel = v(.ollamaModel, d.ollamaModel); ollamaURL = v(.ollamaURL, d.ollamaURL)
        gameContext = v(.gameContext, d.gameContext)
        videoDeviceID = try? c.decodeIfPresent(String.self, forKey: .videoDeviceID)
        quickApple = v(.quickApple, d.quickApple); refine = v(.refine, d.refine)
        eraseOriginal = v(.eraseOriginal, d.eraseOriginal)
        thaiSizeScale = v(.thaiSizeScale, d.thaiSizeScale)
        captureWidth = v(.captureWidth, d.captureWidth); captureHeight = v(.captureHeight, d.captureHeight)
        captureFPS = v(.captureFPS, d.captureFPS)
    }

    static func load() -> Settings {
        // Settings saved before the rename live under the old bundle id.
        guard let data = UserDefaults.standard.data(forKey: storageKey)
                ?? UserDefaults(suiteName: "local.ps5thaisubs")?.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// Thread-safe holder so the video queue can read the current ROI.
final class ROIBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CGRect(x: 0, y: 0, width: 1, height: 1)
    func get() -> CGRect { lock.withLock { value } }
    func set(_ v: CGRect) { lock.withLock { value = v } }
}

final class ModeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = OCRMode.subtitle
    func get() -> OCRMode { lock.withLock { value } }
    func set(_ v: OCRMode) { lock.withLock { value = v } }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = Settings.load() {
        didSet { settingsChanged(from: oldValue) }
    }
    @Published var apiKey: String
    @Published private(set) var originalText = ""
    @Published private(set) var thaiText = ""
    @Published private(set) var status = "พร้อม"
    @Published private(set) var lastLatency: TimeInterval?
    /// How long OCR takes per frame (ms), and from first reading a new text to its Thai on screen (s).
    @Published private(set) var ocrMilliseconds: Double = 0
    @Published private(set) var textToThai: TimeInterval?
    /// Full-screen mode: text blocks on screen with their Thai (when ready).
    @Published private(set) var screenBlocks: [ScreenBlock] = []
    /// Width / height of the incoming video, so the overlay lines up with the picture (not always 16:9).
    @Published private(set) var videoAspect: CGFloat = 16 / 9

    let capture = CaptureService()
    let apple = AppleTranslationBridge()
    let renderer = VideoRenderer()
    /// Subtitle mode: where the English subtitle lines are on screen (normalised), for placing Thai.
    @Published private(set) var subtitleBox: CGRect?
    /// Subtitle mode: height of one English line (normalised), to size Thai like the original.
    @Published private(set) var subtitleLineHeight: CGFloat?
    /// Subtitle mode: colours of the English subtitle, and of its « » highlights.
    @Published private(set) var subtitleColors: TextColors?
    @Published private(set) var subtitleHighlightColors: [TextColors] = []
    private let translator = Translator()
    private let roiBox = ROIBox()
    private let modeBox = ModeBox()
    private var tracker = SubtitleTracker()
    /// When each on-screen text was first read, to measure the delay until its Thai shows.
    private var firstSeen: [Int: Date] = [:]
    private var lineFirstSeen = Date()
    private var lastRawKey = ""
    /// OCR reads in a row with no text in the ROI (clears the erase even when no line was shown).
    private var emptyReads = 0
    /// Colours of each OCR reading of the current subtitle, so the translated reading gets its own.
    private var readingColors: [String: (TextColors?, [TextColors])] = [:]
    private var screenTracker = ScreenTextTracker()
    /// Full-screen mode: blocks waiting for the request in flight to finish, sent together next.
    private var queuedJobs: [TranslationJob] = []
    private var batchInFlight = false
    private var sequence = 0
    private var shownSequence = 0
    /// Whether the subtitle on screen is the main translator's (true) or Apple's quick one (false).
    private var shownFinal = true

    init() {
        apiKey = KeychainStore.loadAPIKey() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        roiBox.set(settings.roi)
        modeBox.set(settings.mode)
        capture.frameInterval = 1 / max(settings.ocrPerSecond, 0.5)

        // Subtitle text is big; skipping small text there filters HUD noise. Full screen needs small text too.
        let subtitleOCR = OCRService(minTextHeight: 0.08, wantWordBoxes: true)
        let screenOCR = OCRService(minTextHeight: 0.012, wantWordBoxes: true)
        // Reads text colours (per word, for highlighted keywords) straight from the frame.
        func annotate(_ lines: [OCRLine], _ pixelBuffer: CVPixelBuffer) -> [OCRLine] {
            guard !lines.isEmpty else { return lines }
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let reader = BGRAPixelReader(pixelBuffer) else { return lines }
            return ColorAnnotator.annotate(lines, frame: reader)
        }
        let roiBox = self.roiBox, modeBox = self.modeBox
        capture.onFrame = { [weak self] pixelBuffer in
            let start = CFAbsoluteTimeGetCurrent()
            switch modeBox.get() {
            case .subtitle:
                let lines = annotate(subtitleOCR.recognizeLines(pixelBuffer: pixelBuffer, roi: roiBox.get()), pixelBuffer)
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                Task { @MainActor in
                    self?.noteOCR(ms)
                    self?.ingest(OCRService.join(lines), lines: lines)
                }
            case .fullScreen:
                let lines = annotate(screenOCR.recognizeLines(pixelBuffer: pixelBuffer, roi: CGRect(x: 0, y: 0, width: 1, height: 1)), pixelBuffer)
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                Task { @MainActor in
                    self?.noteOCR(ms)
                    self?.ingestScreen(lines)
                }
            }
        }
        applyStableReads()

        let renderer = self.renderer
        renderer.setEraseEnabled(settings.eraseOriginal)
        renderer.onAspectChange = { [weak self] aspect in
            Task { @MainActor in self?.videoAspect = aspect }
        }
        capture.onVideoFrame = { renderer.render($0) }

        if settings.videoDeviceID == nil {
            settings.videoDeviceID = capture.videoDevices.first?.uniqueID
        }
    }

    var selectedVideoDevice: AVCaptureDevice? {
        capture.videoDevices.first { $0.uniqueID == settings.videoDeviceID }
    }

    func saveAPIKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = key
        status = KeychainStore.saveAPIKey(key) ? "บันทึก API key ใน Keychain แล้ว" : "บันทึก API key ไม่สำเร็จ"
        sendQueuedBatch()  // blocks that waited for a key
    }

    /// nil (with a status message) when the chosen backend isn't usable yet.
    private func translatorConfig() -> TranslatorConfig? {
        switch settings.backend {
        case .claude:
            guard !apiKey.isEmpty else {
                status = "ยังไม่ได้ใส่ Anthropic API key (แถบตั้งค่าด้านขวา)"
                return nil
            }
            return TranslatorConfig(backend: .claude, apiKey: apiKey, model: settings.model, gameContext: settings.gameContext)
        case .ollama:
            guard let url = URL(string: settings.ollamaURL) else {
                status = "Ollama URL ไม่ถูกต้อง"
                return nil
            }
            return TranslatorConfig(backend: .ollama, model: settings.ollamaModel, ollamaURL: url, gameContext: settings.gameContext)
        }
    }

    /// Loads the local model ahead of time so the first line isn't slow.
    private func warmUpTranslator() {
        guard settings.backend == .ollama, let config = translatorConfig() else { return }
        status = "กำลังโหลดโมเดล \(config.model) ใน Ollama…"
        Task {
            await translator.warmUp(config: config)
            if status.hasPrefix("กำลังโหลดโมเดล") { status = "โมเดล \(config.model) พร้อมแล้ว" }
        }
    }

    func start() {
        guard let device = selectedVideoDevice else {
            capture.errorMessage = "ยังไม่ได้เลือก capture card"
            return
        }
        let audio = settings.playAudio ? capture.matchingAudioDevice(for: device)?.uniqueID : nil
        capture.errorMessage = nil
        let format = CaptureService.FormatChoice(width: settings.captureWidth, height: settings.captureHeight, fps: settings.captureFPS)
        Task { await capture.start(videoDeviceID: device.uniqueID, audioDeviceID: audio, volume: Float(settings.volume), format: format) }
        defer { warmUpTranslator() }
        status = audio == nil && settings.playAudio ? "เริ่มแล้ว (ไม่พบอุปกรณ์เสียงที่ชื่อตรงกับ capture card)" : "เริ่มแล้ว"
    }

    func stop() {
        capture.stop()
        clearSubtitle()
        status = "หยุดแล้ว"
    }

    func resetContext() {
        Task { await translator.resetContext() }
        status = "ล้างบริบทการแปลแล้ว"
    }

    private func settingsChanged(from old: Settings) {
        settings.save()
        if settings.roi != old.roi { roiBox.set(settings.roi) }
        if settings.quickApple != old.quickApple || settings.refine != old.refine { applyStableReads() }
        if settings.eraseOriginal != old.eraseOriginal { renderer.setEraseEnabled(settings.eraseOriginal) }
        if settings.backend != old.backend || settings.ollamaModel != old.ollamaModel { warmUpTranslator() }
        if settings.backend != old.backend || settings.refine != old.refine { sendQueuedBatch() }
        if settings.mode != old.mode {
            modeBox.set(settings.mode)
            clearSubtitle()
        }
        if settings.ocrPerSecond != old.ocrPerSecond { capture.frameInterval = 1 / max(settings.ocrPerSecond, 0.5) }
        if settings.volume != old.volume { capture.setVolume(Float(settings.volume)) }
        let restartNeeded = settings.videoDeviceID != old.videoDeviceID || settings.playAudio != old.playAudio
            || settings.captureWidth != old.captureWidth || settings.captureHeight != old.captureHeight
            || settings.captureFPS != old.captureFPS
        if restartNeeded, capture.isRunning { start() }
    }

    /// Apple-only: translate on the first read (it is nearly free, so a half-drawn line just gets
    /// re-translated). With a slower main translator, wait for the text to read the same twice.
    private var stableReads: Int { settings.quickApple && !settings.refine ? 1 : 2 }

    private func applyStableReads() {
        tracker.requiredStableReads = stableReads
        screenTracker.requiredStableReads = stableReads
    }

    private func noteOCR(_ ms: Double) {
        ocrMilliseconds = ocrMilliseconds == 0 ? ms : ocrMilliseconds * 0.8 + ms * 0.2
    }

    private func ingest(_ raw: String, lines: [OCRLine]) {
        // An OCR result still in flight from before a mode switch.
        guard settings.mode == .subtitle else { return }
        let key = String(raw.lowercased().filter { $0.isLetter || $0.isNumber })
        if key != lastRawKey {
            lastRawKey = key
            if !key.isEmpty {
                lineFirstSeen = Date()
                // New line: take its colours (kept while the same line stays, so they don't flicker).
                subtitleColors = lines.compactMap(\.colors).first
                subtitleHighlightColors = lines.flatMap(\.highlightColors)
            }
        }
        if !lines.isEmpty {
            if readingColors.count > 64 { readingColors.removeAll() }
            readingColors[raw.trimmingCharacters(in: .whitespacesAndNewlines)] = (lines.compactMap(\.colors).first, lines.flatMap(\.highlightColors))
        }
        // Erase English as soon as it is read; Thai follows ~0.1 s later (Apple) and is refined after.
        if lines.isEmpty {
            // Text that was erased but never became a shown line (a one-frame read, or a line no
            // translator took) gets no `.clear` from the tracker; un-erase it here.
            emptyReads += 1
            if emptyReads == 3 { clearSubtitle() }
        } else {
            emptyReads = 0
            renderer.setEraseRegions(lines.map { EraseRegion(box: $0.box, flatBackground: $0.flatBackground) })
            let union = lines.dropFirst().reduce(lines[0].box) { $0.union($1.box) }
            if subtitleBox.map({ ScreenTextTracker.reallyMoved(from: $0, to: union) }) ?? true {
                subtitleBox = union
                let heights = lines.map(\.box.height).sorted()
                subtitleLineHeight = heights[heights.count / 2]
            }
        }
        switch tracker.ingest(raw) {
        case let .show(text):
            if let (colors, highlights) = readingColors[text] {
                subtitleColors = colors
                subtitleHighlightColors = highlights
            }
            originalText = text
            translate(text)
        case .clear:
            clearSubtitle()
        case nil:
            break
        }
    }

    private func clearSubtitle() {
        renderer.setEraseRegions([])
        subtitleBox = nil
        subtitleLineHeight = nil
        subtitleColors = nil
        subtitleHighlightColors = []
        readingColors = [:]
        originalText = ""
        thaiText = ""
        shownSequence = sequence  // drop any translation still in flight
        shownFinal = true  // ...including a late final result for the line just cleared
        tracker = SubtitleTracker(requiredStableReads: stableReads)
        screenTracker.reset()
        firstSeen = [:]
        screenBlocks = []
        queuedJobs = []
    }

    // MARK: Full-screen mode

    private func ingestScreen(_ lines: [OCRLine]) {
        guard settings.mode == .fullScreen else { return }
        let jobs = screenTracker.ingest(lines)
        screenBlocks = screenTracker.blocks
        let now = Date()
        for b in screenBlocks where firstSeen[b.id] == nil { firstSeen[b.id] = now }
        let onScreen = Set(screenBlocks.map(\.id))
        firstSeen = firstSeen.filter { onScreen.contains($0.key) }
        renderer.setEraseRegions(screenBlocks.map { EraseRegion(box: $0.box, flatBackground: $0.flatBackground) })
        guard !jobs.isEmpty else { return }

        let useApple = settings.quickApple && apple.isReady
        if useApple {
            let started = Date()
            Task {
                do {
                    let result = try await apple.translate(jobs.map(\.english))
                    guard settings.mode == .fullScreen else { return }
                    for job in jobs {
                        if let thai = result[job.english] { screenTracker.setTranslation(thai, for: job, final: !settings.refine) }
                    }
                    let delays = jobs.compactMap { firstSeen[$0.blockID].map { Date().timeIntervalSince($0) } }
                    if let worst = delays.max() { textToThai = worst }
                    screenBlocks = screenTracker.blocks
                    status = String(format: "Apple แปล %d กล่องใน %.2f วินาที", jobs.count, Date().timeIntervalSince(started))
                } catch {
                    status = "Apple แปลไม่สำเร็จ: \(error.localizedDescription)"
                    if !settings.refine { jobs.forEach { screenTracker.translationFailed(for: $0) } }
                }
            }
        }
        guard settings.refine else {
            if !useApple {
                status = settings.quickApple ? "รอ Apple Translation พร้อม…" : "ปิดตัวแปลทั้งสองแบบอยู่"
                // Nothing translated them: let the next read ask again.
                jobs.forEach { screenTracker.translationFailed(for: $0) }
            }
            return
        }
        queuedJobs.removeAll { q in jobs.contains { $0.blockID == q.blockID } }
        queuedJobs.append(contentsOf: jobs)
        sendQueuedBatch()
    }

    /// One request at a time; blocks that appear meanwhile go out together in the next one.
    private func sendQueuedBatch() {
        // Blocks that left the screen while waiting don't need translating any more.
        let onScreen = Set(screenTracker.blocks.map(\.id))
        queuedJobs.removeAll { !onScreen.contains($0.blockID) }
        guard !batchInFlight, !queuedJobs.isEmpty, settings.refine else { return }
        guard let config = translatorConfig() else {
            // No main translator yet. Blocks Apple is covering wait in the queue (sent once a key or
            // backend is set); the rest are asked for again on the next read.
            if !(settings.quickApple && apple.isReady) {
                queuedJobs.forEach { screenTracker.translationFailed(for: $0) }
                queuedJobs = []
            }
            return
        }
        let jobs = queuedJobs
        queuedJobs = []
        batchInFlight = true
        let started = Date()
        Task {
            defer {
                batchInFlight = false
                sendQueuedBatch()
            }
            // With Apple's quick text on screen, a failed refinement just leaves it there (no retry storm).
            let retry = !(settings.quickApple && apple.isReady)
            do {
                let result = try await translator.translateBatch(jobs.map(\.english), config: config)
                guard settings.mode == .fullScreen else { return }
                for job in jobs {
                    if let thai = result[job.english] {
                        screenTracker.setTranslation(thai, for: job, final: true)
                    } else if retry {
                        screenTracker.translationFailed(for: job)
                    }
                }
                screenBlocks = screenTracker.blocks
                lastLatency = Date().timeIntervalSince(started)
                status = String(format: "%@ แปล %d กล่องใน %.1f วินาที", config.backend.displayName, jobs.count, lastLatency ?? 0)
            } catch {
                if retry { jobs.forEach { screenTracker.translationFailed(for: $0) } }
                status = "\(config.backend.displayName) แปลไม่สำเร็จ: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Subtitle mode

    private func translate(_ text: String) {
        sequence += 1
        let id = sequence
        let started = Date()

        let useApple = settings.quickApple && apple.isReady
        if !useApple, !settings.refine {
            status = settings.quickApple ? "รอ Apple Translation พร้อม…" : "ปิดตัวแปลทั้งสองแบบอยู่"
            // Nothing will translate this line: forget it so the next read emits it again.
            dropLine(id)
            return
        }
        if useApple {
            Task {
                do {
                    guard let thai = try await apple.translate([text])[text] else { return }
                    if showSubtitle(thai, id: id, final: !settings.refine) {
                        status = String(format: "Apple %.2f วินาที", Date().timeIntervalSince(started))
                    }
                } catch {
                    status = "Apple แปลไม่สำเร็จ: \(error.localizedDescription)"
                    // Apple was the only translator: forget the line so the next read tries again.
                    // Otherwise blank it until the main translator answers.
                    if !settings.refine { dropLine(id) } else { blankLine(id) }
                }
            }
        }

        guard settings.refine else { return }
        guard let config = translatorConfig() else {
            // Nothing will translate this line: forget it so the next read emits it again.
            if !useApple { dropLine(id) }
            return
        }
        Task {
            do {
                let thai = try await translator.translate(text, config: config)
                if showSubtitle(thai, id: id, final: true) {
                    lastLatency = Date().timeIntervalSince(started)
                    status = String(format: "%@ %.1f วินาที", config.backend.displayName, lastLatency ?? 0)
                }
            } catch {
                status = "\(config.backend.displayName) แปลไม่สำเร็จ: \(error.localizedDescription)"
                // Nothing else will show this line: don't leave the previous line's Thai over it.
                // (The tracker is kept, so a failing API isn't called again on every read.)
                if !useApple { blankLine(id) }
            }
        }
    }

    /// No translator could take line `id`: blank the subtitle (so the previous line's Thai doesn't sit over
    /// this one) and forget the line so the next read emits it again.
    private func dropLine(_ id: Int) {
        guard id == sequence else { return }
        tracker = SubtitleTracker(requiredStableReads: stableReads)
        blankLine(id)
    }

    /// Hides the previous line's Thai while line `id` has none; a final result for `id` can still show.
    private func blankLine(_ id: Int) {
        guard id == sequence, shownSequence < id else { return }
        thaiText = ""
        shownSequence = id
        shownFinal = false
    }

    /// Shows a translation unless a newer line, or the final translation of this line, is already up.
    @discardableResult
    private func showSubtitle(_ thai: String, id: Int, final: Bool) -> Bool {
        let newer = id > shownSequence
        let upgrade = id == shownSequence && final && !shownFinal
        guard newer || upgrade else { return false }
        if newer { textToThai = Date().timeIntervalSince(lineFirstSeen) }
        shownSequence = id
        shownFinal = final
        thaiText = thai
        return true
    }
}

// MARK: - Self-test (development)

extension AppModel {
    /// `open --env OCRSUB_SELFTEST=/path/out.txt build/OCRThaiSub.app` runs a few subtitle lines through
    /// the real translate path (Apple first, then the main translator), logs timings, and quits.
    /// `OCRSUB_DEMO=/path/frame.png` plays a still frame through the whole pipeline (no capture card needed).
    func runDemoFeedIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["OCRSUB_DEMO"],
              let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(pb, [])
        warmUpTranslator()
        capture.startDemoFeed(pb)
        status = "โหมดทดสอบ: เล่นภาพ \((path as NSString).lastPathComponent)"

        // OCRSUB_SNAPSHOT=/dir: after a few seconds, save the drawn frame and what is on screen, then quit.
        guard let dir = ProcessInfo.processInfo.environment["OCRSUB_SNAPSHOT"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            if let cg = renderer.snapshot() {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("erased.png"))
            }
            var log = "mode=\(settings.mode.rawValue) erase=\(settings.eraseOriginal) render=\(String(format: "%.2f", renderer.averageRenderMilliseconds))ms/frame\n"
            log += "status=\(status)\n"
            log += String(format: "ocr=%.0fms textToThai=%@ ocrPerSecond=%.0f stableReads=%d\n", ocrMilliseconds,
                          textToThai.map { String(format: "%.2fs", $0) } ?? "-", settings.ocrPerSecond, stableReads)
            if settings.mode == .subtitle {
                log += "subtitleBox=\(subtitleBox.map { "\($0)" } ?? "nil")\nthai=\(thaiText)\n"
                log += "english=\(originalText)\n"
                if let c = subtitleColors {
                    log += String(format: "fill=#%02X%02X%02X outline=#%02X%02X%02X hasOutline=%@\n",
                                  Int(c.fill.r * 255), Int(c.fill.g * 255), Int(c.fill.b * 255),
                                  Int(c.outline.r * 255), Int(c.outline.g * 255), Int(c.outline.b * 255), c.hasOutline ? "yes" : "no")
                }
                for h in subtitleHighlightColors {
                    log += String(format: "highlight=#%02X%02X%02X\n", Int(h.fill.r * 255), Int(h.fill.g * 255), Int(h.fill.b * 255))
                }
            }
            func hex(_ c: RGB?) -> String {
                guard let c else { return "-" }
                return String(format: "#%02X%02X%02X", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
            }
            for b in screenBlocks {
                log += String(format: "block %.4f %.4f %.4f %.4f lines=%d final=%@ | %@ | %@",
                              b.box.minX, b.box.minY, b.box.width, b.box.height, b.lineCount,
                              b.isFinal ? "yes" : "no", b.english, b.thai ?? "-")
                log += " | fill=\(hex(b.colors?.fill)) outline=\(hex(b.colors?.outline))\(b.colors?.hasOutline == true ? "" : "(none)")"
                log += " highlights=\(b.highlightColors.map { hex($0.fill) })\n"
            }
            try? log.write(toFile: URL(fileURLWithPath: dir).appendingPathComponent("state.txt").path, atomically: true, encoding: .utf8)
            NSApplication.shared.terminate(nil)
        }
    }

    func runSelfTestIfRequested() {
        guard let out = ProcessInfo.processInfo.environment["OCRSUB_SELFTEST"] else { return }
        Task { @MainActor in
            var log = ""
            func say(_ line: String) {
                log += line + "\n"
                try? log.write(toFile: out, atomically: true, encoding: .utf8)
            }
            apple.activate()
            let waitStart = Date()
            while !apple.isReady, apple.errorMessage == nil, Date().timeIntervalSince(waitStart) < 90 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            say(String(format: "apple ready=%@ after %.2fs %@", apple.isReady ? "yes" : "no",
                       Date().timeIntervalSince(waitStart), apple.errorMessage ?? ""))
            say("main translator: \(settings.backend.displayName) refine=\(settings.refine) quickApple=\(settings.quickApple)")
            warmUpTranslator()
            try? await Task.sleep(for: .seconds(2))

            for line in ["Kratos: We must keep moving, boy.",
                         "Stay close. Do not let your guard down.",
                         "The bridge is out. We'll have to find another way across.",
                         "Resume Game"] {
                let start = Date()
                translate(line)
                let id = sequence
                var seen: [String] = []
                while Date().timeIntervalSince(start) < 20 {
                    if shownSequence == id, seen.last != thaiText {
                        seen.append(thaiText)
                        say(String(format: "  %.3fs %@ | %@", Date().timeIntervalSince(start),
                                   shownFinal ? "final" : "quick", thaiText))
                    }
                    if shownSequence == id, shownFinal { break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                say("  <- \(line)   [\(status)]")
            }
            say("DONE")
            NSApplication.shared.terminate(nil)
        }
    }
}

extension TranslatorBackend {
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .ollama: return "Ollama"
        }
    }
}
