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
    var secondaryCaptureFrame: CGRect? = nil
    var layout: CaptureLayout = .single
    var splitRatio: Double = 0.5
    var camera = CameraConfiguration()
}

enum CameraPlacement: String, CaseIterable, Identifiable, Sendable {
    case off, overlay, regionA, regionB
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .overlay: return "Floating overlay"
        case .regionA: return "Replace region A"
        case .regionB: return "Replace region B"
        }
    }
}

enum CameraShape: String, CaseIterable, Identifiable, Sendable {
    case circle, roundedRectangle
    var id: String { rawValue }
    var title: String { self == .circle ? "Circle" : "Rounded rectangle" }
}

struct CameraOverlayConfiguration: Sendable, Equatable {
    /// Normalized output coordinates measured from the top-left, matching the UI.
    var center = CGPoint(x: 0.78, y: 0.20)
    var widthFraction: Double = 0.30
    var shape: CameraShape = .circle

    func clamped(in outputSize: CGSize) -> CameraOverlayConfiguration {
        var result = self
        result.widthFraction = widthFraction.isFinite ? min(max(widthFraction, 0.15), 0.65) : 0.30
        let width = min(outputSize.width, outputSize.height) * result.widthFraction
        let height = shape == .circle ? width : width * 0.75
        let halfX = width / max(outputSize.width, 1) / 2
        let halfY = height / max(outputSize.height, 1) / 2
        result.center.x = min(max(center.x.isFinite ? center.x : 0.78, halfX), 1 - halfX)
        result.center.y = min(max(center.y.isFinite ? center.y : 0.20, halfY), 1 - halfY)
        return result
    }

    /// The circle is square; rounded rectangles use a 4:3 frame. Returns pixels
    /// in Core Image's bottom-left coordinate space, fully inside the canvas.
    func rect(in outputSize: CGSize) -> CGRect {
        let normalized = clamped(in: outputSize)
        let width = min(outputSize.width, outputSize.height) * normalized.widthFraction
        let height = shape == .circle ? width : width * 0.75
        return CGRect(x: normalized.center.x * outputSize.width - width / 2,
            y: (1 - normalized.center.y) * outputSize.height - height / 2,
            width: width, height: height)
    }
}

/// Framing samples the camera after mirroring, so panning follows the image the
/// user sees. `center` is normalized source coordinates measured from top-left.
/// Zoom 1 is aspect-fill; larger values crop further without changing the frame.
struct CameraFramingConfiguration: Sendable, Equatable {
    var zoom: Double = 1
    var center = CGPoint(x: 0.5, y: 0.5)

    func clamped() -> CameraFramingConfiguration {
        CameraFramingConfiguration(
            zoom: zoom.isFinite ? min(max(zoom, 1), 4) : 1,
            center: CGPoint(x: center.x.isFinite ? min(max(center.x, 0), 1) : 0.5,
                            y: center.y.isFinite ? min(max(center.y, 0), 1) : 0.5))
    }

    /// The source crop in Core Image's bottom-left coordinates. The requested
    /// center is clamped by the crop's half extents, keeping every edge in-bounds.
    func sourceRect(in sourceSize: CGSize, filling destinationSize: CGSize) -> CGRect {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              destinationSize.width.isFinite, destinationSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0,
              destinationSize.width > 0, destinationSize.height > 0 else { return .zero }
        let normalized = clamped()
        let scale = max(destinationSize.width / sourceSize.width,
                        destinationSize.height / sourceSize.height)
        let width = min(sourceSize.width, destinationSize.width / scale) / normalized.zoom
        let height = min(sourceSize.height, destinationSize.height / scale) / normalized.zoom
        return CGRect(
            x: min(max(normalized.center.x * sourceSize.width - width / 2, 0), sourceSize.width - width),
            y: min(max((1 - normalized.center.y) * sourceSize.height - height / 2, 0), sourceSize.height - height),
            width: width, height: height)
    }

    /// Resolve a requested center to the visible crop before starting a drag,
    /// avoiding a dead zone when the stored center extends beyond a crop edge.
    func centerClamped(in sourceSize: CGSize, filling destinationSize: CGSize) -> CameraFramingConfiguration {
        var result = clamped()
        let crop = result.sourceRect(in: sourceSize, filling: destinationSize)
        guard !crop.isEmpty else { return result }
        result.center = CGPoint(x: crop.midX / sourceSize.width, y: 1 - crop.midY / sourceSize.height)
        return result
    }
}

struct CameraConfiguration: Sendable, Equatable {
    var deviceID: String? = nil
    var placement: CameraPlacement = .off
    var overlay = CameraOverlayConfiguration()
    var mirrored = true
    var framing = CameraFramingConfiguration()
    var isEnabled: Bool { deviceID != nil && placement != .off }
}

enum CaptureLayout: String, CaseIterable, Identifiable, Sendable {
    case single, stacked
    var id: String { rawValue }
    var title: String {
        switch self {
        case .single: return "Single region"
        case .stacked: return "Stacked"
        }
    }

    static func clampedSplitRatio(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0.15), 0.85) : 0.5
    }

    /// Rectangles use Core Image's bottom-left origin. A is top and B is bottom.
    /// Encoded output sizes are even; an even split boundary keeps
    /// both cells aligned with the encoder's chroma grid, with no canvas gaps.
    func destinationRects(in outputSize: CGSize, splitRatio: Double) -> [CGRect] {
        let canvas = CGRect(origin: .zero, size: outputSize)
        let ratio = CGFloat(Self.clampedSplitRatio(splitRatio))
        switch self {
        case .single:
            return [canvas]
        case .stacked:
            let height = min(max((outputSize.height * ratio / 2).rounded() * 2, 2), outputSize.height - 2)
            return [CGRect(x: 0, y: outputSize.height - height, width: outputSize.width, height: height),
                    CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height - height)]
        }
    }
}

struct CaptureComposition: Sendable {
    var layout: CaptureLayout = .single
    var splitRatio: Double = 0.5
    var primaryFrame: CGRect
    var secondaryFrame: CGRect?
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
                      aspectRatio: CGFloat = CaptureGeometry.aspectRatio,
                      minimumWidth: CGFloat = 144) -> CGRect {
        let validMinimum = minimumWidth.isFinite && minimumWidth > 0 ? minimumWidth : 144
        let fittedWidth = min(max(width, validMinimum), bounds.width, bounds.height * aspectRatio)
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
