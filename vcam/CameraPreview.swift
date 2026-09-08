import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI

/// A stable native video surface: frames go directly to the renderer rather than
/// becoming observable SwiftUI image state on every capture tick.
@MainActor
final class CameraPreviewSurface: NSView {
    private let videoLayer = AVSampleBufferDisplayLayer()
    private var videoFormat: CMVideoFormatDescription?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        // Immediate-display samples use the host clock, without a playback timebase.
        videoLayer.controlTimebase = nil
        layer?.addSublayer(videoLayer)
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 1
    }

    /// Pixel buffers must be IOSurface-backed and remain immutable after delivery.
    /// AVFoundation retains each enqueued buffer until it finishes displaying it.
    func display(_ pixelBuffer: CVPixelBuffer) {
        if videoFormat.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) != true {
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &format
            ) == noErr, let format else { return }
            videoFormat = format
        }
        guard let videoFormat else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: videoFormat,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return }

        // This per-sample attachment replaces older queued images immediately.
        // It must not be set as a whole-buffer attachment with CMSetAttachment.
        sample.sampleAttachments[0][.displayImmediately] = true
        let renderer = videoLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding || !renderer.isReadyForMoreMediaData {
            // Live preview favors the newest frame over playing a delayed backlog.
            // Raw pixel buffers have no dependency on previous encoded keyframes.
            renderer.flush()
        }
        renderer.enqueue(sample)
    }

    func clear() {
        videoFormat = nil
        videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}

struct CameraPreview: NSViewRepresentable {
    let surface: CameraPreviewSurface

    func makeNSView(context: Context) -> CameraPreviewSurface { surface }

    func updateNSView(_ nsView: CameraPreviewSurface, context: Context) {}
}
