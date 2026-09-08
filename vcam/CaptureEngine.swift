import AppKit
import AVFoundation
import CoreImage
@preconcurrency import CoreVideo
@preconcurrency import ScreenCaptureKit

/// Capture, Core Image rendering, and preview use desktop sRGB. The writer
/// converts these explicitly tagged RGB buffers to standard Rec.709 video.
/// The pixels and their source tags must agree before that conversion.
private enum CaptureColor {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func tag(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}

/// Owns capture lifetime on the main actor; all frame processing and encoding lives on one queue.
@MainActor
final class CaptureEngine {
    var onPreview: ((CGImage) -> Void)?
    var onPreviewPixelBuffer: ((CVPixelBuffer) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    /// Peak dBFS, with digital silence clamped to -120 dBFS.
    var onAudioDecibels: ((Float) -> Void)?
    /// The zero-based physical input currently being monitored/recorded.
    var onAudioChannel: ((Int) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Recoverable camera interruption; screen capture and the current take continue.
    var onCameraFailure: ((String) -> Void)?
    /// Native camera dimensions, delivered only when a current source changes.
    var onCameraSourceSize: ((CGSize) -> Void)?

    private var stream: SCStream?
    private var worker: CaptureWorker?
    private var generation = UUID()
    private var cameraIntent = UUID()
    private var cameraSourceSize: CGSize?
    private var isStarting = false

    func startPreview(configuration: CaptureConfiguration) async throws {
        guard stream == nil, !isStarting else { throw CaptureError.message("The camera is already running.") }
        isStarting = true
        defer { isStarting = false }
        let token = UUID()
        generation = token
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard generation == token else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == configuration.displayID }) else {
            throw CaptureError.message("The selected display is no longer connected. Choose another display.")
        }
        if let microphoneID = configuration.microphoneID {
            guard let device = AVCaptureDevice(uniqueID: microphoneID), device.isConnected else {
                throw CaptureError.message("The selected microphone is disconnected. Choose another microphone.")
            }
        }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        // Excluding the entire application also excludes panels created or moved after capture starts.
        guard !ownApplications.isEmpty else {
            throw CaptureError.message("vcam could not exclude its controls from capture. Keep its window open and try again.")
        }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let settings = SCStreamConfiguration()
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        settings.width = max(2, Int((filter.contentRect.width * scale).rounded()))
        settings.height = max(2, Int((filter.contentRect.height * scale).rounded()))
        settings.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
        settings.queueDepth = 5
        settings.pixelFormat = kCVPixelFormatType_32BGRA
        settings.colorSpaceName = CGColorSpace.sRGB
        settings.captureDynamicRange = .SDR
        settings.captureResolution = .best
        settings.showsCursor = configuration.showsCursor
        settings.capturesAudio = false
        settings.captureMicrophone = false // Physical inputs are captured by AVFoundation below.
        let newWorker = CaptureWorker(configuration: configuration)
        if onPreviewPixelBuffer != nil {
            newWorker.onPreviewPixelBuffer = { [weak self, weak newWorker] buffer in
                let frame = CapturePreviewFrame(buffer)
                Task { @MainActor [weak self, weak newWorker] in
                    defer { newWorker?.previewWasDelivered() }
                    guard let self, self.generation == token else { return }
                    self.onPreviewPixelBuffer?(frame.buffer)
                }
            }
        } else if onPreview != nil {
            newWorker.onPreview = { [weak self, weak newWorker] image in
                Task { @MainActor [weak self, weak newWorker] in
                    defer { newWorker?.previewWasDelivered() }
                    guard let self, self.generation == token else { return }
                    self.onPreview?(image)
                }
            }
        }
        newWorker.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onAudioLevel?(level)
            }
        }
        newWorker.onAudioDecibels = { [weak self] decibels in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onAudioDecibels?(decibels)
            }
        }
        newWorker.onAudioChannel = { [weak self] channel in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onAudioChannel?(channel)
            }
        }
        newWorker.onFailure = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onFailure?(message)
            }
        }
        newWorker.onCameraFailure = { [weak self] message, intent in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.cameraIntent == intent else { return }
                self.cameraIntent = UUID()
                self.onCameraFailure?(message)
            }
        }
        newWorker.onCameraSourceSize = { [weak self] size, intent in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.cameraIntent == intent,
                      self.cameraSourceSize != size else { return }
                self.cameraSourceSize = size
                self.onCameraSourceSize?(size)
            }
        }
        let newStream = SCStream(filter: filter, configuration: settings, delegate: newWorker)
        do {
            try newStream.addStreamOutput(newWorker, type: .screen, sampleHandlerQueue: newWorker.queue)
            await newWorker.prepare(stream: newStream)
            stream = newStream
            worker = newWorker
            try await newStream.startCapture()
            guard generation == token else {
                try? await newStream.stopCapture()
                await newWorker.shutdown()
                throw CancellationError()
            }
            await newWorker.beginRendering(clock: newStream.synchronizationClock)
            try await newWorker.startMicrophone()
            guard generation == token else { throw CancellationError() }
            cameraIntent = UUID()
            try await newWorker.setCamera(configuration.camera, intent: cameraIntent)
            guard generation == token else { throw CancellationError() }
        } catch {
            await newWorker.shutdown()
            try? await newStream.stopCapture()
            if generation == token {
                stream = nil
                worker = nil
            }
            throw error
        }
    }

    func updateCrop(_ frame: CGRect) { worker?.updateCrop(frame) }

    func updateCamera(_ configuration: CameraConfiguration) { worker?.updateCamera(configuration) }

    func setCamera(_ configuration: CameraConfiguration) async throws {
        guard let worker, stream != nil else { throw CaptureError.message("Open preview before changing the camera.") }
        cameraIntent = UUID()
        try await worker.setCamera(configuration, intent: cameraIntent)
    }

    func updateComposition(primaryFrame: CGRect, secondaryFrame: CGRect?, layout: CaptureLayout, splitRatio: Double,
                           camera: CameraConfiguration? = nil, tertiaryFrame: CGRect? = nil,
                           secondSplitRatio: Double = 2.0 / 3.0) {
        worker?.updateComposition(primaryFrame: primaryFrame, secondaryFrame: secondaryFrame,
                                  layout: layout, splitRatio: splitRatio, camera: camera,
                                  tertiaryFrame: tertiaryFrame, secondSplitRatio: secondSplitRatio)
    }

    func startRecording(to url: URL) async throws {
        guard let worker, stream != nil, !isStarting else {
            throw CaptureError.message("Open the camera before recording.")
        }
        try await worker.startRecording(to: url)
    }

    func stopRecording() async throws -> URL? { try await worker?.stopRecording() }

    func discardRecording() async throws { try await worker?.discardRecording() }

    func stopPreview() async {
        generation = UUID()
        cameraIntent = UUID()
        cameraSourceSize = nil
        let oldStream = stream
        let oldWorker = worker
        stream = nil
        worker = nil
        // Shutdown finalizes any recording before dropping the stream or its audio buffers.
        await oldWorker?.shutdown()
        try? await oldStream?.stopCapture()
    }
}

private enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

