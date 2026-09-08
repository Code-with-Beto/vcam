// Synthetic screen, native-format camera pixels, and microphone PCM only.
// DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swiftc \
// -D VCAM_CAPTURE_VALIDATION -swift-version 5 -target arm64-apple-macos15.0 \
// vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
// vcam/CaptureCamera.swift vcam/CaptureEngine.swift scripts/validate-camera.swift \
// -o /tmp/vcam-validate-camera
// /tmp/vcam-validate-camera
import AVFoundation
import CoreImage
import VideoToolbox

@main
struct ValidateCamera {
    static let size = CGSize(width: 1440, height: 2560)
    static let display = CGRect(x: -400, y: -100, width: 400, height: 300)
    static let primary = CGRect(x: -400, y: -100, width: 200, height: 300)
    static let secondary = CGRect(x: -200, y: -100, width: 200, height: 300)
    static let screenColors = [[35, 170, 65], [35, 75, 210]]
    static let cameraLuma = [64, 112, 160, 208]

    static func main() async throws {
        try validateGeometry()
        let screen = try makeScreen()
        let camera = try makeCamera()
        let reference = try nativeCameraReference(camera)
        var states: [(CaptureLayout, CameraConfiguration)] = []
        var configuration = CameraConfiguration(deviceID: "synthetic-camera", placement: .overlay,
            overlay: CameraOverlayConfiguration(center: CGPoint(x: 0.25, y: 0.25), widthFraction: 0.30, shape: .circle), mirrored: false)
        states.append((.single, configuration))
        configuration.overlay.center = CGPoint(x: 0.75, y: 0.75)
        states.append((.single, configuration))
        configuration.overlay.widthFraction = 0.55
        states.append((.single, configuration))
        configuration.mirrored = true
        states.append((.single, configuration))
        configuration.overlay.shape = .roundedRectangle
        states.append((.single, configuration))
        states.append((.stacked, configuration))
        configuration.placement = .regionA
        states.append((.stacked, configuration))
        configuration.placement = .regionB
        states.append((.stacked, configuration))
        configuration.placement = .off
        states.append((.single, configuration))
        configuration.placement = .regionA
        states.append((.stacked, configuration))
        configuration.placement = .off
        states.append((.stacked, configuration))
        configuration.placement = .overlay
        states.append((.single, configuration))
        configuration.placement = .off
        states.append((.single, configuration))
        // All framing changes occur during this same take. The asymmetric crop
        // positions expose zoom, pan direction, mirror order, and edge clamping.
        configuration.placement = .overlay
        configuration.framing = CameraFramingConfiguration(zoom: 1.8, center: CGPoint(x: 0.65, y: 0.4))
        states.append((.single, configuration))
        configuration.mirrored = false
        states.append((.single, configuration))
        configuration.overlay.shape = .circle
        configuration.framing = CameraFramingConfiguration(zoom: 4, center: CGPoint(x: 0, y: 1))
        states.append((.single, configuration))
        configuration.placement = .regionA
        configuration.framing = CameraFramingConfiguration(zoom: 3, center: CGPoint(x: 1, y: 0))
        states.append((.stacked, configuration))
        configuration.placement = .regionB
        configuration.framing = CameraFramingConfiguration(zoom: 2, center: CGPoint(x: 0.1, y: 0.8))
        states.append((.stacked, configuration))
        configuration.mirrored = true
        states.append((.stacked, configuration))
        configuration.framing = CameraFramingConfiguration()
        states.append((.stacked, configuration))
        let compositions = states.map { CaptureComposition(layout: $0.0, primaryFrame: primary, secondaryFrame: secondary) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vcam-camera-validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await CaptureWorker.recordCompositionFixture(screen, displayFrame: display,
            phases: compositions, to: directory.appendingPathComponent("camera.mp4"), outputSize: size,
            cameraBuffer: camera, cameras: states.map(\.1))
        let asset = AVURLAsset(url: result.url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try check(video.count == 1 && audio.count == 1, "Camera composition must retain one movie and one independently selected microphone track")
        try check(try await video[0].load(.naturalSize) == size, "Camera changed output dimensions")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        var images: [Pixels] = []
        for (index, time) in result.sampleTimes.enumerated() {
            let image = try Pixels(try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image)
            images.append(image)
            let state = states[index]
            let cells = state.0.destinationRects(in: size, splitRatio: 0.5)
            let cameraRect: CGRect?
            switch state.1.placement {
            case .overlay: cameraRect = state.1.overlay.rect(in: size)
            case .regionA: cameraRect = cells[0]
            case .regionB: cameraRect = cells[1]
            case .off: cameraRect = nil
            }
            if let rect = cameraRect {
                // Quarter points stay in the circle/rounded mask and on opposite
                // sides of both camera axes, exposing upside-down or double-flipped images.
                for top in [false, true] {
                    for left in [false, true] {
                        let point = CGPoint(x: rect.minX + rect.width * (left ? 0.30 : 0.70),
                            y: rect.minY + rect.height * (top ? 0.70 : 0.30))
                        try expect(image.pixel(point), cameraColor(at: point, in: rect, configuration: state.1, reference: reference),
                                   "Phase \(index) camera framing/orientation/color")
                    }
                }
                if state.1.placement == .overlay {
                    let corner = CGPoint(x: rect.minX + 2, y: rect.minY + 2)
                    try expect(image.pixel(corner), screenColor(at: corner, cells: cells), "Phase \(index) masked corner must show screen")
                    let topEdge = CGPoint(x: rect.midX, y: rect.maxY - 6)
                    // Avoid the camera's exact quadrant seam for this edge assertion.
                    let edgePoint = CGPoint(x: topEdge.x + rect.width * 0.03, y: rect.maxY - rect.height * 0.08)
                    try expect(image.pixel(edgePoint), cameraColor(at: edgePoint, in: rect, configuration: state.1, reference: reference),
                               "Phase \(index) mask must include the face area")
                } else {
                    // Samples just inside all four region corners must stay
                    // covered, including when a zoomed crop reaches source edges.
                    for x in [0.01, 0.99] { for y in [0.01, 0.99] {
                        let point = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
                        try expect(image.pixel(point), cameraColor(at: point, in: rect, configuration: state.1, reference: reference),
                                   "Phase \(index) cropped region must never expose black edges")
                    } }
                }
            }
            for (cellIndex, cell) in cells.enumerated() {
                let replaced = (cellIndex == 0 && state.1.placement == .regionA) || (cellIndex == 1 && state.1.placement == .regionB)
                if !replaced {
                    let point = CGPoint(x: cell.minX + cell.width * 0.1, y: cell.minY + cell.height * 0.1)
                    if cameraRect?.contains(point) != true {
                        try expect(image.pixel(point), screenColors[cellIndex], "Phase \(index) unchanged screen region")
                    }
                }
            }
        }
        let originalCenter = states[0].1.overlay.rect(in: size).center
        try expect(images[1].pixel(originalCenter), screenColors[0], "Moving overlay must reveal the previous screen pixels")
        let smallRect = states[1].1.overlay.rect(in: size)
        let enlargedRect = states[2].1.overlay.rect(in: size)
        let expansionPoint = CGPoint(x: enlargedRect.midX - enlargedRect.width * 0.40, y: enlargedRect.midY)
        try check(!smallRect.contains(expansionPoint), "Resize fixture point must be outside the old overlay")
        try expect(images[1].pixel(expansionPoint), screenColors[0], "Before resize, newly covered pixels must show screen")
        try check(images[2].pixel(expansionPoint).max()! - images[2].pixel(expansionPoint).min()! < 8,
                  "Resizing overlay must cover the newly included screen pixels with the grayscale camera")
        try await validateAudioAndTiming(asset, video: video[0], audio: audio[0])
        print("PASS: 1440×2560 camera circle/rounded mask, move/resize, live zoom/pan/reset, post-mirror crop direction, no exposed crop edges, Rec.709 NV12 color conversion, live Off/On, single/stacked layouts and A/B replacement on one monotonic writer timeline, released camera providers, and independent mono AAC.")
        print("Synthetic camera recording: \(result.url.path)")
    }

    static func validateGeometry() throws {
        for size in [CGSize(width: 1440, height: 2560), CGSize(width: 2560, height: 1440)] {
            for shape in CameraShape.allCases {
                for center in [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: -10, y: 10)] {
                    let overlay = CameraOverlayConfiguration(center: center, widthFraction: 2, shape: shape)
                    let clamped = overlay.clamped(in: size)
                    let rect = overlay.rect(in: size)
                    try check(CGRect(origin: .zero, size: size).insetBy(dx: -0.001, dy: -0.001).contains(rect), "Overlay must stay inside the output")
                    try check(clamped.widthFraction == 0.65 && abs(rect.width - min(size.width, size.height) * 0.65) < 0.001,
                              "Overlay size must clamp against the canvas short edge")
                    try check(abs(clamped.clamped(in: size).center.x - clamped.center.x) < 0.001, "Normalization must be stable")
                }
            }
        }
        let top = CameraOverlayConfiguration(center: CGPoint(x: 0.5, y: 0.1)).rect(in: size)
        try check(top.midY > size.height / 2, "Top-left UI coordinates must become bottom-left image coordinates")
    }

    static func makeScreen() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, 800, 600, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, "Cannot create screen fixture")
        CVPixelBufferLockBaseAddress(buffer!, [])
        let data = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer!)
        for y in 0..<600 { for x in 0..<800 {
            let rgb = screenColors[x < 400 ? 0 : 1], offset = y * stride + x * 4
            data[offset] = UInt8(rgb[2]); data[offset + 1] = UInt8(rgb[1]); data[offset + 2] = UInt8(rgb[0]); data[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        return buffer!
    }

    static func makeCamera() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, "Cannot create camera fixture")
        let pixel = buffer!
        CVPixelBufferLockBaseAddress(pixel, [])
        let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
        let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<480 { for x in 0..<640 {
            yPlane[y * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + x] = UInt8(cameraLuma[(y < 240 ? 0 : 2) + (x < 320 ? 0 : 1)])
        } }
        memset(uvPlane, 128, CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) * 240)
        CVPixelBufferUnlockBaseAddress(pixel, [])
        CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return pixel
    }

    static func nativeCameraReference(_ camera: CVPixelBuffer) throws -> [Int: Int] {
        // VideoToolbox converts the native camera buffer independently of Core
        // Image. Core Graphics then converts its tagged CGImage to display sRGB.
        var image: CGImage?
        try check(VTCreateCGImageFromCVPixelBuffer(camera, options: nil, imageOut: &image) == noErr,
                  "Cannot create the independent native-camera color reference")
        let pixels = try Pixels(image!)
        let values = [pixels.pixel(CGPoint(x: 160, y: 360))[0], pixels.pixel(CGPoint(x: 480, y: 360))[0],
                      pixels.pixel(CGPoint(x: 160, y: 120))[0], pixels.pixel(CGPoint(x: 480, y: 120))[0]]
        print("Native camera Y samples \(cameraLuma) → sRGB reference \(values)")
        return Dictionary(uniqueKeysWithValues: zip(cameraLuma, values))
    }

    static func screenColor(at point: CGPoint, cells: [CGRect]) -> [Int] {
        screenColors[cells.firstIndex(where: { $0.contains(point) }) ?? 0]
    }

    static func cameraColor(at point: CGPoint, in destination: CGRect, configuration: CameraConfiguration,
                            reference: [Int: Int]) -> [Int] {
        let source = CGSize(width: 640, height: 480)
        let crop = configuration.framing.sourceRect(in: source, filling: destination.size)
        var x = crop.minX + (point.x - destination.minX) / destination.width * crop.width
        let y = crop.minY + (point.y - destination.minY) / destination.height * crop.height
        if configuration.mirrored { x = source.width - x }
        let patch = (y >= source.height / 2 ? 0 : 2) + (x < source.width / 2 ? 0 : 1)
        let gray = reference[cameraLuma[patch]]!
        return [gray, gray, gray]
    }

    static func validateAudioAndTiming(_ asset: AVAsset, video: AVAssetTrack, audio: AVAssetTrack) async throws {
        let videoDescription = try await video.load(.formatDescriptions)[0]
        try check(CMFormatDescriptionGetMediaSubType(videoDescription) == kCMVideoCodecType_H264, "Camera output must remain H.264")
        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        videoReader.add(videoOutput)
        try check(videoReader.startReading(), "Cannot inspect camera movie timing")
        var frameTimes: [Double] = []
        while let sample = videoOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { frameTimes.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        }
        try check(videoReader.status == .completed && frameTimes.count > 100, "Camera movie is incomplete")
        try check(zip(frameTimes, frameTimes.dropFirst()).allSatisfy { $1 > $0 },
                  "Live camera/layout changes must preserve strictly increasing presentation timestamps")
        let frameRate = Double(frameTimes.count - 1) / (frameTimes.last! - frameTimes.first!)
        try check(frameRate > 27 && frameRate < 33, "Camera compositor missed its 30 fps cadence: \(frameRate)")
        let audioDescription = try await audio.load(.formatDescriptions)[0]
        try check(CMFormatDescriptionGetMediaSubType(audioDescription) == kAudioFormatMPEG4AAC &&
            CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)?.pointee.mChannelsPerFrame == 1, "Camera must not replace or add to the selected mono microphone")
        let videoRange = try await video.load(.timeRange), audioRange = try await audio.load(.timeRange)
        try check(abs(audioRange.end.seconds - videoRange.end.seconds) < 0.2, "Camera composition changed microphone timing")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); try check(reader.startReading(), "Cannot decode microphone audio")
        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            peak = max(peak, samples.map { abs($0) }.max() ?? 0)
        }
        try check(reader.status == .completed && peak > 0.1 && peak < 0.3, "Independent selected microphone input did not survive camera composition")
        print(String(format: "Camera movie %.2f s; %.2f fps; mono AAC peak %.3f; A/V end difference %.1f ms",
            videoRange.duration.seconds, frameRate, peak, (audioRange.end.seconds - videoRange.end.seconds) * 1000))
    }

    struct Pixels {
        let width: Int, height: Int, bytes: [UInt8]
        init(_ image: CGImage) throws {
            width = image.width; height = image.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            bytes = data
        }
        func pixel(_ point: CGPoint) -> [Int] {
            let x = min(max(Int(point.x), 0), width - 1), y = min(max(height - 1 - Int(point.y), 0), height - 1)
            return (0..<3).map { Int(bytes[(y * width + x) * 4 + $0]) }
        }
    }
    static func expect(_ actual: [Int], _ expected: [Int], _ label: String) throws {
        try check(zip(actual, expected).allSatisfy { abs($0 - $1) <= 5 }, "\(label): got \(actual), expected \(expected)")
    }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "vcam.camera-validation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}

private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }
