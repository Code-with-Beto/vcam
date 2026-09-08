import Foundation
import CoreGraphics
import CoreImage

@main
struct ValidateGeometry {
    static func main() {
        let leftDisplay = CGRect(x: -1920, y: -240, width: 1920, height: 1080)
        let requested = CaptureGeometry.frame(width: 540, centeredAt: CGPoint(x: -1910, y: 830), within: leftDisplay)
        precondition(leftDisplay.contains(requested), "Frame must fit a display with a negative origin")
        precondition(abs(requested.width / requested.height - 9.0 / 16.0) < 0.000001)
        precondition(requested.minX == leftDisplay.minX && requested.maxY == leftDisplay.maxY,
                     "Position at a screen edge must survive clamping")
        let restored = CaptureGeometry.frame(width: requested.width,
            centeredAt: CGPoint(x: requested.midX, y: requested.midY), within: leftDisplay)
        precondition(restored == requested, "Restoring a frame at an edge must not shift it")
        let smallScreen = CGRect(x: 250, y: 40, width: 800, height: 500)
        let oversized = CaptureGeometry.frame(width: 900, centeredAt: CGPoint(x: 600, y: 300), within: smallScreen)
        precondition(smallScreen.contains(oversized))
        precondition(abs(oversized.height - 500) < 0.001, "Oversized frame must fit the available height")
        precondition(abs(oversized.width / oversized.height - 9.0 / 16.0) < 0.000001)
        let moved = CaptureGeometry.clamp(requested.offsetBy(dx: 5000, dy: -5000), to: leftDisplay)
        precondition(leftDisplay.contains(moved))
        precondition(moved.size == requested.size, "Moving a frame must never resize it")
        validateSourcePixelCrop()
        validatePixelAlignedContrast()
        validateCameraFraming()
        print("PASS: vertical geometry, negative display origins, screen-edge restoration, resize limits, clamped movement, Retina source-pixel mapping, integral crop origins, preserved crop dimensions/aspect, 1:1 edge contrast, and camera aspect-fill/zoom/pan clamping.")
    }