private final class CapturePreviewFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// Queue confinement includes the timer, writer, crop, frame cache, and stream callbacks.
final class CaptureWorker: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.codewithbeto.vcam.capture", qos: .userInitiated)
    var onPreview: (@Sendable (CGImage) -> Void)?
    var onPreviewPixelBuffer: (@Sendable (CVPixelBuffer) -> Void)?
    var onAudioLevel: (@Sendable (Float) -> Void)?
    var onAudioDecibels: (@Sendable (Float) -> Void)?
    var onAudioChannel: (@Sendable (Int) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    var onCameraFailure: (@Sendable (String, UUID) -> Void)?
    var onCameraSourceSize: (@Sendable (CGSize, UUID) -> Void)?

    private let configuration: CaptureConfiguration
    private let context = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,
        .workingColorSpace: CaptureColor.workingSpace,
        .outputColorSpace: CaptureColor.space,
        .workingFormat: CIFormat.RGBAh,
        .highQualityDownsample: true
    ])
    private let outputRect: CGRect
    private let previewRect: CGRect
    private var previewPool: CVPixelBufferPool?
    private var previewDeliveryPending = false
    private var microphoneCapture: CaptureMicrophone?
    private var cameraCapture: (any CameraCaptureSession)?
    private let cameraFactory: @Sendable () -> any CameraCaptureSession
    private var cameraGeneration = UUID()
    private var cameraIntent = UUID()
    private var cameraStarting = false
    private var cameraStartError: String?
    private var cameraConfiguration: CameraConfiguration
    private var latestCameraBuffer: CVPixelBuffer?
    private var cameraSourceSize: CGSize?
    private var lastCameraAt: CFTimeInterval?
    private var selectedMicrophoneChannel: Int?
    private var latchedMicrophoneChannel: Int?
    private var microphoneSampleRate: Double?
    private var microphonePeak: Float = 0
    private var composition: CaptureComposition
    private var cropFrame: CGRect {
        get { composition.primaryFrame }
        set { composition.primaryFrame = newValue }
    }
    private weak var expectedStream: SCStream?
    private var active = false
    private var timer: DispatchSourceTimer?
    private var captureClock: CMClock?
    private var latestBuffer: CVPixelBuffer?
    private var latestSourceTime: CMTime?
    private var latestSourceArrival: CMTime?
    private var nextPreviewTime: CFTimeInterval = 0
    private var lastLevelTime: CFTimeInterval = 0
    private var lastDisplayCheck: CFTimeInterval = 0
    private var startedAt: CFTimeInterval = 0
    private var lastMicrophoneAt: CFTimeInterval?
    private var microphoneFormat: CMFormatDescription?
    private var reportedFailure = false
    private var disconnectObserver: NSObjectProtocol?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var firstVideoTime: CMTime?
    private var lastVideoTime: CMTime?
    private var recordingStopTime: CMTime?
    private var lastAudioTime: CMTime?
    private var pendingAudio: [CMSampleBuffer] = []
    private var appendedVideoFrames = 0
    private var finishing = false
    private var recordingFailure: String?

    init(configuration: CaptureConfiguration, cameraFactory: @escaping @Sendable () -> any CameraCaptureSession = { CaptureCamera() }) {
        self.configuration = configuration
        self.cameraFactory = cameraFactory
        cameraConfiguration = configuration.camera
        cameraConfiguration.placement = .off // Publish enabled placement only after its first frame.
        cameraConfiguration.overlay = configuration.camera.overlay.clamped(in: configuration.outputSize)
        cameraConfiguration.framing = configuration.camera.framing.clamped()
        composition = CaptureComposition(layout: configuration.layout,
            splitRatio: CaptureLayout.clampedSplitRatio(configuration.splitRatio),
            primaryFrame: configuration.captureFrame, secondaryFrame: configuration.secondaryCaptureFrame,
            tertiaryFrame: configuration.tertiaryCaptureFrame, secondSplitRatio: configuration.secondSplitRatio)
        outputRect = CGRect(origin: .zero, size: configuration.outputSize)
        let previewScale = min(1, 960 / max(configuration.outputSize.width, configuration.outputSize.height))
        previewRect = CGRect(x: 0, y: 0,
            width: (configuration.outputSize.width * previewScale / 2).rounded() * 2,
            height: (configuration.outputSize.height * previewScale / 2).rounded() * 2)
        super.init()
    }

    func prepare(stream: SCStream) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.expectedStream = stream
                self.active = true
                self.startedAt = CACurrentMediaTime()
                if let microphoneID = self.configuration.microphoneID {
                    self.disconnectObserver = NotificationCenter.default.addObserver(
                        forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
                    ) { [weak worker = self] notification in
                        guard let device = notification.object as? AVCaptureDevice, device.uniqueID == microphoneID else { return }
                        worker?.queue.async { [weak worker] in
                            worker?.fail("The selected microphone was disconnected. The recording has been interrupted.")
                        }
                    }
                }
                continuation.resume()
            }
        }
    }

    func beginRendering(clock: CMClock?) async {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.active else { continuation.resume(); return }
                self.captureClock = clock
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / self.configuration.framesPerSecond), leeway: .milliseconds(1))
                timer.setEventHandler { [weak worker = self] in worker?.renderTick() }
                self.timer = timer
                timer.resume()
                continuation.resume()
            }
        }
    }

    func startMicrophone() async throws {
        guard let microphoneID = configuration.microphoneID else { return }
        let microphone = CaptureMicrophone()
        await withCheckedContinuation { continuation in
            queue.async {
                self.microphoneCapture = microphone
                self.lastMicrophoneAt = CACurrentMediaTime()
                continuation.resume()
            }
        }
        try await microphone.start(deviceID: microphoneID, delegate: self, sampleQueue: queue) { [weak self] message in
            self?.queue.async { [weak self] in self?.fail(message) }
        }
    }

    func startCamera() async throws {
        try await setCamera(configuration.camera)
    }

    func setCamera(_ requested: CameraConfiguration, intent: UUID = UUID()) async throws {
        guard requested.placement == .off || requested.deviceID?.isEmpty == false else {
            throw CaptureError.message("Choose a connected camera before enabling it.")
        }
        var normalized = requested
        normalized.overlay = requested.overlay.clamped(in: outputRect.size)
        normalized.framing = requested.framing.clamped()
        let target = normalized
        let token = UUID()
        let transition: (old: (any CameraCaptureSession)?, new: (any CameraCaptureSession)?) = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.active else { continuation.resume(throwing: CancellationError()); return }
                self.cameraIntent = intent
                if target.isEnabled, self.cameraCapture != nil, !self.cameraStarting,
                   self.cameraConfiguration.isEnabled, self.cameraConfiguration.deviceID == target.deviceID {
                    self.cameraConfiguration = target
                    if let size = self.cameraSourceSize { self.onCameraSourceSize?(size, intent) }
                    continuation.resume(returning: (nil, nil))
                    return
                }
                let old = self.cameraCapture
                self.cameraGeneration = token
                self.cameraCapture = nil
                self.cameraStarting = target.isEnabled
                self.cameraStartError = nil
                self.latestCameraBuffer = nil
                self.cameraSourceSize = nil
                self.lastCameraAt = nil
                self.cameraConfiguration = target
                self.cameraConfiguration.placement = .off
                let new = target.isEnabled ? self.cameraFactory() : nil
                self.cameraCapture = new
                continuation.resume(returning: (old, new))
            }
        }
        await transition.old?.stop()
        guard let camera = transition.new, let deviceID = target.deviceID else { return }
        do {
            try Task.checkCancellation()
            try await checkCameraTransition(token)
            try await camera.start(deviceID: deviceID, framesPerSecond: configuration.framesPerSecond,
                sampleQueue: queue, onFrame: { [weak self] buffer in
                    // CameraCaptureSession delivers directly on this queue. Keeping
                    // a single slot bounds latency and memory even during startup.
                    guard let self, self.active, self.cameraGeneration == token, self.cameraCapture != nil else { return }
                    self.latestCameraBuffer = buffer
                    self.lastCameraAt = CACurrentMediaTime()
                    let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                    if size.width > 0, size.height > 0, size != self.cameraSourceSize {
                        self.cameraSourceSize = size
                        self.onCameraSourceSize?(size, self.cameraIntent)
                    }
                }, onFailure: { [weak self] message in
                    self?.queue.async { [weak self] in self?.cameraFailed(message, token: token) }
                })
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while true {
                try Task.checkCancellation()
                let ready = try await checkCameraTransition(token, publish: target)
                if ready { return }
                guard ContinuousClock.now < deadline else {
                    throw CaptureError.message("The camera did not deliver a frame. Check Camera access and its connection; screen recording can continue.")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            await withCheckedContinuation { continuation in
                queue.async {
                    if self.cameraGeneration == token {
                        self.cameraGeneration = UUID()
                        self.cameraCapture = nil
                        self.latestCameraBuffer = nil
                        self.cameraSourceSize = nil
                        self.cameraStarting = false
                        self.cameraStartError = nil
                        self.cameraConfiguration.placement = .off
                    }
                    continuation.resume()
                }
            }
            await camera.stop()
            throw error
        }
    }

    @discardableResult
    private func checkCameraTransition(_ token: UUID, publish target: CameraConfiguration? = nil) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.active, self.cameraGeneration == token else {
                    continuation.resume(throwing: CancellationError()); return
                }
                if let message = self.cameraStartError {
                    continuation.resume(throwing: CaptureError.message(message)); return
                }
                let ready = self.latestCameraBuffer != nil
                if ready, let target {
                    self.cameraConfiguration = target
                    self.cameraStarting = false
                }
                continuation.resume(returning: ready)
            }
        }
    }

    private func cameraFailed(_ message: String, token: UUID) {
        guard active, cameraGeneration == token else { return }
        if cameraStarting { cameraStartError = message; return }
        guard let camera = cameraCapture else { return }
        cameraGeneration = UUID()
        cameraCapture = nil
        latestCameraBuffer = nil
        cameraSourceSize = nil
        cameraConfiguration.placement = .off
        onCameraFailure?(message, cameraIntent)
        Task { await camera.stop() }
    }

    func updateCamera(_ configuration: CameraConfiguration) {
        queue.async { self.applyCameraEdits(configuration) }
    }

    private func applyCameraEdits(_ configuration: CameraConfiguration) {
        // Cheap edits to an active camera. Starting/stopping hardware goes
        // through setCamera so Off actually releases the physical device.
        guard configuration.deviceID == cameraConfiguration.deviceID,
              configuration.isEnabled, cameraConfiguration.isEnabled, !cameraStarting else { return }
        cameraConfiguration = configuration
        cameraConfiguration.overlay = configuration.overlay.clamped(in: outputRect.size)
        cameraConfiguration.framing = configuration.framing.clamped()
    }

    func previewWasDelivered() {
        queue.async { self.previewDeliveryPending = false }
    }

    func updateCrop(_ frame: CGRect) {
        queue.async {
            guard frame.width > 0, frame.height > 0, frame.minX.isFinite, frame.minY.isFinite else { return }
            self.cropFrame = frame
        }
    }

    func updateComposition(primaryFrame: CGRect, secondaryFrame: CGRect?, layout: CaptureLayout, splitRatio: Double,
                           camera: CameraConfiguration? = nil, tertiaryFrame: CGRect? = nil,
                           secondSplitRatio: Double = 2.0 / 3.0) {
        queue.async {
            func valid(_ frame: CGRect) -> Bool {
                frame.width.isFinite && frame.height.isFinite && frame.minX.isFinite && frame.minY.isFinite &&
                    frame.width > 0 && frame.height > 0
            }
            guard valid(primaryFrame), secondaryFrame.map(valid) ?? true,
                  tertiaryFrame.map(valid) ?? true,
                  layout.regionCount < 2 || secondaryFrame != nil,
                  layout.regionCount < 3 || tertiaryFrame != nil else { return }
            // One serial-queue assignment keeps all source frames and their
            // destination geometry from being mixed across separate UI updates.
            self.composition = CaptureComposition(layout: layout,
                splitRatio: CaptureLayout.clampedSplitRatio(splitRatio),
                primaryFrame: primaryFrame, secondaryFrame: secondaryFrame,
                tertiaryFrame: tertiaryFrame, secondSplitRatio: secondSplitRatio)
            if let camera { self.applyCameraEdits(camera) }
        }
    }

    func startRecording(to url: URL) async throws {
        // The Record button may open preview and immediately request recording. Let
        // the first real screen/microphone buffers arrive without making the user retry.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            try Task.checkCancellation()
            let ready: Bool = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.active, !self.reportedFailure else {
                        continuation.resume(throwing: CaptureError.message("The camera stopped before recording could start."))
                        return
                    }
                    continuation.resume(returning: self.latestBuffer != nil &&
                        (self.configuration.microphoneID == nil || self.microphoneFormat != nil) &&
                        (!self.cameraConfiguration.isEnabled || self.latestCameraBuffer != nil))
                }
            }
            if ready { break }
            if ContinuousClock.now >= deadline {
                throw CaptureError.message("The screen, camera, or selected microphone did not become ready. Check access and device connections, then try again.")
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.active, !self.reportedFailure else { throw CaptureError.message("The camera has stopped. Open it again before recording.") }
                    guard self.writer == nil, !self.finishing else { throw CaptureError.message("A recording is still being saved.") }
                    guard self.latestBuffer != nil else { throw CaptureError.message("Waiting for the first screen frame. Try recording again in a moment.") }
                    guard !FileManager.default.fileExists(atPath: url.path) else { throw CaptureError.message("A file already exists at this location. Choose a new filename.") }
                    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: Int(self.outputRect.width),
                        AVVideoHeightKey: Int(self.outputRect.height),
                        AVVideoColorPropertiesKey: [
                            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                            // AVAssetWriter performs the sRGB → Rec.709 conversion
                            // from our tagged input buffers, including its transfer curve.
                            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                        ],
                        AVVideoCompressionPropertiesKey: [
                            AVVideoAverageBitRateKey: Int((self.configuration.framesPerSecond == 60 ? 24_000_000.0 : 16_000_000.0) * self.outputRect.width * self.outputRect.height / (1080 * 1920)),
                            AVVideoExpectedSourceFrameRateKey: self.configuration.framesPerSecond,
                            AVVideoMaxKeyFrameIntervalKey: self.configuration.framesPerSecond * 2,
                            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                            AVVideoAllowFrameReorderingKey: false
                        ]
                    ])
                    video.expectsMediaDataInRealTime = true
                    guard writer.canAdd(video) else { throw CaptureError.message("The video encoder is unavailable.") }
                    writer.add(video)
                    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: Int(self.outputRect.width),
                        kCVPixelBufferHeightKey as String: Int(self.outputRect.height),
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                        kCVPixelBufferMetalCompatibilityKey as String: true
                    ])
                    var audio: AVAssetWriterInput?
                    if self.configuration.microphoneID != nil {
                        guard let format = self.microphoneFormat,
                              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
                            throw CaptureError.message("The microphone is not delivering audio yet. Check access and try again.")
                        }
                        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                            AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: description.mSampleRate,
                            AVNumberOfChannelsKey: 1,
                            AVEncoderBitRateKey: 192_000
                        ], sourceFormatHint: format)
                        input.expectsMediaDataInRealTime = true
                        guard writer.canAdd(input) else { throw CaptureError.message("The microphone audio format cannot be recorded.") }
                        writer.add(input)
                        audio = input
                    }
                    guard writer.startWriting() else { throw writer.error ?? CaptureError.message("Could not create the recording file.") }
                    self.writer = writer
                    self.videoInput = video
                    self.audioInput = audio
                    self.adaptor = adaptor
                    self.recordingURL = url
                    self.firstVideoTime = nil
                    self.lastVideoTime = nil
                    self.recordingStopTime = nil
                    self.lastAudioTime = nil
                    self.pendingAudio = []
                    self.appendedVideoFrames = 0
                    self.recordingFailure = nil
                    self.latchedMicrophoneChannel = self.configuration.microphoneChannel
                    if self.latchedMicrophoneChannel == nil, self.microphonePeak >= 0.003 {
                        self.latchedMicrophoneChannel = self.selectedMicrophoneChannel
                    }
                    self.renderTick()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stopRecording() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.finishRecording(continuation: continuation) }
        }
    }

    func discardRecording() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.finishing else {
                    continuation.resume(throwing: CaptureError.message("This take is already being saved. Wait for it to finish before starting another take.")); return
                }
                guard let writer = self.writer else { continuation.resume(); return }
                guard writer.status != .completed else {
                    continuation.resume(throwing: CaptureError.message("A completed recording cannot be discarded as an unfinished take.")); return
                }
                let unfinishedURL = self.recordingURL
                self.writer = nil
                self.videoInput = nil
                self.audioInput = nil
                self.adaptor = nil
                self.recordingURL = nil
                self.firstVideoTime = nil
                self.lastVideoTime = nil
                self.recordingStopTime = nil
                self.lastAudioTime = nil
                self.pendingAudio.removeAll()
                self.appendedVideoFrames = 0
                self.recordingFailure = nil
                writer.cancelWriting()
                do {
                    // Only this worker's current unfinished URL is eligible. Saved
                    // takes have already been detached by finishRecording.
                    if let url = unfinishedURL, FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func shutdown() async {
        _ = try? await stopRecording()
        let devices: (CaptureMicrophone?, (any CameraCaptureSession)?) = await withCheckedContinuation { continuation in
            queue.async {
                let devices = (self.microphoneCapture, self.cameraCapture)
                self.active = false
                self.timer?.cancel()
                self.timer = nil
                self.microphoneCapture = nil
                self.cameraCapture = nil
                self.cameraGeneration = UUID()
                self.cameraStarting = false
                continuation.resume(returning: devices)
            }
        }
        await devices.0?.stop()
        await devices.1?.stop()
        await withCheckedContinuation { continuation in
            queue.async {
                self.active = false
                self.timer?.cancel()
                self.timer = nil
                self.latestBuffer = nil
                self.latestCameraBuffer = nil
                self.cameraSourceSize = nil
                self.previewPool = nil
                self.expectedStream = nil
                if let observer = self.disconnectObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.disconnectObserver = nil
                }
                continuation.resume()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard active, expectedStream === stream, CMSampleBufferIsValid(sampleBuffer) else { return }
        switch outputType {
        case .screen:
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let rawStatus = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: rawStatus) {
                switch status {
                case .complete, .started: break
                case .idle: return // A cached complete frame is enough to pan over a stationary desktop.
                case .blank, .suspended:
                    fail("Screen capture was interrupted. Wake or reconnect the display, then open the camera again.")
                    return
                case .stopped: return
                @unknown default: return
                }
            }
            guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard time.isValid, time.isNumeric else { return }
            latestBuffer = image
            latestSourceTime = time
            latestSourceArrival = CMClockGetTime(CMClockGetHostTimeClock())
        default: break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active, let microphone = microphoneCapture, output === microphone.output,
              CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              let sourceClock = microphone.synchronizationClock else { return }
        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let time: CMTime
        if let captureClock {
            time = CMSyncConvertTime(sourceTime, from: sourceClock, to: captureClock)
        } else {
            guard let sourceScreenTime = latestSourceTime, let sourceScreenArrival = latestSourceArrival else { return }
            let hostTime = CMSyncConvertTime(sourceTime, from: sourceClock, to: CMClockGetHostTimeClock())
            time = CMTimeAdd(sourceScreenTime, CMTimeSubtract(hostTime, sourceScreenArrival))
        }
        guard time.isValid, time.isNumeric else { return }
        processMicrophone(sampleBuffer, at: time)
    }

    private func processMicrophone(_ sample: CMSampleBuffer, at time: CMTime) {
        do {
            let decoded = try CapturePCM.decode(sample)
            lastMicrophoneAt = CACurrentMediaTime()
            let channel: Int
            if let requested = configuration.microphoneChannel ?? (writer != nil ? latchedMicrophoneChannel : nil) {
                guard decoded.channels.indices.contains(requested) else {
                    fail("Microphone input \(requested + 1) is unavailable on the selected device.")
                    return
                }
                channel = requested
            } else {
                // On interfaces such as Scarlett Solo, channels 3/4 are loopback.
                // Auto considers the first two physical inputs and latches after
                // signal appears during recording, avoiding channel switching.
                let candidates = Array(decoded.peaks.prefix(2))
                channel = candidates.indices.max(by: { candidates[$0] < candidates[$1] }) ?? 0
                if writer != nil, decoded.peaks[channel] >= 0.003 { latchedMicrophoneChannel = channel }
            }
            if selectedMicrophoneChannel != channel {
                selectedMicrophoneChannel = channel
                onAudioChannel?(channel)
            }
            microphonePeak = decoded.peaks[channel]
            let now = CACurrentMediaTime()
            if now - lastLevelTime >= 0.08 {
                lastLevelTime = now
                onAudioLevel?(microphonePeak)
                onAudioDecibels?(20 * log10(max(microphonePeak, 0.000_001)))
            }
            if microphoneFormat == nil || microphoneSampleRate != decoded.sampleRate {
                guard writer == nil else { fail("The microphone sample rate changed during recording. Stop and reselect the device."); return }
                microphoneFormat = try CapturePCM.monoFormat(sampleRate: decoded.sampleRate)
                microphoneSampleRate = decoded.sampleRate
            }
            if writer != nil, let format = microphoneFormat {
                appendAudio(try CapturePCM.monoSample(decoded, channel: channel, format: format, at: time))
            }
        } catch { fail(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, self.active, self.expectedStream === stream else { return }
            self.fail("Screen capture stopped: \(error.localizedDescription)")
        }
    }

    private func captureTime() -> CMTime? {
        // Use the stream's clock so video and unmodified microphone PTS share one timebase.
        if let captureClock { return CMClockGetTime(captureClock) }
        // Some streams expose no clock. Anchor elapsed host time to a real screen PTS,
        // rather than assuming its epoch is the same as the machine's host clock.
        guard let sourceTime = latestSourceTime, let arrivalTime = latestSourceArrival else { return nil }
        return CMTimeAdd(sourceTime, CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), arrivalTime))
    }

    private func croppedImage(from buffer: CVPixelBuffer) -> CIImage {
        // All regions sample the same cached display frame. Moving a region or
        // the split never reconfigures capture, timestamps, or the output file.
        let source = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: CaptureColor.space])
        let state = composition
        let destinations = state.layout.destinationRects(in: outputRect.size, splitRatio: state.splitRatio,
                                                        secondSplitRatio: state.secondSplitRatio)
        var result = CIImage(color: .black).cropped(to: outputRect)
        result = regionImage(source, frame: state.primaryFrame, destination: destinations[0]).composited(over: result)
        if destinations.count > 1, let secondary = state.secondaryFrame {
            result = regionImage(source, frame: secondary, destination: destinations[1]).composited(over: result)
        }
        if destinations.count > 2, let tertiary = state.tertiaryFrame {
            result = regionImage(source, frame: tertiary, destination: destinations[2]).composited(over: result)
        }
        if cameraConfiguration.isEnabled, let buffer = latestCameraBuffer {
            // Camera sources may be Rec.709 YCbCr or tagged RGB. Let Core Image
            // read those attachments, then convert through the linear working
            // space into the same sRGB output as the screen; never relabel them.
            var camera = CIImage(cvPixelBuffer: buffer)
            if cameraConfiguration.mirrored {
                camera = camera.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                    tx: camera.extent.minX + camera.extent.maxX, ty: 0))
            }
            switch cameraConfiguration.placement {
            case .off: break
            case .regionA:
                result = framedCameraImage(camera, destination: destinations[0]).composited(over: result)
            case .regionB:
                if destinations.count > 1 {
                    result = framedCameraImage(camera, destination: destinations[1]).composited(over: result)
                }
            case .regionC:
                if destinations.count > 2 {
                    result = framedCameraImage(camera, destination: destinations[2]).composited(over: result)
                }
            case .overlay:
                let overlay = cameraConfiguration.overlay
                let rect = overlay.rect(in: outputRect.size)
                let image = framedCameraImage(camera, destination: rect)
                let radius = overlay.shape == .circle ? rect.width / 2 : rect.height * 0.14
                let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                    "inputExtent": CIVector(cgRect: rect), "inputRadius": radius, "inputColor": CIColor.white
                ])!.outputImage!
                result = image.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask
                ])
            }
        }
        return result.cropped(to: outputRect)
    }

    private func regionImage(_ source: CIImage, frame: CGRect, destination: CGRect) -> CIImage {
        let crop = CaptureGeometry.sourcePixelCrop(frame,
            displayFrame: configuration.displayFrame, pixelSize: source.extent.size)
        return fittedImage(source, crop: crop, destination: destination)
    }

    private func framedCameraImage(_ source: CIImage, destination: CGRect) -> CIImage {
        let crop = cameraConfiguration.framing.sourceRect(in: source.extent.size, filling: destination.size)
            .offsetBy(dx: source.extent.minX, dy: source.extent.minY)
        return fittedImage(source, crop: crop, destination: destination)
    }

    private func fittedImage(_ source: CIImage, crop requestedCrop: CGRect, destination: CGRect) -> CIImage {
        var crop = requestedCrop
        let destinationAspect = destination.width / destination.height
        let sourceAspect = crop.width / crop.height
        // UI frames follow their destination aspect. If an update or restored
        // frame differs, center-crop before a uniform scale instead of stretching.
        if abs(sourceAspect - destinationAspect) > 0.000_001 {
            let original = crop
            if sourceAspect > destinationAspect {
                crop.size.width = crop.height * destinationAspect
            } else {
                crop.size.height = crop.width / destinationAspect
            }
            let maximumX = max(original.minX, floor(original.maxX - crop.width))
            let maximumY = max(original.minY, floor(original.maxY - crop.height))
            crop.origin.x = min(max((original.midX - crop.width / 2).rounded(), original.minX), maximumX)
            crop.origin.y = min(max((original.midY - crop.height / 2).rounded(), original.minY), maximumY)
        }
        let scale = destination.width / crop.width
        return source.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: destination.minX, y: destination.minY))
            .cropped(to: destination)
    }

    private func renderTick() {
        guard active else { return }
        let now = CACurrentMediaTime()
        if now - lastDisplayCheck >= 1 {
            lastDisplayCheck = now
            if CGDisplayIsOnline(configuration.displayID) == 0 {
                fail("The selected display was disconnected. Choose another display to continue.")
            }
        }
        if now - startedAt > 6 {
            if latestBuffer == nil { fail("No screen frames arrived. Check Screen Recording access and reopen the camera.") }
            if configuration.microphoneID != nil, now - (lastMicrophoneAt ?? startedAt) > 6 {
                fail("The selected microphone stopped delivering audio. Check its connection and microphone access.")
            }
            if cameraConfiguration.isEnabled, now - (lastCameraAt ?? startedAt) > 6 {
                cameraFailed("The selected camera stopped delivering video. Screen recording can continue; reconnect or reselect the camera.", token: cameraGeneration)
            }
        }
        drainAudio()
        guard let buffer = latestBuffer else { return }
        autoreleasepool {
            let shouldPreview = !previewDeliveryPending && (onPreviewPixelBuffer != nil || onPreview != nil) && now + 0.002 >= nextPreviewTime
            let shouldWrite = writer != nil && !finishing && recordingFailure == nil
            guard shouldPreview || shouldWrite else { return }
            let image = croppedImage(from: buffer)
            if shouldPreview {
                let interval = 1.0 / 30.0
                nextPreviewTime = nextPreviewTime < now - interval ? now + interval : nextPreviewTime + interval
                emitPreview(image)
            }
            if shouldWrite, let time = captureTime() { appendVideo(image, at: time) }
        }
    }

    private func emitPreview(_ image: CIImage) {
        let small = image.transformed(by: CGAffineTransform(scaleX: previewRect.width / outputRect.width, y: previewRect.height / outputRect.height))
        if let onPreviewPixelBuffer {
            if previewPool == nil {
                let attributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(previewRect.width),
                    kCVPixelBufferHeightKey as String: Int(previewRect.height),
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
                CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                    attributes as CFDictionary, &previewPool)
            }
            guard let pool = previewPool else { return }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &buffer) == kCVReturnSuccess,
                let buffer else { return }
            context.render(small, to: buffer, bounds: previewRect, colorSpace: CaptureColor.space)
            CaptureColor.tag(buffer)
            previewDeliveryPending = true
            onPreviewPixelBuffer(buffer)
        } else if let onPreview, let preview = context.createCGImage(small, from: previewRect, format: .RGBA8, colorSpace: CaptureColor.space) {
            previewDeliveryPending = true
            onPreview(preview)
        }
    }

    private func appendVideo(_ image: CIImage, at time: CMTime) {
        guard let writer, let videoInput, let adaptor, time.isValid, time.isNumeric else { return }
        if writer.status == .failed { fail(writer.error?.localizedDescription ?? "The video encoder failed."); return }
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        if let lastVideoTime, CMTimeCompare(time, lastVideoTime) <= 0 { return }
        if firstVideoTime == nil {
            writer.startSession(atSourceTime: time)
            firstVideoTime = time
        }
        guard let pool = adaptor.pixelBufferPool else { fail("The video encoder could not allocate its image buffers."); return }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { fail("There is not enough memory for the recording frame."); return }
        context.render(image, to: buffer, bounds: outputRect, colorSpace: CaptureColor.space)
        CaptureColor.tag(buffer)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            fail(writer.error?.localizedDescription ?? "A video frame could not be encoded.")
            return
        }
        lastVideoTime = time
        appendedVideoFrames += 1
    }

    private func appendAudio(_ sample: CMSampleBuffer) {
        guard let writer, writer.status == .writing, audioInput != nil,
              let firstVideoTime, recordingFailure == nil, !finishing else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        // Start on the first video frame. Drop microphone packets captured before that
        // boundary; retain original timestamps for the remainder to preserve A/V sync.
        let previousTime = pendingAudio.last.map { CMSampleBufferGetPresentationTimeStamp($0) } ?? lastAudioTime
        guard time.isValid, time.isNumeric, CMTimeCompare(time, firstVideoTime) >= 0,
              previousTime.map({ CMTimeCompare(time, $0) > 0 }) ?? true else { return }
        // Video may skip a frame under backpressure while keeping its timeline. Audio
        // packets need a short queue: dropping PCM can shorten the AAC timeline.
        guard pendingAudio.count < 200 else {
            fail("The audio encoder could not keep up. Close other demanding apps and try again.")
            return
        }
        pendingAudio.append(sample)
        drainAudio()
    }

    private func drainAudio() {
        guard let writer, writer.status == .writing, let audioInput else { return }
        while !pendingAudio.isEmpty, audioInput.isReadyForMoreMediaData {
            let sample = pendingAudio.removeFirst()
            guard audioInput.append(sample) else {
                pendingAudio.removeAll()
                fail(writer.error?.localizedDescription ?? "Microphone audio could not be encoded.")
                return
            }
            lastAudioTime = CMSampleBufferGetPresentationTimeStamp(sample)
        }
    }

    private func fail(_ message: String) {
        guard active, !reportedFailure else { return }
        reportedFailure = true
        if writer != nil { recordingFailure = message }
        onFailure?(message)
    }

    private func finishRecording(continuation: CheckedContinuation<URL?, Error>, audioDrainDeadline: CFTimeInterval? = nil) {
        if audioDrainDeadline == nil {
            guard !finishing else { continuation.resume(throwing: CaptureError.message("The recording is already being saved.")); return }
        }
        guard let writer else { continuation.resume(returning: nil); return }
        if audioDrainDeadline == nil {
            recordingStopTime = captureTime()
            // A final frame extends a still desktop up to the actual stop time.
            if recordingFailure == nil, let buffer = latestBuffer, let time = recordingStopTime {
                appendVideo(croppedImage(from: buffer), at: time)
            }
            finishing = true
        }
        drainAudio()
        let deadline = audioDrainDeadline ?? CACurrentMediaTime() + 2
        if !pendingAudio.isEmpty, writer.status == .writing, CACurrentMediaTime() < deadline {
            queue.asyncAfter(deadline: .now() + 0.01) {
                self.finishRecording(continuation: continuation, audioDrainDeadline: deadline)
            }
            return
        }
        if !pendingAudio.isEmpty {
            fail("The microphone encoder could not finish all queued audio. The recording may end early.")
        }
        pendingAudio.removeAll()
        let url = recordingURL
        let priorFailure = recordingFailure
        let hasFrames = appendedVideoFrames > 0
        if writer.status == .writing {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
        }
        if let end = recordingStopTime, let firstVideoTime, CMTimeCompare(end, firstVideoTime) > 0, writer.status == .writing {
            writer.endSession(atSourceTime: end)
        }
        self.writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        recordingURL = nil
        if !hasFrames || writer.status != .writing {
            writer.cancelWriting()
            if let url { try? FileManager.default.removeItem(at: url) }
            finishing = false
            continuation.resume(throwing: writer.error ?? CaptureError.message(priorFailure ?? "No video frames were recorded. Open the camera and try again."))
            return
        }
        writer.finishWriting { [self] in
            queue.async {
                self.finishing = false
                if writer.status == .completed, let url {
                    // A stream interruption can still yield a valid partial recording.
                    // The live failure callback reports that interruption to the UI.
                    continuation.resume(returning: url)
                } else {
                    if let url { try? FileManager.default.removeItem(at: url) }
                    continuation.resume(throwing: writer.error ?? CaptureError.message("The recording could not be saved."))
                }
            }
        }
    }
}

