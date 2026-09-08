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

    private var stream: SCStream?
    private var worker: CaptureWorker?
    private var generation = UUID()
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

    func startRecording(to url: URL) async throws {
        guard let worker, stream != nil, !isStarting else {
            throw CaptureError.message("Open the camera before recording.")
        }
        try await worker.startRecording(to: url)
    }

    func stopRecording() async throws -> URL? { try await worker?.stopRecording() }

    func stopPreview() async {
        generation = UUID()
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
    private var selectedMicrophoneChannel: Int?
    private var latchedMicrophoneChannel: Int?
    private var microphoneSampleRate: Double?
    private var microphonePeak: Float = 0
    private var cropFrame: CGRect
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

    init(configuration: CaptureConfiguration) {
        self.configuration = configuration
        cropFrame = configuration.captureFrame
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

    func previewWasDelivered() {
        queue.async { self.previewDeliveryPending = false }
    }

    func updateCrop(_ frame: CGRect) {
        queue.async {
            guard frame.width > 0, frame.height > 0, frame.minX.isFinite, frame.minY.isFinite else { return }
            self.cropFrame = frame
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
                        (self.configuration.microphoneID == nil || self.microphoneFormat != nil))
                }
            }
            if ready { break }
            if ContinuousClock.now >= deadline {
                throw CaptureError.message("The screen or selected microphone did not become ready. Check access and the microphone connection, then try again.")
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

    func shutdown() async {
        _ = try? await stopRecording()
        let microphone: CaptureMicrophone? = await withCheckedContinuation { continuation in
            queue.async {
                let microphone = self.microphoneCapture
                self.microphoneCapture = nil
                continuation.resume(returning: microphone)
            }
        }
        await microphone?.stop()
        await withCheckedContinuation { continuation in
            queue.async {
                self.active = false
                self.timer?.cancel()
                self.timer = nil
                self.latestBuffer = nil
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
        // SCStreamConfiguration requests sRGB. State that contract explicitly
        // instead of relying on Core Image's fallback for untagged RGB buffers.
        let source = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: CaptureColor.space])
        // Both AppKit's global frame and Core Image use a bottom-left origin. Remove
        // the selected display's global origin, then convert points to captured pixels.
        // No Quartz top-left conversion is needed because we capture the full display.
        let crop = CaptureGeometry.sourcePixelCrop(cropFrame,
            displayFrame: configuration.displayFrame, pixelSize: source.extent.size)
        let positioned = source.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: outputRect.width / crop.width, y: outputRect.height / crop.height))
        return positioned.composited(over: CIImage(color: .black).cropped(to: outputRect)).cropped(to: outputRect)
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
// Compiled only by scripts/validate-capture.swift. Synthetic inputs exercise the
// exact production crop, timer tick, encoder, microphone metering and finish path.
extension CaptureWorker {
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
