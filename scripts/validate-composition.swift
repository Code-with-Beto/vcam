// Run from the repository root. Uses synthetic pixels/PCM, never screen or microphone access.
// DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swiftc \
//   -D VCAM_CAPTURE_VALIDATION -swift-version 5 -target arm64-apple-macos15.0 \
//   vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
//   vcam/CaptureCamera.swift vcam/CaptureEngine.swift scripts/validate-composition.swift -o /tmp/vcam-validate-composition
// /tmp/vcam-validate-composition [width height] (defaults: 1440 2560)
import AVFoundation
import CoreImage
import Foundation

@main
struct ValidateComposition {
    static let palette = [[220, 35, 45], [25, 180, 65], [30, 70, 220], [225, 185, 25]]
    static let display = CGRect(x: -400, y: -150, width: 400, height: 300)
    static let sources = [CGRect(x: -400, y: 0, width: 200, height: 150),
                          CGRect(x: -400, y: -150, width: 200, height: 150),
                          CGRect(x: -200, y: 0, width: 200, height: 150),
                          CGRect(x: -200, y: -150, width: 200, height: 150)]

    static func main() async throws {
        try validateDestinationGeometry()
        let arguments = Array(CommandLine.arguments.dropFirst())
        let width = Int(arguments.first ?? "1440") ?? 0
        let height = Int(arguments.dropFirst().first ?? "2560") ?? 0
        try check(width >= 512 && height >= 512 && width <= 3840 && height <= 3840 &&
                  width % 2 == 0 && height % 2 == 0, "Choose even output dimensions from 512 through 3840")
        let size = CGSize(width: width, height: height)
        let source = try makeSource()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vcam-composition-validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for layout in CaptureLayout.allCases {
            // The source regions deliberately have a different aspect from each cell.
            // The white circles must stay circular under the defensive aspect-fill.
            let phases = [
                CaptureComposition(layout: layout, splitRatio: 0.5, primaryFrame: sources[0], secondaryFrame: sources[2]),
                CaptureComposition(layout: layout, splitRatio: 0.5, primaryFrame: sources[1], secondaryFrame: sources[2]),
                CaptureComposition(layout: layout, splitRatio: 0.5, primaryFrame: sources[1], secondaryFrame: sources[3]),
                CaptureComposition(layout: layout, splitRatio: 0.7, primaryFrame: sources[1], secondaryFrame: sources[3])
            ]
            let result = try await CaptureWorker.recordCompositionFixture(source, displayFrame: display,
                phases: phases, to: directory.appendingPathComponent("\(layout.rawValue).mp4"), outputSize: size)
            try await inspect(result.url, times: result.sampleTimes, phases: phases,
                              expectedColors: [[0, 2], [1, 2], [1, 3], [1, 3]], size: size)
            print("PASS: \(layout.rawValue): encoded cell positions, independent A/B movement, live split, uniform aspect-fill, one synchronized mono AAC track.")
        }
        print("Composition recordings: \(directory.path)")
    }

