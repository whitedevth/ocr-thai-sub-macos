import AVFoundation
import CoreVideo

/// Owns the AVCaptureSession: video from the capture card (preview + frames for OCR) and,
/// optionally, its audio played through the Mac's speakers.
final class CaptureService: NSObject, ObservableObject {
    @Published private(set) var videoDevices: [AVCaptureDevice] = []
    @Published private(set) var audioDevices: [AVCaptureDevice] = []
    @Published private(set) var isRunning = false
    @Published var errorMessage: String?
    /// What actually arrives, measured from the frames, e.g. "1920×1080 @ 59.9 fps".
    @Published private(set) var deliveredText: String?

    /// Requested resolution and frame rate; 0 means automatic.
    struct FormatChoice: Equatable {
        var width = 0
        var height = 0
        var fps = 0.0
    }

    let session = AVCaptureSession()

    /// Called on the OCR queue with at most one frame per `frameInterval`, never two at once.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the capture queue for every frame (drawing).
    var onVideoFrame: ((CVPixelBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "ocrthaisub.session")
    private let videoQueue = DispatchQueue(label: "ocrthaisub.video", qos: .userInteractive)
    private let ocrQueue = DispatchQueue(label: "ocrthaisub.ocr", qos: .userInitiated)
    private var ocrBusy = false
    private var demoTimer: DispatchSourceTimer?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioPreview = AVCaptureAudioPreviewOutput()
    private let lock = NSLock()
    private var _frameInterval: TimeInterval = 0.25
    private var lastFrameTime: CFAbsoluteTime = 0
    /// Frame counting for `deliveredText`; touched only on videoQueue.
    private var statsStart: CFAbsoluteTime = 0
    private var statsFrames = 0
    /// Format lists for the settings panel, so they aren't rebuilt on every redraw. Main thread only.
    private var resolutionCache: [String: [CMVideoDimensions]] = [:]
    private var rateCache: [String: [Double]] = [:]

    var frameInterval: TimeInterval {
        get { lock.withLock { _frameInterval } }
        set { lock.withLock { _frameInterval = newValue } }
    }

    override init() {
        super.init()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        refreshDevices()
    }

    func refreshDevices() {
        let video = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
        let audio = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .microphone],
            mediaType: .audio, position: .unspecified
        ).devices
        // Capture cards show up as .external; list them first.
        videoDevices = video.sorted { ($0.deviceType == .external ? 0 : 1) < ($1.deviceType == .external ? 0 : 1) }
        audioDevices = audio
        resolutionCache = [:]
        rateCache = [:]
    }

    /// Picks the audio device whose name best matches the video device (capture cards expose both).
    func matchingAudioDevice(for video: AVCaptureDevice) -> AVCaptureDevice? {
        let name = video.localizedName.lowercased()
        return audioDevices.first { $0.localizedName.lowercased() == name }
            ?? audioDevices.first { a in
                let an = a.localizedName.lowercased()
                return an.contains(name) || name.contains(an)
            }
    }

    func start(videoDeviceID: String, audioDeviceID: String?, volume: Float, format: FormatChoice = .init()) async {
        guard await requestAccess(for: .video) else {
            await MainActor.run { errorMessage = "ไม่ได้รับสิทธิ์ใช้กล้อง/capture card — เปิดได้ที่ System Settings › Privacy & Security › Camera" }
            return
        }
        var audioID = audioDeviceID
        if audioID != nil, !(await requestAccess(for: .audio)) {
            audioID = nil
            await MainActor.run { errorMessage = "ไม่ได้รับสิทธิ์ใช้ไมโครโฟน จึงไม่เล่นเสียงจาก capture card" }
        }

        resetFrameStats()
        let error: String? = await withCheckedContinuation { cont in
            sessionQueue.async { [self] in
                cont.resume(returning: configure(videoDeviceID: videoDeviceID, audioDeviceID: audioID, volume: volume, format: format))
            }
        }
        await MainActor.run {
            if let error { errorMessage = error }
            isRunning = session.isRunning
            if !isRunning { deliveredText = nil }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            session.stopRunning()
            DispatchQueue.main.async {
                self.isRunning = false
                self.deliveredText = nil
            }
        }
    }

    func setVolume(_ volume: Float) {
        audioPreview.volume = volume
    }

    private func configure(videoDeviceID: String, audioDeviceID: String?, volume: Float, format: FormatChoice) -> String? {
        session.beginConfiguration()
        var failed = true
        // Held until the session runs, so the session doesn't swap the chosen format back.
        var lockedDevice: AVCaptureDevice?
        var frameDuration = CMTime.invalid  // .invalid = the format's default rate
        defer {
            session.commitConfiguration()
            // After the commit, so applying a session preset can't overwrite the rate.
            if let lockedDevice, !failed {
                lockedDevice.activeVideoMinFrameDuration = frameDuration
                lockedDevice.activeVideoMaxFrameDuration = frameDuration
            }
            if failed {
                if session.isRunning { session.stopRunning() }
            } else if !session.isRunning {
                session.startRunning()
            }
            lockedDevice?.unlockForConfiguration()
        }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = AVCaptureDevice(uniqueID: videoDeviceID) else { return "ไม่พบอุปกรณ์วิดีโอที่เลือก" }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return "เพิ่ม \(device.localizedName) เข้า session ไม่ได้" }
            session.addInput(input)
        } catch {
            return "เปิด \(device.localizedName) ไม่ได้: \(error.localizedDescription)"
        }
        // Auto resolution with a set fps still needs a format that can do that fps: a preset could
        // pick a 30 fps format when the same size also comes at 60.
        let chosen = format.width > 0
            ? Self.bestFormat(of: device, width: format.width, height: format.height, fps: format.fps)
            : (format.fps > 0 ? Self.autoFormat(of: device, fps: format.fps) : nil)
        if chosen == nil {
            for preset: AVCaptureSession.Preset in [.hd1920x1080, .hd1280x720, .high] where session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
                break
            }
        }
        // Always locked, so switching fps back to automatic also resets an earlier custom rate.
        do {
            try device.lockForConfiguration()
            lockedDevice = device
            if let chosen { device.activeFormat = chosen }
            if format.fps > 0, let duration = Self.frameDuration(format.fps, in: device.activeFormat) {
                frameDuration = duration
            }
        } catch {
            if chosen != nil || format.fps > 0 {
                DispatchQueue.main.async { self.errorMessage = "ตั้งความละเอียด/fps ไม่ได้ ใช้ค่าอัตโนมัติแทน: \(error.localizedDescription)" }
            }
        }
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        failed = false

        if let audioDeviceID, let audioDevice = AVCaptureDevice(uniqueID: audioDeviceID),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
            audioPreview.volume = volume
            if session.canAddOutput(audioPreview) { session.addOutput(audioPreview) }
        }
        return nil
    }

    // MARK: Formats

    func resolutions(of device: AVCaptureDevice) -> [CMVideoDimensions] {
        if let cached = resolutionCache[device.uniqueID] { return cached }
        let list = Self.resolutions(of: device)
        resolutionCache[device.uniqueID] = list
        return list
    }

    func frameRates(of device: AVCaptureDevice, width: Int, height: Int) -> [Double] {
        let key = "\(device.uniqueID)|\(width)x\(height)"
        if let cached = rateCache[key] { return cached }
        let list = Self.frameRates(of: device, width: width, height: height)
        rateCache[key] = list
        return list
    }

    /// Resolutions the device offers, largest first.
    private static func resolutions(of device: AVCaptureDevice) -> [CMVideoDimensions] {
        var seen = Set<Int64>()
        return device.formats
            .map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
            .filter { seen.insert(Int64($0.width) << 32 | Int64($0.height)).inserted }
            .sorted { Int($0.width) * Int($0.height) > Int($1.width) * Int($1.height) }
    }

    /// Frame rates offered at a resolution (any resolution when width is 0), fastest first.
    private static func frameRates(of device: AVCaptureDevice, width: Int, height: Int) -> [Double] {
        let common: [Double] = [240, 144, 120, 60, 59.94, 50, 30, 29.97, 25, 24, 15]
        var rates: [Double] = []
        func add(_ r: Double) {
            let r = (r * 100).rounded() / 100
            if r >= 10, !rates.contains(where: { abs($0 - r) < 0.01 }) { rates.append(r) }
        }
        for f in device.formats where width == 0 || matches(f, width, height) {
            for range in f.videoSupportedFrameRateRanges {
                add(range.maxFrameRate)
                add(range.minFrameRate)
                for r in common where r > range.minFrameRate && r < range.maxFrameRate { add(r) }
            }
        }
        return rates.sorted(by: >)
    }

    private static func matches(_ f: AVCaptureDevice.Format, _ width: Int, _ height: Int) -> Bool {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return Int(d.width) == width && Int(d.height) == height
    }

    /// The format with this resolution that can do `fps` (or the fastest one when fps is 0).
    private static func bestFormat(of device: AVCaptureDevice, width: Int, height: Int, fps: Double) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { matches($0, width, height) }
        let maxRate = { (f: AVCaptureDevice.Format) in f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        if fps > 0, let f = candidates.filter({ frameDuration(fps, in: $0) != nil }).max(by: { maxRate($0) < maxRate($1) }) {
            return f
        }
        return candidates.max { maxRate($0) < maxRate($1) }
    }

    /// For automatic resolution with a set fps: 1080p, then 720p, then the largest size that can do it.
    private static func autoFormat(of device: AVCaptureDevice, fps: Double) -> AVCaptureDevice.Format? {
        for (w, h) in [(1920, 1080), (1280, 720)] {
            if let f = bestFormat(of: device, width: w, height: h, fps: fps), frameDuration(fps, in: f) != nil { return f }
        }
        let area = { (f: AVCaptureDevice.Format) -> Int in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        return device.formats.filter { frameDuration(fps, in: $0) != nil }.max { area($0) < area($1) }
    }

    /// Frame duration for `fps` if the format supports it; uses the format's exact value at a range's ends (59.94 = 1001/60000).
    private static func frameDuration(_ fps: Double, in format: AVCaptureDevice.Format) -> CMTime? {
        for range in format.videoSupportedFrameRateRanges {
            if abs(range.maxFrameRate - fps) < 0.01 { return range.minFrameDuration }
            if abs(range.minFrameRate - fps) < 0.01 { return range.maxFrameDuration }
            if fps > range.minFrameRate, fps < range.maxFrameRate {
                return CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
            }
        }
        return nil
    }

    private func requestAccess(for type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
}

extension CaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handle(pixelBuffer)
    }

    /// Development: feed a still image as if it came from the capture card (OCRSUB_DEMO=/path/frame.png).
    func startDemoFeed(_ pixelBuffer: CVPixelBuffer, fps: Double = 60) {
        DispatchQueue.main.async { self.isRunning = true }
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now(), repeating: 1 / fps)
        timer.setEventHandler { [weak self] in self?.handle(pixelBuffer) }
        timer.resume()
        demoTimer = timer
    }

    private func resetFrameStats() {
        videoQueue.async { [self] in
            statsStart = 0
            statsFrames = 0
        }
    }

    private func handle(_ pixelBuffer: CVPixelBuffer) {
        onVideoFrame?(pixelBuffer)
        let now = CFAbsoluteTimeGetCurrent()
        countFrame(pixelBuffer, at: now)

        // OCR on its own queue so drawing never waits for it (~70 ms per 1080p frame).
        let due: Bool = lock.withLock {
            guard !ocrBusy, now - lastFrameTime >= _frameInterval else { return false }
            ocrBusy = true
            lastFrameTime = now
            return true
        }
        guard due else { return }
        ocrQueue.async { [self] in
            onFrame?(pixelBuffer)
            lock.withLock { ocrBusy = false }
        }
    }

    /// Publishes the real frame size and rate about once a second.
    private func countFrame(_ pixelBuffer: CVPixelBuffer, at now: CFAbsoluteTime) {
        guard statsStart > 0 else {
            statsStart = now
            statsFrames = 0
            return
        }
        statsFrames += 1
        let elapsed = now - statsStart
        guard elapsed >= 1 else { return }
        let text = String(format: "%d×%d @ %.1f fps", CVPixelBufferGetWidth(pixelBuffer),
                          CVPixelBufferGetHeight(pixelBuffer), Double(statsFrames) / elapsed)
        statsStart = now
        statsFrames = 0
        DispatchQueue.main.async {
            if self.isRunning { self.deliveredText = text }
        }
    }
}
