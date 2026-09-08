// Run from the project root:
// DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swiftc \
//   -D VCAM_CAPTURE_VALIDATION -swift-version 5 -target arm64-apple-macos15.0 \
//   vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
//   vcam/CaptureCamera.swift vcam/CaptureEngine.swift scripts/validate-capture.swift \
//   -o /tmp/vcam-validate-capture && /tmp/vcam-validate-capture 60
// Arguments: fps (30 or 60), short edge (1080 or 1440), orientation (portrait or landscape).
// Defaults: 30 1080 portrait. Example: /tmp/vcam-validate-capture 30 1440 landscape
// Uses generated pixels and PCM audio only. No screen or microphone access.
import AVFoundation
import Foundation
import CoreImage

@main
struct ValidateCapture {
    static func main() async throws {
        let requestedRate = Int(CommandLine.arguments.dropFirst().first ?? "30")
        try check(requestedRate == 30 || requestedRate == 60, "Choose 30 or 60 frames per second")
        let framesPerSecond = requestedRate!
        let shortEdge = Int(CommandLine.arguments.dropFirst(2).first ?? "1080")
        let orientation = CommandLine.arguments.dropFirst(3).first ?? "portrait"
        try check(shortEdge == 1080 || shortEdge == 1440, "Choose 1080 or 1440 for the output short edge")
        try check(orientation == "portrait" || orientation == "landscape", "Choose portrait or landscape")
        let portrait = CGSize(width: shortEdge!, height: shortEdge! * 16 / 9)
        let expectedSize = orientation == "portrait" ? portrait : CGSize(width: portrait.height, height: portrait.width)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vcam-capture-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try await CaptureWorker.recordSynthetic(to: directory.appendingPathComponent("synthetic.mp4"), framesPerSecond: framesPerSecond, outputSize: expectedSize)
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try check(videoTracks.count == 1 && audioTracks.count == 1, "Expected one video and one microphone track")
        let video = videoTracks[0], audio = audioTracks[0]
        let size = try await video.load(.naturalSize)
        try check(size == expectedSize, "Output was \(size), expected \(expectedSize)")
        let videoFormat = try await video.load(.formatDescriptions)[0]
        let audioFormat = try await audio.load(.formatDescriptions)[0]
        try check(CMFormatDescriptionGetMediaSubType(videoFormat) == kCMVideoCodecType_H264, "Expected H.264")
        try check(CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC, "Expected AAC")
        try check(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee.mChannelsPerFrame == 1,
                  "The selected physical microphone input must be encoded as mono")
        let duration = try await asset.load(.duration).seconds
        try check(duration > 1.9 && duration < 6, "Unexpected recording duration: \(duration)")
        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        videoReader.add(videoOutput)
        try check(videoReader.startReading(), "Cannot inspect generated video frames")
        var frameCount = 0
        var firstPTS: Double?
        var lastPTS: Double?
        var largestGap: Double = 0
        while let sample = videoOutput.copyNextSampleBuffer() {
            // AVAssetReader also emits empty timing/segment markers. They are
            // not encoded video frames and must not inflate the measured rate.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if let lastPTS { largestGap = max(largestGap, time - lastPTS) }
            if firstPTS == nil { firstPTS = time }
            lastPTS = time
            frameCount += 1
        }
        try check(videoReader.status == .completed && frameCount > 1, "Cannot read completed video timeline")
        let measuredRate = Double(frameCount - 1) / max((lastPTS ?? 0) - (firstPTS ?? 0), 0.001)
        print(String(format: "Timer requested: %d fps; achieved: %.2f fps; frames: %d; duration: %.3f s; largest gap: %.1f ms",
                     framesPerSecond, measuredRate, frameCount, duration, largestGap * 1_000))
        try check(measuredRate >= Double(framesPerSecond) * 0.85 && measuredRate <= Double(framesPerSecond) * 1.15,
                  "The actual render timer did not sustain the requested frame rate")
        let videoRange = try await video.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        try check(abs(videoRange.start.seconds - audioRange.start.seconds) < 0.15, "Audio/video start times are misaligned")
        try check(abs(videoRange.end.seconds - audioRange.end.seconds) < 0.25, "Audio/video end times are misaligned")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let early = try await generator.image(at: CMTime(seconds: duration * 0.2, preferredTimescale: 600)).image
        let late = try await generator.image(at: CMTime(seconds: duration * 0.8, preferredTimescale: 600)).image
        // CGImage bitmap rows have their top at y=0. These four assertions catch
        // upside-down capture, Retina scaling, negative display origins, and frozen crops.
        try expectPixel(early, yFraction: 0.2, color: [255, 0, 0], label: "Early top")
        try expectPixel(early, yFraction: 0.8, color: [0, 255, 0], label: "Early bottom")
        try expectPixel(late, yFraction: 0.2, color: [0, 0, 255], label: "Moved top")
        try expectPixel(late, yFraction: 0.8, color: [255, 255, 0], label: "Moved bottom")
        // Read decoded PCM to verify AAC contains real signal rather than an empty track.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        try check(reader.startReading(), "Cannot decode generated microphone track")
        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            peak = max(peak, floats.map { abs($0) }.max() ?? 0)
        }
        try check(reader.status == .completed && peak > 0.1 && peak < 0.3,
                  "Selected input 2 is missing, or louder loopback/competing inputs leaked into mono AAC")
        print("PASS: \(Int(size.width))×\(Int(size.height)) H.264 + AAC, synchronized tracks, correct orientation, Retina/negative-origin crop, live pan on static source, production render timer, native 4-channel/24-bit PCM decoded to latched input-2 mono AAC.")
        print("Synthetic recording: \(url.path)")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "vcam.capture-validation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func expectPixel(_ image: CGImage, yFraction: Double, color: [Int], label: String) throws {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let index = (Int(Double(height) * yFraction) * width + width / 2) * 4
        let actual = (0..<3).map { Int(pixels[index + $0]) }
        try check(zip(actual, color).allSatisfy { abs($0 - $1) <= 30 }, "\(label) was \(actual), expected \(color)")
    }
}
