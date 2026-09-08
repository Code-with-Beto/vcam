// Run from the project root (uses generated pixels only; no screen or microphone access):
// xcrun swiftc -D VCAM_CAPTURE_VALIDATION -swift-version 5 -target arm64-apple-macos15.0 \
//   vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
//   vcam/CaptureCamera.swift vcam/CaptureEngine.swift scripts/validate-color.swift -o /tmp/vcam-validate-color
// /tmp/vcam-validate-color [1080|1440]
//
// Measures actual production preview buffers and H.264 decoded pixels in the same
// explicitly defined sRGB space. Metadata alone cannot make this validation pass.
import AppKit
import AVFoundation
import CoreImage
import CoreVideo

private struct ColorPatch {
    let name: String
    let rgb: [UInt8]
}

private struct Raster {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    func pixel(_ x: Int, _ y: Int) -> [Double] {
        let offset = (y * width + x) * 4
        return (0..<3).map { Double(rgba[offset + $0]) }
    }

    func patchMean(_ index: Int) -> [Double] {
        let cellWidth = Double(width) / 6, cellHeight = Double(height) / 4
        let minX = Int((Double(index % 6) + 0.35) * cellWidth)
        let maxX = Int((Double(index % 6) + 0.65) * cellWidth)
        let minY = Int((Double(index / 6) + 0.35) * cellHeight)
        let maxY = Int((Double(index / 6) + 0.65) * cellHeight)
        var sums = [Double](repeating: 0, count: 3)
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = (y * width + x) * 4
                for channel in 0..<3 { sums[channel] += Double(rgba[offset + channel]) }
            }
        }
        return sums.map { $0 / Double((maxX - minX) * (maxY - minY)) }
    }
}

private final class PreviewCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    func receive(_ buffer: CVPixelBuffer) { lock.lock(); latest = buffer; lock.unlock() }
    func snapshot() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return latest }
}

@main
struct ValidateColor {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let patches: [ColorPatch] = {
        let grays: [UInt8] = [0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 192, 224, 240, 255]
        return grays.map { ColorPatch(name: "gray \($0)", rgb: [$0, $0, $0]) } + [
            ColorPatch(name: "red", rgb: [255, 0, 0]),
            ColorPatch(name: "green", rgb: [0, 255, 0]),
            ColorPatch(name: "blue", rgb: [0, 0, 255]),
            ColorPatch(name: "cyan", rgb: [0, 255, 255]),
            ColorPatch(name: "magenta", rgb: [255, 0, 255]),
            ColorPatch(name: "yellow", rgb: [255, 255, 0]),
            ColorPatch(name: "system blue", rgb: [0, 122, 255]),
            ColorPatch(name: "muted blue", rgb: [40, 116, 209]),
            ColorPatch(name: "8 px stripes", rgb: [0, 0, 0])
        ]
    }()