    static func validateDestinationGeometry() throws {
        for size in [CGSize(width: 1440, height: 2560), CGSize(width: 2560, height: 1440)] {
            for layout in CaptureLayout.allCases {
                for ratio in [-1.0, 0.15, 0.333, 0.5, 0.85, 2.0, .nan] {
                    let cells = layout.destinationRects(in: size, splitRatio: ratio)
                    let canvas = CGRect(origin: .zero, size: size)
                    try check(cells.count == (layout == .single ? 1 : 2), "Incorrect number of destination cells")
                    try check(cells.allSatisfy { canvas.contains($0) && $0.width > 0 && $0.height > 0 }, "A destination lies outside the canvas")
                    try check(cells.allSatisfy { $0.width.truncatingRemainder(dividingBy: 2) == 0 && $0.height.truncatingRemainder(dividingBy: 2) == 0 }, "Cell dimensions must be even")
                    try check(cells.reduce(0) { $0 + $1.width * $1.height } == size.width * size.height, "Cells must cover the entire canvas without gaps")
                    if cells.count == 2 {
                        try check(cells[0].union(cells[1]) == canvas && cells[0].intersection(cells[1]).isEmpty, "Cells overlap or leave a seam")
                        if layout == .sideBySide {
                            try check(cells[0].minX == 0 && cells[0].maxX == cells[1].minX, "A must be left of B")
                        } else {
                            try check(cells[0].maxY == size.height && cells[0].minY == cells[1].maxY, "A must be above B")
                        }
                    }
                }
            }
        }
        try check(CaptureLayout.clampedSplitRatio(-1) == 0.15 && CaptureLayout.clampedSplitRatio(2) == 0.85 && CaptureLayout.clampedSplitRatio(.nan) == 0.5,
                  "Split-ratio bounds must be stable")
        let display = CGRect(x: -1000, y: -100, width: 1600, height: 900)
        let cellAspect: CGFloat = 216.0 / 2560.0
        let narrow = CaptureGeometry.frame(width: 54, centeredAt: CGPoint(x: -200, y: 350),
            within: display, aspectRatio: cellAspect, minimumWidth: 1)
        try check(narrow.width == 54 && narrow.height == 640 && display.contains(narrow),
                  "Automatic split fitting must preserve narrow regions without applying the manual 144-point minimum")
        for minimum: CGFloat in [.nan, .infinity, 0, -1] {
            let frame = CaptureGeometry.frame(width: 54, centeredAt: .zero, within: display,
                aspectRatio: 1, minimumWidth: minimum)
            try check(frame.width == 144, "An invalid minimum width must retain the manual default")
        }
    }

