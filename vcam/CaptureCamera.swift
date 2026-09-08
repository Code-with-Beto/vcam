@preconcurrency import AVFoundation
import CoreMedia

protocol CameraCaptureSession: AnyObject, Sendable {
    func start(deviceID: String, framesPerSecond: Int, sampleQueue: DispatchQueue,
               onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) async throws
    func stop() async
}

/// One video-only camera session. Its blocking configuration/start/stop operations
/// never run on the main actor or on the compositor's sample queue.
final class CaptureCamera: NSObject, CameraCaptureSession, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let output = AVCaptureVideoDataOutput()
    private let controlQueue = DispatchQueue(label: "dev.codewithbeto.vcam.camera", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private let handlerLock = NSLock()
    private var frameHandler: (@Sendable (CVPixelBuffer) -> Void)?
    private var stopped = false // Confined to the control queue; sessions are single-use.

    func start(deviceID: String, framesPerSecond: Int, sampleQueue: DispatchQueue,
               onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) async throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw Self.error("Enable Camera access for vcam in System Settings, then try again.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async { [self] in
                do {
                    guard !stopped else { throw CancellationError() }
                    guard let device = AVCaptureDevice(uniqueID: deviceID), device.isConnected,
                          device.hasMediaType(.video) else {
                        throw Self.error("The selected camera is no longer connected. Choose another camera.")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    session.beginConfiguration()
                    do {
                        guard session.canAddInput(input) else { throw Self.error("The selected camera cannot be opened.") }
                        session.addInput(input)
                        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                        else if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                        guard session.canAddOutput(output) else { throw Self.error("The camera video output could not be configured.") }
                        session.addOutput(output)
                        let formats = output.availableVideoPixelFormatTypes
                        let format = formats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
                        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
                        // The delegate writes one latest-frame slot on the compositor
                        // queue. AVFoundation discards queued late camera frames.
                        output.alwaysDiscardsLateVideoFrames = true
                        handlerLock.lock(); frameHandler = onFrame; handlerLock.unlock()
                        output.setSampleBufferDelegate(self, queue: sampleQueue)
                        if let connection = output.connection(with: .video) {
                            if connection.isVideoMirroringSupported {
                                connection.automaticallyAdjustsVideoMirroring = false
                                connection.isVideoMirrored = false // Mirrored once by the compositor.
                            }
                            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                            rotationCoordinator = coordinator
                            applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture, to: connection)
                            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, change in
                                guard let angle = change.newValue else { return }
                                self?.controlQueue.async { [weak self] in self?.applyRotation(angle, to: connection) }
                            }
                        }
                        session.commitConfiguration()
                    } catch {
                        session.commitConfiguration()
                        throw error
                    }
                    let rate = Double(min(framesPerSecond, 30))
                    if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= rate && $0.maxFrameRate >= rate }) {
                        try device.lockForConfiguration()
                        if device.activeFormat.isAutoVideoFrameRateSupported { device.isAutoVideoFrameRateEnabled = false }
                        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(rate))
                        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(rate))
                        device.unlockForConfiguration()
                    }
                    observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                        object: session, queue: nil) { note in
                        let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                        onFailure("Camera capture stopped: \(error?.localizedDescription ?? "The camera reported an error.")")
                    })
                    observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                        object: session, queue: nil) { _ in
                        onFailure("Camera capture was interrupted. Reconnect or reselect the camera.")
                    })
                    observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.didStopRunningNotification,
                        object: session, queue: nil) { _ in
                        onFailure("The selected camera stopped. Reconnect or reselect the camera.")
                    })
                    observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                        object: device, queue: nil) { _ in
                        onFailure("The selected camera was disconnected. Screen recording can continue without it.")
                    })
                    session.startRunning()
                    guard session.isRunning else { throw Self.error("The camera did not start. Check its connection and Camera access for vcam.") }
                    continuation.resume()
                } catch {
                    cleanup()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            controlQueue.async { [self] in stopped = true; cleanup(); continuation.resume() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        handlerLock.lock(); let handler = frameHandler; handlerLock.unlock()
        handler?(buffer) // Already on the compositor's serial queue; never enqueue every frame again.
    }

    private func applyRotation(_ angle: CGFloat, to connection: AVCaptureConnection) {
        // AVFoundation physically rotates delivered buffers. The compositor uses
        // those dimensions directly for both preview and export, with no second rotation.
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }

    private func cleanup() {
        handlerLock.lock(); frameHandler = nil; handlerLock.unlock()
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "vcam.camera", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
