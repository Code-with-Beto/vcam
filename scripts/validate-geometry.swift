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
        print("PASS: vertical geometry, negative display origins, screen-edge restoration, resize limits, clamped movement, Retina source-pixel mapping, integral crop origins, preserved crop dimensions/aspect, and 1:1 edge contrast.")
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
