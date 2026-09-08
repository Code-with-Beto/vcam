@preconcurrency import AVFoundation
import CoreMedia

/// A dedicated AVFoundation input preserves physical interface channels. In
/// particular Scarlett interfaces can expose two analog inputs plus loopback.
final class CaptureMicrophone: @unchecked Sendable {
    let session = AVCaptureSession()
    let output = AVCaptureAudioDataOutput()
    private let controlQueue = DispatchQueue(label: "dev.codewithbeto.vcam.microphone", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    var synchronizationClock: CMClock? { session.synchronizationClock }

    func start(deviceID: String, delegate: AVCaptureAudioDataOutputSampleBufferDelegate,
               sampleQueue: DispatchQueue, onFailure: @escaping @Sendable (String) -> Void) async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NSError(domain: "vcam.microphone", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Enable Microphone access for vcam in System Settings, then try again."])
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async { [self] in
                do {
                    guard let device = AVCaptureDevice(uniqueID: deviceID), device.isConnected else {
                        throw NSError(domain: "vcam.microphone", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "The selected microphone is no longer connected."])
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    session.beginConfiguration()
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        throw NSError(domain: "vcam.microphone", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "The selected microphone cannot be opened. Check whether another application has exclusive access."])
                    }
                    session.addInput(input)
                    // Normalize sample storage, while retaining all physical channels
                    // for explicit selection. The PCM decoder also handles native 24-bit
                    // data if a device does not honor the requested representation.
                    let channels = max(1, Int(CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee.mChannelsPerFrame ?? 1))
                    output.audioSettings = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: channels,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsNonInterleaved: false,
                        AVLinearPCMIsBigEndianKey: false
                    ]
                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw NSError(domain: "vcam.microphone", code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "The microphone audio output could not be configured."])
                    }
                    session.addOutput(output)
                    output.setSampleBufferDelegate(delegate, queue: sampleQueue)
                    session.commitConfiguration()
                    observers.append(NotificationCenter.default.addObserver(
                        forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
                    ) { note in
                        let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                        onFailure("Microphone capture stopped: \(error?.localizedDescription ?? "The audio device reported an error.")")
                    })
                    observers.append(NotificationCenter.default.addObserver(
                        forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
                    ) { _ in onFailure("Microphone capture was interrupted. Reconnect or reselect the audio interface.") })
                    session.startRunning()
                    guard session.isRunning else {
                        throw NSError(domain: "vcam.microphone", code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "The microphone did not start. Check its connection and Microphone access for vcam."])
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            controlQueue.async { [self] in
                output.setSampleBufferDelegate(nil, queue: nil)
                if session.isRunning { session.stopRunning() }
                for observer in observers { NotificationCenter.default.removeObserver(observer) }
                observers = []
                continuation.resume()
            }
        }
    }
}
