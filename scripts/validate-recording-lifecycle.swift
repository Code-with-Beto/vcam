// Generated screen/camera pixels and PCM only. Does not open any physical input.
// DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swiftc \
// -D VCAM_CAPTURE_VALIDATION -swift-version 5 -target arm64-apple-macos15.0 \
// vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
// vcam/CaptureCamera.swift vcam/CaptureEngine.swift scripts/validate-recording-lifecycle.swift \
// -o /tmp/vcam-validate-recording-lifecycle
// /tmp/vcam-validate-recording-lifecycle
import AVFoundation
import Foundation

@main
struct ValidateRecordingLifecycle {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vcam-lifecycle-validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try await CaptureWorker.validateRecordingLifecycle(in: directory)
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        try check(videos.count == 1 && audios.count == 1, "Restarted take must retain one video and one microphone track")
        let video = videos[0], audio = audios[0]
        try check(try await video.load(.naturalSize) == CGSize(width: 640, height: 960), "Restarted take changed output dimensions")
        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoReader.add(videoOutput)
        try check(videoReader.startReading(), "Cannot decode the restarted take")
        var timestamps: [Double] = []
        while let sample = videoOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        }
        try check(videoReader.status == .completed && timestamps.count >= 20, "Restarted video did not decode completely")
        try check(zip(timestamps, timestamps.dropFirst()).allSatisfy { $1 > $0 }, "Restarted video timestamps are not monotonic")
        try check(abs(timestamps.first ?? 1) < 0.02, "A restarted take inherited the cancelled take's timeline")
        let videoRange = try await video.load(.timeRange), audioRange = try await audio.load(.timeRange)
        try check(videoRange.duration.seconds > 0.65 && videoRange.duration.seconds < 1.5, "Restarted take has an unexpected duration")
        try check(abs(videoRange.end.seconds - audioRange.end.seconds) < 0.15, "Restarted microphone and video are not aligned")
        let audioFormat = try await audio.load(.formatDescriptions)[0]
        try check(CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC &&
            CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee.mChannelsPerFrame == 1, "Restarted microphone is not mono AAC")
        let audioReader = try AVAssetReader(asset: asset)
        let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        audioReader.add(audioOutput)
        try check(audioReader.startReading(), "Cannot decode restarted microphone audio")
        var peak: Float = 0
        var nonzero = 0
        while let sample = audioOutput.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            for value in values { peak = max(peak, abs(value)); if abs(value) > 0.00001 { nonzero += 1 } }
        }
        try check(audioReader.status == .completed && peak > 0.1 && nonzero > 20_000, "Restart lost the selected microphone")
        print(String(format: "Restarted take: %d decoded video frames, %.3f s, %d nonzero microphone samples, A/V end %.1f ms",
            timestamps.count, videoRange.duration.seconds, nonzero, (audioRange.end.seconds - videoRange.end.seconds) * 1000))
        print("PASS: failed/no-frame camera activation preserves the current writer; Off cancels pending activation; stopped-camera callbacks cannot disable a replacement; active-camera interruption is recoverable; discard removes only unfinished files; restart retains preview/inputs and saves a valid synchronized take.")
        print("Restarted recording: \(url.path)")
    }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "vcam.lifecycle-validation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