    static func main() async {
        do { try await validate() }
        catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func validate() async throws {
        let shortEdge = Int(CommandLine.arguments.dropFirst().first ?? "1080") ?? 0
        try require(shortEdge == 1080 || shortEdge == 1440, "Choose 1080 or 1440")
        let size = CGSize(width: shortEdge, height: shortEdge * 16 / 9)
        let source = try makeFixture(width: Int(size.width), height: Int(size.height))
        let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        let reference = try rasterize(CIImage(cvPixelBuffer: source), context: context)
        // Check the reference independently against the original sRGB byte values,
        // so a conversion mistake in the test cannot silently redefine its target.
        for (index, patch) in patches.dropLast().enumerated() {
            let error = channelError(reference.patchMean(index), patch.rgb.map(Double.init))
            try require(error <= 1, "Reference \(patch.name) changed by \(error) sRGB levels")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vcam-color-validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preview = PreviewCollector()
        let movie = try await CaptureWorker.recordColorFixture(source,
            to: directory.appendingPathComponent("color-chart.mp4"), outputSize: size,
            onPreview: { preview.receive($0) })
        guard let previewBuffer = preview.snapshot() else { throw failure("No native preview buffer arrived") }
        let previewRaster = try rasterize(CIImage(cvPixelBuffer: previewBuffer), context: context)
        let asset = AVURLAsset(url: movie)
        let video = try await asset.loadTracks(withMediaType: .video)
        try require(video.count == 1, "Expected one encoded video track")
        let naturalSize = try await video[0].load(.naturalSize)
        try require(naturalSize == size, "Encoded dimensions do not match fixture")
        let generator = AVAssetImageGenerator(asset: asset)
        let decoded = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let videoRaster = try rasterize(CIImage(cgImage: decoded), context: context)

        var failures: [String] = []
        print("Comparison: 8-bit sRGB; center 30% of each solid patch; actual production crop/render/encode/decode.")
        print("Patch                 source RGB         preview RGB        video RGB")
        var previewMaximum: Double = 0, videoMaximum: Double = 0
        for (index, patch) in patches.dropLast().enumerated() {
            let expected = patch.rgb.map(Double.init)
            let live = previewRaster.patchMean(index), saved = videoRaster.patchMean(index)
            previewMaximum = max(previewMaximum, channelError(live, expected))
            videoMaximum = max(videoMaximum, channelError(saved, expected))
            print(patch.name.padding(toLength: 22, withPad: " ", startingAt: 0)
                + rgb(expected).padding(toLength: 19, withPad: " ", startingAt: 0)
                + rgb(live).padding(toLength: 19, withPad: " ", startingAt: 0) + rgb(saved))
        }
        // Flat, opaque interiors avoid scaling edges and 4:2:0 chroma boundaries.
        // Two preview levels allow 8-bit color conversion rounding. Six encoded
        // levels allow H.264 quantization and YCbCr round trips, while catching the
        // substantially larger midtone shifts caused by a transfer-function mix-up.
        if previewMaximum > 2 { failures.append(String(format: "Preview max channel error %.2f exceeds 2 sRGB levels", previewMaximum)) }
        if videoMaximum > 6 { failures.append(String(format: "Video max channel error %.2f exceeds 6 sRGB levels", videoMaximum)) }
        for (name, raster, tolerance) in [("Preview", previewRaster, 3.0), ("Video", videoRaster, 8.0)] {
            let contrast = raster.patchMean(12)[0] - raster.patchMean(2)[0]
            print(String(format: "%@ grayscale contrast (224−32): %.2f; target 192", name, contrast))
            if abs(contrast - 192) > tolerance { failures.append("\(name) changed grayscale contrast") }
            let stripeContrast = stripeContrast(raster, sourceWidth: reference.width)
            print(String(format: "%@ 8-source-pixel stripe contrast: %.2f /255", name, stripeContrast))
            if stripeContrast < 235 { failures.append("\(name) blurred the centers of 8-source-pixel black/white stripes") }
        }
        print(String(format: "Maximum error: preview %.2f /255; decoded video %.2f /255", previewMaximum, videoMaximum))
        print("Synthetic recording: \(movie.path)")
        try require(failures.isEmpty, failures.joined(separator: "; "))
        print("PASS: sRGB colors, grayscale contrast, and stripe detail survive native preview and H.264 recording at \(Int(size.width))×\(Int(size.height)).")
    }

    private static func makeFixture(width: Int, height: Int) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        try require(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &optional) == kCVReturnSuccess, "Cannot allocate fixture pixels")
        let buffer = optional!
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * 4 / height) * 6 + x * 6 / width
                let color: [UInt8]
                if index == patches.count - 1 {
                    let value: UInt8 = ((x - width * 5 / 6) / 8).isMultiple(of: 2) ? 0 : 255
                    color = [value, value, value]
                } else { color = patches[index].rgb }
                let offset = y * rowBytes + x * 4
                bytes[offset] = color[2]; bytes[offset + 1] = color[1]
                bytes[offset + 2] = color[0]; bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, srgb, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return buffer
    }

    private static func rasterize(_ image: CIImage, context: CIContext) throws -> Raster {
        guard let cgImage = context.createCGImage(image, from: image.extent,
            format: .RGBA8, colorSpace: srgb) else { throw failure("Cannot normalize image into sRGB") }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let bitmap = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            bitmap.interpolationQuality = .none
            bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try require(drawn, "Cannot read sRGB comparison pixels")
        return Raster(width: width, height: height, rgba: pixels)
    }

    private static func stripeContrast(_ raster: Raster, sourceWidth: Int) -> Double {
        let start = sourceWidth * 5 / 6, end = sourceWidth
        var black: [Double] = [], white: [Double] = []
        for sourceX in stride(from: start + 20, to: end - 8, by: 8) {
            let x = min(raster.width - 1, Int((Double(sourceX) + 0.5) * Double(raster.width) / Double(sourceWidth)))
            let luma = raster.pixel(x, Int(Double(raster.height) * 0.875)).reduce(0, +) / 3
            if ((sourceX - start) / 8).isMultiple(of: 2) { black.append(luma) }
            else { white.append(luma) }
        }
        return white.reduce(0, +) / Double(white.count) - black.reduce(0, +) / Double(black.count)
    }

    private static func rgb(_ values: [Double]) -> String { values.map { String(format: "%.1f", $0) }.joined(separator: ",") }
    private static func channelError(_ actual: [Double], _ expected: [Double]) -> Double { zip(actual, expected).map { abs($0 - $1) }.max() ?? 0 }
    private static func failure(_ message: String) -> NSError { NSError(domain: "vcam.color-validation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
}