    static func validateCameraFraming() {
        precondition(CaptureLayout.allCases == [.single, .stacked], "Only single and stacked layouts should remain")
        let source = CGSize(width: 1920, height: 1080)
        let square = CGSize(width: 500, height: 500)
        let normal = CameraFramingConfiguration()
        precondition(normal.sourceRect(in: source, filling: square) == CGRect(x: 420, y: 0, width: 1080, height: 1080),
                     "At 1x, a square camera must aspect-fill rather than stretch")
        let zoomed = CameraFramingConfiguration(zoom: 2)
        precondition(zoomed.sourceRect(in: source, filling: square) == CGRect(x: 690, y: 270, width: 540, height: 540),
                     "Zoom 2 must crop half the source width and height around the center")
        let topRight = CameraFramingConfiguration(zoom: 2, center: CGPoint(x: 1, y: 0))
        precondition(topRight.sourceRect(in: source, filling: square) == CGRect(x: 1380, y: 540, width: 540, height: 540),
                     "Top-left UI coordinates must select the top-right source without exposing an edge")
        let visible = topRight.centerClamped(in: source, filling: square)
        precondition(visible.center == CGPoint(x: 1650.0 / 1920.0, y: 0.25),
                     "The drag origin must resolve to the visible crop center without a dead zone")
        let invalid = CameraFramingConfiguration(zoom: .nan, center: CGPoint(x: CGFloat.infinity, y: CGFloat.nan)).clamped()
        precondition(invalid == normal, "Nonfinite stored framing must return safe defaults")
        precondition(CameraFramingConfiguration(zoom: 99, center: CGPoint(x: -3, y: 5)).clamped()
            == CameraFramingConfiguration(zoom: 4, center: CGPoint(x: 0, y: 1)), "Framing must respect its public bounds")
        for source in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 640, height: 480)] {
            for destination in [square, CGSize(width: 800, height: 600), CGSize(width: 1440, height: 384), CGSize(width: 1440, height: 2176)] {
                for zoom in [-1.0, 1, 1.7, 4, 10, .nan] {
                    for center in [CGPoint.zero, CGPoint(x: 0.37, y: 0.68), CGPoint(x: 1, y: 1)] {
                        let framing = CameraFramingConfiguration(zoom: zoom, center: center)
                        let rect = framing.sourceRect(in: source, filling: destination)
                        precondition(CGRect(origin: .zero, size: source).insetBy(dx: -0.000001, dy: -0.000001).contains(rect),
                                     "Every zoomed camera crop must remain inside the native source")
                        precondition(abs(rect.width / rect.height - destination.width / destination.height) < 0.000001,
                                     "Framing must retain the destination aspect at every crop and zoom")
                        let resolved = framing.centerClamped(in: source, filling: destination)
                            .sourceRect(in: source, filling: destination)
                        precondition(abs(resolved.minX - rect.minX) < 0.000001 && abs(resolved.minY - rect.minY) < 0.000001,
                                     "Clamping the drag center must not change the visible crop")
                    }
                }
            }
        }
        precondition(normal.sourceRect(in: .zero, filling: square) == .zero,
                     "A temporarily unavailable camera size must not produce invalid geometry")
    }

    static func validateSourcePixelCrop() {
        let display = CGRect(x: -1920, y: -240, width: 1920, height: 1080)
        let pixels = CGSize(width: 3840, height: 2160)
        let frame = CGRect(x: -1800, y: -200, width: 540, height: 960)
        let crop = CaptureGeometry.sourcePixelCrop(frame, displayFrame: display, pixelSize: pixels)
        precondition(crop == CGRect(x: 240, y: 80, width: 1080, height: 1920),
                     "A negative-origin Retina display must map into zero-origin captured pixels")

        let fractional = CaptureGeometry.sourcePixelCrop(frame.offsetBy(dx: 0.25, dy: 0.375),
            displayFrame: display, pixelSize: pixels)
        precondition(fractional.origin == CGPoint(x: 241, y: 81),
                     "Source coordinates must round to the nearest integral pixel")
        precondition(fractional.size == crop.size, "Snapping an origin must not resize the crop")

        let fractionalHeight: CGFloat = 960.375
        let fractionalWidth = fractionalHeight * 9 / 16
        let edgeFrame = CGRect(x: display.maxX - fractionalWidth, y: display.maxY - fractionalHeight,
                               width: fractionalWidth, height: fractionalHeight)
        let atEdge = CaptureGeometry.sourcePixelCrop(edgeFrame, displayFrame: display, pixelSize: pixels)
        precondition(atEdge.origin == CGPoint(x: 2759, y: 239),
                     "A fractional-sized crop at the top/right edge must clamp to an integral in-bounds origin")
        precondition(atEdge.width == fractionalWidth * 2 && atEdge.height == fractionalHeight * 2,
                     "Source-pixel alignment must preserve fractional dimensions")
        precondition(abs(atEdge.width / atEdge.height - 9.0 / 16.0) < 0.000001,
                     "Source-pixel alignment must preserve the requested aspect ratio")
        precondition(CGRect(origin: .zero, size: pixels).contains(atEdge),
                     "Rounding must never place the crop beyond the actual pixel buffer")

        let outside = CaptureGeometry.sourcePixelCrop(frame.offsetBy(dx: -10_000, dy: -10_000),
            displayFrame: display, pixelSize: pixels)
        precondition(outside.origin == .zero && outside.size == crop.size,
                     "Movement beyond the bottom/left edge must clamp without resizing")
        let fullDisplay = CaptureGeometry.sourcePixelCrop(display, displayFrame: display, pixelSize: pixels)
        precondition(fullDisplay == CGRect(origin: .zero, size: pixels),
                     "A full-display crop must exactly cover the pixel buffer")

        let alternatePixels = CGSize(width: 2880, height: 1620)
        let alternateCrop = CaptureGeometry.sourcePixelCrop(frame, displayFrame: display, pixelSize: alternatePixels)
        precondition(alternateCrop == CGRect(x: 180, y: 60, width: 810, height: 1440),
                     "Mapping must use actual captured dimensions rather than assume a 2x backing scale")
    }

    static func validatePixelAlignedContrast() {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let width = 8, height = 4
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value: UInt8 = x.isMultiple(of: 2) ? 0 : 255
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
            }
        }
        let source = CIImage(bitmapData: Data(pixels), bytesPerRow: width * 4,
            size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let display = CGRect(x: -10, y: -2, width: width, height: height)
        let requested = CGRect(x: -7.5, y: -2, width: 4, height: 4)
        let aligned = CaptureGeometry.sourcePixelCrop(requested, displayFrame: display,
            pixelSize: CGSize(width: width, height: height))
        let image = source.cropped(to: aligned)
            .transformed(by: CGAffineTransform(translationX: -aligned.minX, y: -aligned.minY))
        var rendered = [UInt8](repeating: 0, count: 4 * 4 * 4)
        context.render(image, toBitmap: &rendered, rowBytes: 4 * 4,
            bounds: CGRect(x: 0, y: 0, width: 4, height: 4), format: .RGBA8, colorSpace: colorSpace)
        let interior = [rendered[(1 * 4 + 1) * 4], rendered[(1 * 4 + 2) * 4]]
        precondition(interior == [0, 255],
                     "A 1:1 capture with a fractional requested position must retain black/white contrast, not interpolate to gray")
    }
}