#if VCAM_CAPTURE_VALIDATION
private final class SyntheticAudioState: @unchecked Sendable {
    var sampleCount = 0 // Accessed on the synthetic worker's serial queue only.
    var peakMeter: Float = 0
    var peakDecibels: Float = -120
    var previewFrames = 0
}
private final class SyntheticFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer // Filled before crossing into the serial worker queue.
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}
/// A device-free provider exercises the real camera activation/teardown path.
/// It deliberately emits a late frame/error after stop to check session gating.
private final class SyntheticCameraSession: CameraCaptureSession, @unchecked Sendable {
    let frame: SyntheticFrame?
    let failsOnStart: Bool
    private let lock = NSLock()
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var lateDelivery: (@Sendable () -> Void)?
    init(frame: SyntheticFrame?, failsOnStart: Bool = false) { self.frame = frame; self.failsOnStart = failsOnStart }
    func start(deviceID: String, framesPerSecond: Int, sampleQueue: DispatchQueue,
               onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) async throws {
        try await Task.sleep(for: .milliseconds(40))
        if failsOnStart || deviceID == "synthetic-failing" { throw CaptureError.message("Synthetic camera could not start.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sampleQueue.async {
                self.lock.lock()
                defer { self.lock.unlock() }
                guard !self.stopped else { continuation.resume(throwing: CancellationError()); return }
                let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
                timer.schedule(deadline: .now() + 0.04, repeating: .milliseconds(33))
                timer.setEventHandler { if let frame = self.frame, deviceID != "synthetic-no-frames" { onFrame(frame.buffer) } }
                self.timer = timer
                self.lateDelivery = {
                    sampleQueue.asyncAfter(deadline: .now() + 0.03) {
                        if let frame = self.frame { onFrame(frame.buffer) }
                        onFailure("Late callback from a stopped synthetic camera.")
                    }
                }
                timer.resume()
                continuation.resume()
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            stopped = true
            timer?.cancel(); timer = nil
            let late = lateDelivery; lateDelivery = nil
            lock.unlock()
            late?()
            continuation.resume()
        }
    }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
private final class SyntheticCameraHolder: @unchecked Sendable {
    var latest: SyntheticCameraSession? // Factory and reads run on the worker queue.
}
private final class SyntheticLifecycleState: @unchecked Sendable {
    var audioSamples = 0
    var recoverableErrors = 0
    var cameraSizes: [CGSize] = []
    var fatalError: String?
}
// Compiled only by scripts/validate-capture.swift. Synthetic inputs exercise the
// exact production crop, timer tick, encoder, microphone metering and finish path.
extension CaptureWorker {
    static func validateRecordingLifecycle(in directory: URL) async throws -> URL {
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 960)
        var config = CaptureConfiguration(displayID: CGMainDisplayID(), displayFrame: bounds, captureFrame: bounds,
            framesPerSecond: 30, microphoneID: "synthetic-microphone", showsCursor: false)
        config.outputSize = bounds.size
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 640, 960, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &created) == kCVReturnSuccess,
              let buffer = created else { throw CaptureError.message("Cannot allocate lifecycle fixture.") }
        CIContext().render(CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.3)).cropped(to: bounds),
                           to: buffer, bounds: bounds, colorSpace: CaptureColor.space)
        let frame = SyntheticFrame(buffer)
        let state = SyntheticLifecycleState()
        let worker = CaptureWorker(configuration: config, cameraFactory: { SyntheticCameraSession(frame: frame) })
        let audioTimer = DispatchSource.makeTimerSource(queue: worker.queue)
        let audioOrigin = CMClockGetTime(CMClockGetHostTimeClock())
        await withCheckedContinuation { continuation in
            worker.queue.async {
                worker.active = true
                worker.startedAt = CACurrentMediaTime()
                worker.captureClock = CMClockGetHostTimeClock()
                worker.latestBuffer = frame.buffer
                worker.onFailure = { state.fatalError = $0 }
                worker.onCameraFailure = { _, _ in state.recoverableErrors += 1 }
                worker.onCameraSourceSize = { size, _ in state.cameraSizes.append(size) }
                audioTimer.schedule(deadline: .now(), repeating: .milliseconds(10))
                audioTimer.setEventHandler {
                    let elapsed = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), audioOrigin).seconds
                    let count = max(1, Int(elapsed * 48_000) - state.audioSamples)
                    let time = CMTimeAdd(audioOrigin, CMTime(value: Int64(state.audioSamples), timescale: 48_000))
                    if let sample = try? syntheticMicrophoneSample(count: count, offset: state.audioSamples, at: time, competingInput: false) {
                        worker.processMicrophone(sample, at: time)
                        state.audioSamples += count
                    }
                }
                audioTimer.resume()
                continuation.resume()
            }
        }
        let discarded = directory.appendingPathComponent("discarded.mp4")
        let saved = directory.appendingPathComponent("saved-restart.mp4")
        let laterDiscard = directory.appendingPathComponent("later-discard.mp4")
        let protected = directory.appendingPathComponent("unrelated.txt")
        let sentinel = Data("Keep this unrelated file.".utf8)
        try sentinel.write(to: protected)
        do {
            await worker.beginRendering(clock: CMClockGetHostTimeClock())
            try await worker.startRecording(to: discarded)
            let originalWriter: ObjectIdentifier = await withCheckedContinuation { continuation in
                worker.queue.async { continuation.resume(returning: ObjectIdentifier(worker.writer!)) }
            }
            var on = CameraConfiguration(deviceID: "synthetic-camera", placement: .overlay)
            for device: String? in ["synthetic-failing", "synthetic-no-frames", nil, ""] {
                var failing = on; failing.deviceID = device
                var rejected = false
                do { try await worker.setCamera(failing) } catch { rejected = true }
                guard rejected else { throw CaptureError.message("A failing camera unexpectedly activated.") }
                try await worker.requireSyntheticState({ $0.writer.map(ObjectIdentifier.init) == originalWriter && !$0.cameraConfiguration.isEnabled && state.fatalError == nil },
                    "Camera activation failure damaged the ongoing screen take.")
            }
            let pending = Task { try await worker.setCamera(on) }
            try await Task.sleep(for: .milliseconds(15))
            var off = on; off.placement = .off
            try await worker.setCamera(off)
            switch await pending.result {
            case .success: throw CaptureError.message("Turning Off during camera startup did not cancel activation.")
            case .failure: break
            }
            try await worker.setCamera(on)
            try await worker.setCamera(off)
            try await worker.setCamera(on)
            try await Task.sleep(for: .milliseconds(100))
            try await worker.requireSyntheticState({ $0.writer.map(ObjectIdentifier.init) == originalWriter && $0.cameraConfiguration.isEnabled && state.recoverableErrors == 0 && state.fatalError == nil },
                "A stopped camera's late callback affected its replacement or the writer.")
            try await worker.requireSyntheticState({ _ in state.cameraSizes == [bounds.size, bounds.size] },
                "Camera size must publish once per new source, ignoring repeated frames and late callbacks from stopped cameras.")
            await withCheckedContinuation { continuation in
                worker.queue.async {
                    worker.cameraFailed("Synthetic active camera disconnected.", token: worker.cameraGeneration)
                    continuation.resume()
                }
            }
            try await Task.sleep(for: .milliseconds(60))
            try await worker.requireSyntheticState({ $0.writer.map(ObjectIdentifier.init) == originalWriter && !$0.cameraConfiguration.isEnabled && state.recoverableErrors == 1 && state.fatalError == nil },
                "An active camera interruption must recover to screen-only without cancelling the take.")
            try await worker.requireSyntheticState({ _ in state.cameraSizes.count == 2 },
                "A disconnected camera's late frame republished stale dimensions.")
            on.placement = .regionA
            try await worker.setCamera(on)
            try await worker.discardRecording()
            guard !FileManager.default.fileExists(atPath: discarded.path) else { throw CaptureError.message("Discard left its unfinished file on disk.") }
            try await worker.requireSyntheticState({ $0.active && $0.timer != nil && $0.latestBuffer != nil && $0.microphoneFormat != nil && $0.cameraConfiguration.isEnabled && $0.writer == nil },
                "Discard stopped preview or its selected inputs.")
            try await worker.startRecording(to: saved)
            try await Task.sleep(for: .milliseconds(750))
            guard try await worker.stopRecording() == saved else { throw CaptureError.message("Restarted take did not save.") }
            let savedBytes = try Data(contentsOf: saved)
            try await worker.discardRecording() // No current writer: must not touch the saved take.
            try await worker.startRecording(to: laterDiscard)
            try await Task.sleep(for: .milliseconds(200))
            try await worker.discardRecording()
            guard !FileManager.default.fileExists(atPath: laterDiscard.path), try Data(contentsOf: saved) == savedBytes,
                  try Data(contentsOf: protected) == sentinel else { throw CaptureError.message("Discard altered a completed or unrelated file.") }
            try await worker.requireSyntheticState({ state.fatalError == nil && $0.active }, "Lifecycle exercise stopped screen capture.")
            audioTimer.cancel()
            await worker.shutdown()
            return saved
        } catch {
            audioTimer.cancel()
            await worker.shutdown()
            throw error
        }
    }

    private func requireSyntheticState(_ predicate: @escaping @Sendable (CaptureWorker) -> Bool, _ message: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if predicate(self) { continuation.resume() }
                else { continuation.resume(throwing: CaptureError.message(message)) }
            }
        }
    }

    /// Injects known, color-tagged pixels through the production preview and encoder.
    static func recordColorFixture(_ buffer: CVPixelBuffer, to url: URL, outputSize: CGSize,
                                   onPreview: @escaping @Sendable (CVPixelBuffer) -> Void) async throws -> URL {
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        var config = CaptureConfiguration(displayID: CGMainDisplayID(), displayFrame: bounds,
            captureFrame: bounds, framesPerSecond: 30, microphoneID: nil, showsCursor: false)
        config.outputSize = outputSize
        let worker = CaptureWorker(configuration: config)
        let frame = SyntheticFrame(buffer)
        await withCheckedContinuation { continuation in
            worker.queue.async {
                worker.onPreviewPixelBuffer = { [weak receiver = worker] buffer in
                    onPreview(buffer)
                    receiver?.previewWasDelivered()
                }
                worker.active = true
                worker.startedAt = CACurrentMediaTime()
                worker.captureClock = CMClockGetHostTimeClock()
                worker.latestBuffer = frame.buffer
                continuation.resume()
            }
        }
        do {
            await worker.beginRendering(clock: CMClockGetHostTimeClock())
            try await worker.startRecording(to: url)
            try await Task.sleep(for: .milliseconds(600))
            guard let result = try await worker.stopRecording() else {
                throw CaptureError.message("The color fixture did not produce a recording.")
            }
            await worker.shutdown()
            return result
        } catch {
            await worker.shutdown()
            throw error
        }
    }

    /// Records several composition states against one unchanged source buffer.
    /// Returned times are phase midpoints on the encoded movie's timeline.
    static func recordCompositionFixture(_ buffer: CVPixelBuffer, displayFrame: CGRect,
                                         phases: [CaptureComposition], to url: URL,
                                         outputSize: CGSize, cameraBuffer: CVPixelBuffer? = nil,
                                         cameras: [CameraConfiguration] = []) async throws -> (url: URL, sampleTimes: [Double]) {
        guard let initial = phases.first else { throw CaptureError.message("The composition fixture needs an initial phase.") }
        var config = CaptureConfiguration(displayID: CGMainDisplayID(), displayFrame: displayFrame,
            captureFrame: initial.primaryFrame, framesPerSecond: 30,
            microphoneID: "synthetic-microphone", showsCursor: false)
        config.outputSize = outputSize
        config.secondaryCaptureFrame = initial.secondaryFrame
        config.tertiaryCaptureFrame = initial.tertiaryFrame
        config.layout = initial.layout
        config.splitRatio = initial.splitRatio
        config.secondSplitRatio = initial.secondSplitRatio
        config.camera = cameras.first ?? CameraConfiguration()
        let frame = SyntheticFrame(buffer)
        let camera = cameraBuffer.map(SyntheticFrame.init)
        let cameraHolder = SyntheticCameraHolder()
        let worker = CaptureWorker(configuration: config, cameraFactory: {
            let provider = SyntheticCameraSession(frame: camera)
            cameraHolder.latest = provider
            return provider
        })
        let audio = SyntheticAudioState()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.queue.async {
                worker.active = true
                worker.startedAt = CACurrentMediaTime()
                worker.captureClock = CMClockGetHostTimeClock()
                worker.latestBuffer = frame.buffer
                do {
                    let time = CMClockGetTime(CMClockGetHostTimeClock())
                    worker.processMicrophone(try syntheticMicrophoneSample(count: 512, offset: 0,
                        at: time, competingInput: false), at: time)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        do {
            try await worker.startCamera()
            await worker.beginRendering(clock: CMClockGetHostTimeClock())
            try await worker.startRecording(to: url)
            let originalWriter: ObjectIdentifier = await withCheckedContinuation { continuation in
                worker.queue.async { continuation.resume(returning: ObjectIdentifier(worker.writer!)) }
            }
            var times: [Double] = []
            for (index, phase) in phases.enumerated() {
                worker.updateComposition(primaryFrame: phase.primaryFrame, secondaryFrame: phase.secondaryFrame,
                    layout: phase.layout, splitRatio: phase.splitRatio,
                    camera: cameras.indices.contains(index) ? cameras[index] : nil,
                    tertiaryFrame: phase.tertiaryFrame, secondSplitRatio: phase.secondSplitRatio)
                if cameras.indices.contains(index) {
                    let previous = index > 0 ? cameras[index - 1] : config.camera
                    if previous.isEnabled, cameras[index].isEnabled, previous.deviceID == cameras[index].deviceID {
                        // Exercise the same inexpensive live edit path used by
                        // zoom, panning, mirroring, and placement controls.
                        worker.updateCamera(cameras[index])
                    } else {
                        try await worker.setCamera(cameras[index])
                    }
                    if !cameras[index].isEnabled {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            worker.queue.async {
                                guard worker.cameraCapture == nil, worker.latestCameraBuffer == nil,
                                      cameraHolder.latest?.isStopped ?? true else {
                                    continuation.resume(throwing: CaptureError.message("Camera Off did not release its provider and latest frame.")); return
                                }
                                continuation.resume()
                            }
                        }
                    }
                }
                try await worker.requireSyntheticState({ $0.writer.map(ObjectIdentifier.init) == originalWriter },
                    "A live layout or camera framing edit replaced the ongoing writer.")
                let phaseStart: Double = await withCheckedContinuation { continuation in
                    worker.queue.async {
                        continuation.resume(returning: CMTimeSubtract(worker.captureTime()!, worker.firstVideoTime!).seconds)
                    }
                }
                for _ in 0..<12 {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        worker.queue.async {
                            let first = worker.firstVideoTime!
                            let elapsed = CMTimeSubtract(worker.captureTime()!, first).seconds
                            let count = max(1, Int(elapsed * 48_000) - audio.sampleCount)
                            do {
                                let time = CMTimeAdd(first, CMTime(value: Int64(audio.sampleCount), timescale: 48_000))
                                let sample = try syntheticMicrophoneSample(count: count, offset: audio.sampleCount,
                                    at: time, competingInput: false)
                                audio.sampleCount += count
                                worker.processMicrophone(sample, at: time)
                                continuation.resume()
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                    try await Task.sleep(for: .milliseconds(33))
                }
                let phaseEnd: Double = await withCheckedContinuation { continuation in
                    worker.queue.async {
                        continuation.resume(returning: CMTimeSubtract(worker.captureTime()!, worker.firstVideoTime!).seconds)
                    }
                }
                times.append((phaseStart + phaseEnd) / 2)
            }
            guard let result = try await worker.stopRecording() else {
                throw CaptureError.message("The composition fixture did not save a recording.")
            }
            await worker.shutdown()
            return (result, times)
        } catch {
            await worker.shutdown()
            throw error
        }
    }

    static func recordSynthetic(to url: URL, framesPerSecond: Int = 30,
                                outputSize: CGSize = CGSize(width: 1080, height: 1920)) async throws -> URL {
        let bounds = CGRect(x: -800, y: -100, width: 400, height: 300)
        let aspectRatio = outputSize.width / outputSize.height
        let height = min(bounds.height, (bounds.width / 2) / aspectRatio)
        let width = height * aspectRatio
        var config = CaptureConfiguration(displayID: CGMainDisplayID(), displayFrame: bounds,
            captureFrame: CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: width, height: height),
            framesPerSecond: framesPerSecond, microphoneID: "synthetic-microphone", showsCursor: false)
        config.outputSize = outputSize
        let worker = CaptureWorker(configuration: config)
        var created: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 800, 600, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &created)
        guard result == kCVReturnSuccess, let buffer = created else { throw CaptureError.message("Synthetic buffer allocation failed.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<600 {
            for x in 0..<800 {
                let offset = y * rowBytes + x * 4
                let rgb: (UInt8, UInt8, UInt8)
                switch (x < 400, y < 300) {
                case (true, true): rgb = (255, 0, 0)
                case (true, false): rgb = (0, 255, 0)
                case (false, true): rgb = (0, 0, 255)
                case (false, false): rgb = (255, 255, 0)
                }
                bytes[offset] = rgb.2; bytes[offset + 1] = rgb.1
                bytes[offset + 2] = rgb.0; bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let syntheticFrame = SyntheticFrame(buffer)
        let audioState = SyntheticAudioState()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.queue.async {
                worker.onAudioLevel = { audioState.peakMeter = max(audioState.peakMeter, $0) }
                worker.onAudioDecibels = { audioState.peakDecibels = max(audioState.peakDecibels, $0) }
                worker.onPreviewPixelBuffer = { [weak receiver = worker] buffer in
                    if CVPixelBufferGetIOSurface(buffer) != nil { audioState.previewFrames += 1 }
                    receiver?.previewWasDelivered()
                }
                worker.active = true
                worker.startedAt = CACurrentMediaTime()
                worker.captureClock = CMClockGetHostTimeClock()
                worker.latestBuffer = syntheticFrame.buffer
                do {
                    let time = CMClockGetTime(CMClockGetHostTimeClock())
                    let sample = try syntheticMicrophoneSample(count: 512, offset: 0, at: time, competingInput: false)
                    worker.processMicrophone(sample, at: time)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        // Exercise the production DispatchSourceTimer at the requested rate. The
        // control/audio loop below intentionally runs independently at about 30 Hz.
        await worker.beginRendering(clock: CMClockGetHostTimeClock())
        try await worker.startRecording(to: url)
        for tick in 0..<60 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                worker.queue.async {
                    if tick == 30 {
                        worker.cropFrame.origin.x = bounds.maxX - width
                    }
                    // The full-display buffer never changes: the production timer
                    // must render the moved crop even on a completely idle desktop.
                    let firstTime = worker.firstVideoTime!
                    let elapsed = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), firstTime).seconds
                    let count = max(1, Int(elapsed * 48_000) - audioState.sampleCount)
                    do {
                        let time = CMTimeAdd(firstTime, CMTime(value: Int64(audioState.sampleCount), timescale: 48_000))
                        let sample = try syntheticMicrophoneSample(count: count, offset: audioState.sampleCount, at: time, competingInput: tick >= 30)
                        audioState.sampleCount += count
                        worker.processMicrophone(sample, at: time)
                    } catch { continuation.resume(throwing: error); return }
                    continuation.resume()
                }
            }
            try await Task.sleep(for: .milliseconds(33))
        }
        guard let output = try await worker.stopRecording() else { throw CaptureError.message("Synthetic recording did not return a file.") }
        let meter: Float = await withCheckedContinuation { continuation in
            worker.queue.async { continuation.resume(returning: audioState.peakMeter) }
        }
        guard meter > 0.19 && meter < 0.21, audioState.peakDecibels > -14.1 && audioState.peakDecibels < -13.9 else {
            throw CaptureError.message("The 24-bit input-2 peak meter or dBFS calculation is incorrect.")
        }
        guard audioState.previewFrames >= 30 else { throw CaptureError.message("The GPU preview did not deliver IOSurface-backed frames.") }
        print("GPU preview delivered \(audioState.previewFrames) IOSurface frames; microphone peak \(audioState.peakDecibels) dBFS from native 4-channel/24-bit input 2.")
        await worker.shutdown()
        return output
    }
    private static func syntheticMicrophoneSample(count: Int, offset: Int, at time: CMTime, competingInput: Bool) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
            mBytesPerPacket: 16, mFramesPerPacket: 1, mBytesPerFrame: 16,
            mChannelsPerFrame: 4, mBitsPerChannel: 24, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
            throw CaptureError.message("Synthetic 24-bit PCM format creation failed.")
        }
        var samples = [Int32](repeating: 0, count: count * 4)
        for frame in 0..<count {
            let t = Double(offset + frame) / 48_000
            let values = [competingInput ? sin(2 * .pi * 220 * t) * 0.8 : 0,
                          sin(2 * .pi * 440 * t) * 0.2,
                          sin(2 * .pi * 880 * t) * 0.9,
                          sin(2 * .pi * 1_760 * t) * 0.9]
            for channel in 0..<4 { samples[frame * 4 + channel] = Int32(values[channel] * 8_388_607) << 8 }
        }
        let size = samples.count * MemoryLayout<Int32>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: size, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block) == noErr, let block else {
            throw CaptureError.message("Synthetic PCM buffer failed.")
        }
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr, let sample else { throw CaptureError.message("Synthetic PCM sample failed.") }
        return sample
    }

}
#endif