    static func makeSource() throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        try check(CVPixelBufferCreate(kCFAllocatorDefault, 800, 600, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &created) == kCVReturnSuccess,
            "Cannot allocate source pixels")
        let buffer = created!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let data = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<600 {
            for x in 0..<800 {
                let index = (x < 400 ? 0 : 2) + (y < 300 ? 0 : 1)
                let cx = x < 400 ? 200 : 600, cy = y < 300 ? 150 : 450
                let isCircle = (x - cx) * (x - cx) + (y - cy) * (y - cy) <= 12 * 12
                let rgb = isCircle ? [245, 245, 245] : palette[index]
                let offset = y * rowBytes + x * 4
                data[offset] = UInt8(rgb[2]); data[offset + 1] = UInt8(rgb[1])
                data[offset + 2] = UInt8(rgb[0]); data[offset + 3] = 255
            }
        }
        return buffer
    }

    static func inspect(_ url: URL, times: [Double], phases: [CaptureComposition], expectedColors: [[Int]], size: CGSize) async throws {
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        try check(videos.count == 1 && audios.count == 1, "Composition must retain one video and one audio track")
        try check(try await videos[0].load(.naturalSize) == size, "Composition changed the output resolution")
        let audioFormat = try await audios[0].load(.formatDescriptions)[0]
        try check(CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatMPEG4AAC &&
            CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee.mChannelsPerFrame == 1, "Microphone must remain mono AAC")
        let videoRange = try await videos[0].load(.timeRange), audioRange = try await audios[0].load(.timeRange)
        try check(abs(videoRange.start.seconds - audioRange.start.seconds) < 0.15 && abs(videoRange.end.seconds - audioRange.end.seconds) < 0.2,
                  "Composition updates changed audio/video alignment")
        let timingReader = try AVAssetReader(asset: asset)
        let timingOutput = AVAssetReaderTrackOutput(track: videos[0], outputSettings: nil)
        timingReader.add(timingOutput)
        try check(timingReader.startReading(), "Cannot inspect the composition timeline")
        var frameTimes: [Double] = []
        while let sample = timingOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 {
                frameTimes.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
        }
        try check(timingReader.status == .completed && frameTimes.count > 20, "Composition video is incomplete")
        let frameRate = Double(frameTimes.count - 1) / (frameTimes.last! - frameTimes.first!)
        try check(frameRate > 27 && frameRate < 33, "Composition missed the 30 fps cadence: \(frameRate)")
        print(String(format: "%@ %.0f×%.0f: %.2f fps; %d frames; A/V end difference %.1f ms",
            phases[0].layout.rawValue, size.width, size.height, frameRate, frameTimes.count,
            (audioRange.end.seconds - videoRange.end.seconds) * 1_000))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        var images: [ImagePixels] = []
        for (index, time) in times.enumerated() {
            let cgImage = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let image = try ImagePixels(cgImage)
            images.append(image)
            let cells = phases[index].layout.destinationRects(in: size, splitRatio: phases[index].splitRatio)
            for (cellIndex, cell) in cells.enumerated() {
                let rgb = image.pixel(at: CGPoint(x: cell.minX + cell.width * 0.18, y: cell.minY + cell.height * 0.2))
                try expect(rgb, palette[expectedColors[index][cellIndex]], "Phase \(index), cell \(cellIndex)")
                try verifyCircle(image, in: cell)
            }
        }
        if phases[0].layout != .single {
            let crossingPoint = phases[0].layout == .sideBySide
                ? CGPoint(x: size.width * 0.6, y: size.height * 0.2)
                : CGPoint(x: size.width * 0.18, y: size.height * 0.4)
            try expect(images[2].pixel(at: crossingPoint), palette[3], "Before moving the split, this pixel must belong to B")
            try expect(images[3].pixel(at: crossingPoint), palette[1], "After moving the split, this pixel must belong to A")
        } else {
            // H.264 may encode identical source frames with slightly different
            // quantization. Compare the whole decoded image with that tolerance.
            for index in 2...3 {
                let difference = zip(images[1].data, images[index].data).reduce(0) {
                    $0 + abs(Int($1.0) - Int($1.1))
                }
                let meanDifference = Double(difference) / Double(images[1].data.count)
                try check(meanDifference < 1,
                    "Changing unused B or the split ratio changed single-region pixels: mean error \(meanDifference)")
            }
        }
        let reader = try AVAssetReader(asset: asset)
        let audioOutput = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(audioOutput)
        try check(reader.startReading(), "Cannot decode composition audio")
        var peak: Float = 0
        while let sample = audioOutput.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            peak = max(peak, values.map { abs($0) }.max() ?? 0)
        }
        try check(reader.status == .completed && peak > 0.1, "Composited movie lost microphone audio")
    }

    static func verifyCircle(_ image: ImagePixels, in cell: CGRect) throws {
        func white(_ rgb: [Int]) -> Bool { rgb.allSatisfy { $0 > 225 } }
        // Integral source origins can place the circle's raster center a fraction
        // of a source pixel off the cell midpoint. Search nearby scanlines so a
        // large upscale does not turn that expected offset into a false stretch.
        let radius = Int(ceil(max(cell.width / 400, cell.height / 300))) + 1
        let horizontal = (-radius...radius).map { offset in
            (Int(cell.minX)..<Int(cell.maxX)).filter {
                white(image.pixel(at: CGPoint(x: CGFloat($0), y: cell.midY + CGFloat(offset))))
            }.count
        }.max()!
        let vertical = (-radius...radius).map { offset in
            (Int(cell.minY)..<Int(cell.maxY)).filter {
                white(image.pixel(at: CGPoint(x: cell.midX + CGFloat(offset), y: CGFloat($0))))
            }.count
        }.max()!
        try check(horizontal > 10 && vertical > 10 && abs(horizontal - vertical) <= 4,
                  "Aspect-fill stretched a source circle: \(horizontal)×\(vertical)")
    }

    struct ImagePixels {
        let width: Int, height: Int
        let data: [UInt8]
        init(_ image: CGImage) throws {
            width = image.width; height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw failure("Cannot inspect composited pixels")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            data = bytes
        }
        func pixel(at point: CGPoint) -> [Int] {
            let x = min(max(Int(point.x), 0), width - 1)
            let y = min(max(height - 1 - Int(point.y), 0), height - 1)
            let offset = (y * width + x) * 4
            return (0..<3).map { Int(data[offset + $0]) }
        }
    }
    static func expect(_ actual: [Int], _ expected: [Int], _ label: String) throws {
        try check(zip(actual, expected).allSatisfy { abs($0 - $1) <= 8 }, "\(label): got \(actual), expected \(expected)")
    }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "vcam.composition-validation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
