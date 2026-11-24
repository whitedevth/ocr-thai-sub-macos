import AVFoundation
import CoreVideo

/// Owns the AVCaptureSession: video from the capture card (preview + frames for OCR) and,
/// optionally, its audio played through the Mac's speakers.
final class CaptureService: NSObject, ObservableObject {
    @Published private(set) var videoDevices: [AVCaptureDevice] = []
    @Published private(set) var audioDevices: [AVCaptureDevice] = []
    @Published private(set) var isRunning = false
    @Published var errorMessage: String?

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

    func start(videoDeviceID: String, audioDeviceID: String?, volume: Float) async {
        guard await requestAccess(for: .video) else {
            await MainActor.run { errorMessage = "ไม่ได้รับสิทธิ์ใช้กล้อง/capture card — เปิดได้ที่ System Settings › Privacy & Security › Camera" }
            return
        }
        var audioID = audioDeviceID
        if audioID != nil, !(await requestAccess(for: .audio)) {
            audioID = nil
            await MainActor.run { errorMessage = "ไม่ได้รับสิทธิ์ใช้ไมโครโฟน จึงไม่เล่นเสียงจาก capture card" }
        }

        let error: String? = await withCheckedContinuation { cont in
            sessionQueue.async { [self] in
                cont.resume(returning: configure(videoDeviceID: videoDeviceID, audioDeviceID: audioID, volume: volume))
            }
        }
        await MainActor.run {
            if let error { errorMessage = error }
            isRunning = session.isRunning
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    func setVolume(_ volume: Float) {
        audioPreview.volume = volume
    }

    private func configure(videoDeviceID: String, audioDeviceID: String?, volume: Float) -> String? {
        session.beginConfiguration()
        var failed = true
        defer {
            session.commitConfiguration()
            if failed {
                if session.isRunning { session.stopRunning() }
            } else if !session.isRunning {
                session.startRunning()
            }
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
        for preset: AVCaptureSession.Preset in [.hd1920x1080, .hd1280x720, .high] where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
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

    private func handle(_ pixelBuffer: CVPixelBuffer) {
        onVideoFrame?(pixelBuffer)

        // OCR on its own queue so drawing never waits for it (~70 ms per 1080p frame).
        let now = CFAbsoluteTimeGetCurrent()
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
}
