import Foundation
import CoreGraphics

struct CaptureConfiguration: Sendable {
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let captureFrame: CGRect
    let framesPerSecond: Int
    let microphoneID: String?
    let showsCursor: Bool
    var outputSize = CGSize(width: 1080, height: 1920)
    var microphoneChannel: Int? = nil
}

enum CaptureOrientation: String, CaseIterable, Identifiable, Sendable {
    case portrait, landscape
    var id: String { rawValue }
    var title: String { self == .portrait ? "Portrait" : "Landscape" }
    var aspectRatio: CGFloat { self == .portrait ? 9.0 / 16.0 : 16.0 / 9.0 }
    var ratioLabel: String { self == .portrait ? "9:16" : "16:9" }
}

enum OutputResolution: Int, CaseIterable, Identifiable, Sendable {
    case fullHD = 1080, qhd = 1440
    var id: Int { rawValue }
    var title: String { self == .fullHD ? "1080p" : "1440p · 2K" }
    func size(for orientation: CaptureOrientation) -> CGSize {
        let short = CGFloat(rawValue)
        let long = self == .fullHD ? CGFloat(1920) : CGFloat(2560)
        return orientation == .portrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
    }
}

/// All editable frame coordinates are global AppKit points, with a bottom-left origin.
enum CaptureGeometry {
    static let aspectRatio: CGFloat = 9.0 / 16.0
    static let outputSize = CGSize(width: 1080, height: 1920)

    static func frame(width: CGFloat, centeredAt center: CGPoint, within bounds: CGRect,
                      aspectRatio: CGFloat = CaptureGeometry.aspectRatio) -> CGRect {
        let fittedWidth = min(max(width, 144), bounds.width, bounds.height * aspectRatio)
        let size = CGSize(width: fittedWidth, height: fittedWidth / aspectRatio)
        return clamp(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                            width: size.width, height: size.height), to: bounds)
    }

    static func clamp(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - frame.width),
               y: min(max(frame.minY, bounds.minY), bounds.maxY - frame.height),
               width: frame.width, height: frame.height)
    }

    /// Map a frame that fits its display into the actual captured pixel buffer.
    /// Only the origin is snapped: fractional source dimensions retain the chosen
    /// crop size/aspect, while an integral origin avoids an extra subpixel resample.
    static func sourcePixelCrop(_ frame: CGRect, displayFrame: CGRect, pixelSize: CGSize) -> CGRect {
        let scaleX = pixelSize.width / displayFrame.width
        let scaleY = pixelSize.height / displayFrame.height
        let size = CGSize(width: frame.width * scaleX, height: frame.height * scaleY)
        let requestedX = ((frame.minX - displayFrame.minX) * scaleX).rounded()
        let requestedY = ((frame.minY - displayFrame.minY) * scaleY).rounded()
        // When the crop has a fractional width or height, rounding its last valid
        // origin upward could put its far edge outside the source image.
        let maximumX = max(0, floor(pixelSize.width - size.width))
        let maximumY = max(0, floor(pixelSize.height - size.height))
        return CGRect(x: min(max(requestedX, 0), maximumX),
                      y: min(max(requestedY, 0), maximumY),
                      width: size.width, height: size.height)
    }

    static func initialFrame(in bounds: CGRect, preferredWidth: CGFloat,
                             aspectRatio: CGFloat = CaptureGeometry.aspectRatio) -> CGRect {
        frame(width: preferredWidth,
              centeredAt: CGPoint(x: bounds.minX + bounds.width * 0.72, y: bounds.midY),
              within: bounds, aspectRatio: aspectRatio)
    }
}
