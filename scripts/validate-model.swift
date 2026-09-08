// Run from the project root. The temporary source copy redirects preferences to
// this validator's UUID-named suite; production source and app preferences stay intact.
// sed 's/UserDefaults\.standard/ModelValidation.defaults/g' vcam/RecorderModel.swift \
//   > /tmp/vcam-model-validation-source.swift
// xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 \
//   vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift vcam/CaptureCamera.swift \
//   vcam/CaptureEngine.swift vcam/CameraPreview.swift vcam/SafeAreaGuide.swift \
//   vcam/FrameOverlay.swift vcam/GlobalShortcuts.swift \
//   /tmp/vcam-model-validation-source.swift scripts/validate-model.swift \
//   -o /tmp/vcam-validate-model && /tmp/vcam-validate-model
//
// No prepare(), device discovery, permissions, shortcuts, capture, or visible windows.
import AppKit

@MainActor
enum ModelValidation {
    static let suite = "dev.codewithbeto.vcam.validation.\(UUID().uuidString)"
    static let defaults = UserDefaults(suiteName: suite)!

    static func makeModel(width: CGFloat = 1800, height: CGFloat = 900,
                          resolution: OutputResolution = .qhd) throws -> RecorderModel {
        defaults.removePersistentDomain(forName: suite)
        defaults.set(360.0, forKey: "frameWidth")
        defaults.set(resolution.rawValue, forKey: "resolution")
        defaults.set("", forKey: "microphoneID")
        let model = RecorderModel()
        try require(model.frameWidth == 360 && model.selectedMicrophoneID.isEmpty,
                    "Model must use the isolated validation preferences")
        let bounds = CGRect(x: -1200, y: -200, width: width, height: height)
        let display = DisplayChoice(id: 0xC0A1, name: "Synthetic display", frame: bounds,
                                   visibleFrame: bounds, scale: 2)
        model.displays = [display]
        model.selectDisplay(display.id)
        model.setFrameWidth(360)
        return model
    }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "vcam.model-validation", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func equalSize(_ actual: CGSize, _ expected: CGSize, _ label: String) throws {
        try require(abs(actual.width - expected.width) < 0.001 && abs(actual.height - expected.height) < 0.001,
                    "\(label): got \(actual), expected \(expected)")
    }

    static func validRegions(_ model: RecorderModel) throws {
        let frames = model.hasTwoRegions ? [model.captureFrame, model.secondaryCaptureFrame] : [model.captureFrame]
        let cells = model.layout.destinationRects(in: model.outputSize, splitRatio: model.splitRatio)
        let bounds = model.selectedDisplay!.visibleFrame.insetBy(dx: -0.001, dy: -0.001)
        for (index, frame) in frames.enumerated() {
            try require(frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0,
                        "Region \(index) became empty or nonfinite")
            try require(bounds.contains(frame), "Region \(index) escaped the display: \(frame)")
            let expectedAspect = cells[index].width / cells[index].height
            try require(abs(frame.width / frame.height - expectedAspect) < 0.000001,
                        "Region \(index) no longer matches its destination cell")
        }
        try require(abs(model.frameWidth - model.activeCaptureFrame.width) < 0.001,
                    "Frame-size controls no longer describe the selected region")
        try require(model.minimumFrameWidth <= model.maximumFrameWidth, "Frame-size slider has an invalid range")
        try require(!model.isFrameVisible && !model.isPreviewing && !model.isRecording,
                    "Geometry validation must not show frames or start capture")
    }
}

@main
struct ValidateModel {
    @MainActor
    static func main() async {
        do {
            try ModelValidation.require(Bundle.main.bundleIdentifier == nil,
                                        "Run this as a standalone command, never inside the vcam app bundle")
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            defer { ModelValidation.defaults.removePersistentDomain(forName: ModelValidation.suite) }
            try validateNarrowSplit()
            try validateStackedClamping()
            try validateIndependentResize()
            try await validateLayoutTransitions()
            try await validateLayoutScaleRoundtrip()
            try validateSecondaryMetadata()
            try await validateCameraDefaultsAndOverlay()
            try await validateCameraRegionTransitions()
            try await validateCameraOverlayPersistence()
            try validateLegacyLayoutMigration()
            try await validateCameraFraming()
            try ModelValidation.require(application.windows.allSatisfy { !$0.isVisible },
                                        "Validation unexpectedly displayed a window")
            print("PASS: Model split roundtrips, display clamping, independent B sizing, layout/orientation aspects, secondary persistence metadata, camera placement/geometry/persistence, legacy layout migration, and camera crop/zoom isolation without starting inputs. Preferences used an isolated temporary suite.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func validateNarrowSplit() throws {
        let model = try ModelValidation.makeModel()
        model.setLayout(.stacked)
        let first = model.captureFrame, second = model.secondaryCaptureFrame
        model.setSplitRatio(0.15)
        try ModelValidation.equalSize(model.captureFrame.size, CGSize(width: 360, height: 96),
                                      "A narrow stacked split must allow a source shorter than 144 points")
        try ModelValidation.validRegions(model)
        model.setSplitRatio(0.85)
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, CGSize(width: 360, height: 96),
                                      "B narrow stacked split must allow a source shorter than 144 points")
        model.setSplitRatio(0.5)
        try ModelValidation.equalSize(model.captureFrame.size, first.size, "Narrow A roundtrip")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, second.size, "Narrow B roundtrip")
        try ModelValidation.validRegions(model)
        print("Narrow stacked split: A 360×320 → 360×96 → 360×320; B restores its size.")
    }

    @MainActor
    private static func validateStackedClamping() throws {
        let model = try ModelValidation.makeModel(width: 1600, height: 900)
        model.setLayout(.stacked)
        model.setFrameWidth(800)
        model.selectRegion(.secondary)
        model.setFrameWidth(600)
        let first = model.captureFrame.size, second = model.secondaryCaptureFrame.size
        model.setSplitRatio(0.85)
        try ModelValidation.require(model.captureFrame.width < first.width - 1,
                                    "Stacked fixture did not exercise display clamping")
        for ratio in [0.15, 0.5, 0.85, 0.15, 0.5] {
            model.setSplitRatio(ratio)
            try ModelValidation.validRegions(model)
        }
        try ModelValidation.equalSize(model.captureFrame.size, first, "Display-clamped stacked A roundtrip")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, second, "Display-clamped stacked B roundtrip")
        print("Stacked clamp: repeated 15–85% changes restore A's 800pt and B's 600pt widths.")
    }

    @MainActor
    private static func validateIndependentResize() throws {
        let model = try ModelValidation.makeModel()
        model.setLayout(.stacked)
        let first = model.captureFrame
        model.selectRegion(.secondary)
        model.setFrameHeight(400)
        try ModelValidation.require(model.captureFrame == first, "Resizing B changed A in Stacked")
        try ModelValidation.require(abs(model.secondaryCaptureFrame.height - 400) < 0.001,
                                    "The height entry did not resize selected B")
        let resized = model.secondaryCaptureFrame.size
        model.setSplitRatio(0.15)
        model.setSplitRatio(0.5)
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, resized, "Explicit B scale after divider roundtrip")
        try ModelValidation.validRegions(model)
        print("Region selection: explicit B sizing leaves A unchanged and establishes B's new split scale.")
    }

    @MainActor
    private static func validateLayoutTransitions() async throws {
        for resolution in OutputResolution.allCases {
            let model = try ModelValidation.makeModel(resolution: resolution)
            for orientation in [CaptureOrientation.portrait, .landscape, .portrait] {
                await model.setOrientation(orientation)
                for layout in [CaptureLayout.single, .stacked, .single] {
                    model.setLayout(layout)
                    if model.hasTwoRegions {
                        model.selectRegion(.secondary)
                        for ratio in [0.15, 0.333, 0.85, 0.5] {
                            model.setSplitRatio(ratio)
                            try ModelValidation.validRegions(model)
                        }
                    } else {
                        model.selectRegion(.secondary)
                        try ModelValidation.require(model.selectedRegion == .primary,
                                                    "Single mode retained an unavailable B selection")
                    }
                    try ModelValidation.validRegions(model)
                }
            }
        }
        print("1080p/1440p, portrait/landscape, and every layout preserve positive, contained frames with exact destination aspects.")
    }

    @MainActor
    private static func validateSecondaryMetadata() throws {
        let model = try ModelValidation.makeModel()
        model.setLayout(.stacked)
        model.selectRegion(.secondary)
        model.setFrameHeight(320)
        let frame = model.secondaryCaptureFrame
        let originalDisplay = model.selectedDisplayID
        model.setLayout(.single)
        let defaults = ModelValidation.defaults
        try ModelValidation.require(defaults.double(forKey: "secondaryFrameHeight") == frame.height &&
                                    defaults.double(forKey: "secondaryFrameWidth") == frame.width,
                                    "Single mode discarded B's saved shape")
        let other = DisplayChoice(id: 0xC0A2, name: "Other synthetic display", frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900), scale: 1)
        model.displays.append(other)
        model.selectDisplay(other.id)
        try ModelValidation.require(defaults.integer(forKey: "secondaryFrameDisplayID") == Int(originalDisplay),
                                    "Switching displays associated old B coordinates with the new display")
        print("Saved B metadata retains width/height in Single mode and remains associated with its original display.")
    }

    @MainActor
    private static func validateLayoutScaleRoundtrip() async throws {
        // Large bounds avoid display clamping, isolating unwanted zoom changes.
        // A uses 0.5 screen points per output pixel; B independently uses 0.375.
        let model = try ModelValidation.makeModel(width: 2600, height: 1800)
        model.setLayout(.stacked)
        model.setFrameWidth(720)
        model.selectRegion(.secondary)
        model.setFrameWidth(540)
        let first = model.captureFrame.size, second = model.secondaryCaptureFrame.size
        model.setLayout(.single)
        try ModelValidation.equalSize(model.captureFrame.size, CGSize(width: 720, height: 1280), "A scale entering single mode")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, second, "Single mode retains the hidden B frame")
        model.setLayout(.stacked)
        try ModelValidation.equalSize(model.captureFrame.size, first, "A scale after returning from single mode")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, second, "B scale after returning from single mode")
        model.setLayout(.single)
        model.setLayout(.stacked)
        try ModelValidation.equalSize(model.captureFrame.size, first, "A repeated layout roundtrip")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, second, "B repeated layout roundtrip")
        await model.setOrientation(.landscape)
        try ModelValidation.equalSize(model.captureFrame.size, CGSize(width: 1280, height: 360), "A scale entering landscape")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, CGSize(width: 960, height: 270), "B scale entering landscape")
        await model.setOrientation(.portrait)
        try ModelValidation.equalSize(model.captureFrame.size, first, "A orientation roundtrip")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, second, "B orientation roundtrip")
        try ModelValidation.validRegions(model)
        print("Layout/orientation roundtrips preserve independent A/B screen-points-per-output-pixel scales, including a visit to single mode.")
    }

    @MainActor
    private static func validateCameraDefaultsAndOverlay() async throws {
        let model = try ModelValidation.makeModel()
        try ModelValidation.require(model.cameraPlacement == .off && !model.cameraConfiguration.isEnabled,
                                    "A fresh model unexpectedly enabled its camera")
        try ModelValidation.require(model.selectedCameraID.isEmpty && model.cameras.isEmpty,
                                    "Fresh model construction unexpectedly discovered or selected a camera")
        model.setLayout(.stacked)
        model.selectedMicrophoneID = "synthetic-model-microphone"
        let first = model.captureFrame, second = model.secondaryCaptureFrame
        let outputSize = model.outputSize
        await model.setCameraDevice("synthetic-model-camera-A")
        try ModelValidation.require(model.cameraPlacement == .off && !model.cameraConfiguration.isEnabled,
                                    "Choosing a camera device enabled it while placement was Off")
        await model.setCameraPlacement(.overlay)
        try ModelValidation.require(model.cameraPlacement == .overlay && model.cameraConfiguration.isEnabled,
                                    "Floating overlay did not retain the chosen camera configuration")
        try ModelValidation.require(model.captureFrame == first && model.secondaryCaptureFrame == second,
                                    "Enabling a floating camera overlay moved or resized a screen region")
        try ModelValidation.require(model.outputSize == outputSize && model.layout == .stacked,
                                    "Enabling a camera overlay changed the output canvas or layout")
        try ModelValidation.require(model.selectedMicrophoneID == "synthetic-model-microphone",
                                    "Enabling the camera substituted the chosen microphone")
        model.setMirrorsCamera(false)
        try ModelValidation.require(!model.mirrorsCamera && !model.cameraConfiguration.mirrored,
                                    "Mirror control did not propagate to camera configuration")
        await model.setCameraDevice("synthetic-model-camera-B")
        try ModelValidation.require(model.cameraConfiguration.deviceID == "synthetic-model-camera-B"
                                    && model.cameraPlacement == .overlay,
                                    "Changing a camera device lost placement or retained the old device")
        try ModelValidation.require(model.cameras.isEmpty && !model.requestingCamera && !model.showOnboarding,
                                    "Idle camera settings unexpectedly discovered devices or began onboarding")
        try ModelValidation.validRegions(model)
        print("Camera defaults/overlay: Off on first use; device, mirror, and placement settings preserve both screen regions, output, and microphone without opening inputs.")
    }

    @MainActor
    private static func validateCameraRegionTransitions() async throws {
        for orientation in [CaptureOrientation.portrait, .landscape] {
            let model = try ModelValidation.makeModel()
            await model.setOrientation(orientation)
            await model.setCameraDevice("synthetic-model-camera")
            model.setLayout(.stacked)
            let first = model.captureFrame, second = model.secondaryCaptureFrame
            for placement in [CameraPlacement.overlay, .regionA, .regionB, .off] {
                await model.setCameraPlacement(placement)
                try ModelValidation.require(model.cameraPlacement == placement,
                                            "Split layout changed requested camera placement")
                try ModelValidation.require(model.isCameraRegion(.primary) == (placement == .regionA)
                                            && model.isCameraRegion(.secondary) == (placement == .regionB),
                                            "Camera replacement identified the wrong screen region")
                if placement == .regionA || placement == .regionB {
                    model.selectRegion(placement == .regionA ? .primary : .secondary)
                    try ModelValidation.require(model.activeRegionIsCamera,
                                                "Selected camera region was exposed as a screen region")
                    let before = model.activeCaptureFrame
                    model.setFrameWidth(before.width * 0.75)
                    model.setFrameHeight(before.height * 0.75)
                    try ModelValidation.require(model.activeCaptureFrame == before,
                                                "Screen-size setters resized a camera-backed region")
                }
                try ModelValidation.require(model.captureFrame == first && model.secondaryCaptureFrame == second,
                                            "Camera placement discarded or altered the saved screen rectangles")
                try ModelValidation.validRegions(model)
            }
            try ModelValidation.require(!model.activeRegionIsCamera,
                                        "Turning camera Off did not restore the selected screen region")
            await model.setCameraPlacement(.regionB)
            model.setLayout(.single)
            try ModelValidation.require(model.cameraPlacement == .overlay && !model.hasTwoRegions
                                        && model.selectedRegion == .primary && !model.activeRegionIsCamera,
                                        "Single layout did not safely convert the camera region into a floating overlay")
            try ModelValidation.validRegions(model)
            for placement in [CameraPlacement.regionA, .regionB] {
                await model.setCameraPlacement(placement)
                try ModelValidation.require(model.cameraPlacement == .overlay,
                                            "Single layout accepted an unavailable camera replacement region")
                try ModelValidation.validRegions(model)
            }
            await model.setCameraPlacement(.off)
        }
        print("Camera regions: A/B replacement preserves hidden screen rectangles, rejects screen resizing, restores them when Off, and converts to an overlay in Single mode across both orientations.")
    }

    @MainActor
    private static func validateCameraOverlayPersistence() async throws {
        let model = try ModelValidation.makeModel()
        await model.setCameraDevice("synthetic-persisted-camera")
        await model.setCameraPlacement(.overlay)
        model.setMirrorsCamera(false)
        for shape in CameraShape.allCases {
            model.setCameraOverlay(CameraOverlayConfiguration(center: CGPoint(x: -10, y: 10),
                                                               widthFraction: 4, shape: shape))
            try validateCameraRect(model, label: "Out-of-bounds \(shape.title)")
            try ModelValidation.require(model.cameraOverlay.widthFraction == 0.65,
                                        "Oversized camera overlay did not clamp to its maximum size")
            model.setCameraOverlay(CameraOverlayConfiguration(center: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
                                                               widthFraction: .nan, shape: shape))
            try validateCameraRect(model, label: "Nonfinite \(shape.title)")
            await model.setOrientation(.landscape)
            try validateCameraRect(model, label: "Landscape \(shape.title)")
            await model.setOrientation(.portrait)
        }
        model.setCameraOverlay(CameraOverlayConfiguration(center: CGPoint(x: 0.32, y: 0.68),
                                                           widthFraction: 0.42, shape: .roundedRectangle))
        let expected = model.cameraOverlay
        let restored = RecorderModel()
        try ModelValidation.require(restored.cameraOverlay == expected && restored.cameraPlacement == .overlay
                                    && restored.selectedCameraID == "synthetic-persisted-camera" && !restored.mirrorsCamera,
                                    "Camera placement, position, size, shape, device, or mirror setting did not survive model recreation")
        try validateCameraRect(restored, label: "Restored overlay")
        try ModelValidation.require(!restored.isPreviewing && !restored.isRecording && !restored.isFrameVisible
                                    && !restored.requestingCamera && restored.cameras.isEmpty,
                                    "Restoring camera settings opened an input, window, or permission request")
        try ModelValidation.validRegions(model)
        print("Camera overlay persistence: shape, device, mirroring, position, and size survive recreation; invalid coordinates and sizes remain within portrait/landscape output bounds.")
    }

    @MainActor
    private static func validateLegacyLayoutMigration() throws {
        let defaults = ModelValidation.defaults
        defaults.removePersistentDomain(forName: ModelValidation.suite)
        defaults.set("sideBySide", forKey: "captureLayout")
        defaults.set(0.35, forKey: "splitRatio")
        defaults.set("synthetic-legacy-camera", forKey: "cameraID")
        defaults.set(CameraPlacement.regionB.rawValue, forKey: "cameraPlacement")
        defaults.set("synthetic-legacy-microphone", forKey: "microphoneID")
        defaults.set(223.5, forKey: "frameWidth")
        defaults.set(706.0, forKey: "secondaryFrameWidth")
        defaults.set(564.8, forKey: "secondaryFrameHeight")
        defaults.set(-310.0, forKey: "secondaryFrameX")
        defaults.set(240.0, forKey: "secondaryFrameY")
        defaults.set(0xC0A1, forKey: "secondaryFrameDisplayID")
        let savedKeys = ["frameWidth", "secondaryFrameWidth", "secondaryFrameHeight",
                         "secondaryFrameX", "secondaryFrameY", "secondaryFrameDisplayID"]
        let savedGeometry = savedKeys.map { defaults.double(forKey: $0) }
        let model = RecorderModel()
        try ModelValidation.require(CaptureLayout.allCases == [.single, .stacked],
                                    "The retired layout is still exposed as an available option")
        try ModelValidation.require(model.layout == .stacked && model.hasTwoRegions
                                    && model.cameraPlacement == .regionB && model.splitRatio == 0.35,
                                    "Legacy layout migration lost the stacked split or camera's B region")
        try ModelValidation.require(defaults.string(forKey: "captureLayout") == CaptureLayout.stacked.rawValue,
                                    "Legacy layout was not migrated durably in preferences")
        try ModelValidation.require(savedKeys.map { defaults.double(forKey: $0) } == savedGeometry,
                                    "Layout migration discarded saved source geometry before a display can restore it")
        try ModelValidation.require(model.selectedCameraID == "synthetic-legacy-camera"
                                    && model.selectedMicrophoneID == "synthetic-legacy-microphone",
                                    "Layout migration changed selected input devices")
        let restored = RecorderModel()
        try ModelValidation.require(restored.layout == .stacked && restored.cameraPlacement == .regionB,
                                    "Migrated layout or camera placement did not survive recreation")
        try ModelValidation.require(!model.isPreviewing && !model.isRecording && !model.isFrameVisible
                                    && !model.requestingCamera && model.cameras.isEmpty,
                                    "Migration opened an input, window, or permission request")
        print("Legacy layout: old saved two-column takes reopen as Stacked, preserve the camera panel and source geometry, and save the supported layout.")
    }

    @MainActor
    private static func validateCameraFraming() async throws {
        let model = try ModelValidation.makeModel()
        try ModelValidation.require(model.cameraFraming == CameraFramingConfiguration()
                                    && model.cameraConfiguration.framing == model.cameraFraming,
                                    "A fresh camera must start with its default, centered framing")
        try ModelValidation.equalSize(model.cameraSourceSize, CGSize(width: 1920, height: 1080),
                                      "Camera framing's source-size fallback")
        model.setLayout(.stacked)
        model.selectedMicrophoneID = "synthetic-crop-microphone"
        model.microphoneChannel = 1
        await model.setCameraDevice("synthetic-crop-camera")
        model.setCameraOverlay(CameraOverlayConfiguration(center: CGPoint(x: 0.32, y: 0.68),
                                                           widthFraction: 0.42, shape: .roundedRectangle))
        let first = model.captureFrame, second = model.secondaryCaptureFrame
        let output = model.outputSize, overlay = model.cameraOverlay
        let overlayRect = overlay.rect(in: output)
        let fps = model.framesPerSecond
        let framing = CameraFramingConfiguration(zoom: 2.4, center: CGPoint(x: 0.61, y: 0.42))
        for placement in [CameraPlacement.overlay, .regionA, .regionB, .off] {
            await model.setCameraPlacement(placement)
            model.setCameraFraming(framing)
            try ModelValidation.require(model.cameraFraming == framing
                                        && model.cameraConfiguration.framing == framing,
                                        "Camera framing did not propagate in \(placement.title) mode")
            try ModelValidation.require(model.captureFrame == first && model.secondaryCaptureFrame == second
                                        && model.cameraOverlay == overlay
                                        && model.cameraOverlay.rect(in: output) == overlayRect,
                                        "Cropping camera content moved or resized a screen source or overlay frame")
            try ModelValidation.require(model.outputSize == output && model.layout == .stacked
                                        && model.framesPerSecond == fps
                                        && model.selectedMicrophoneID == "synthetic-crop-microphone"
                                        && model.microphoneChannel == 1,
                                        "Camera framing changed the output, layout, frame rate, or microphone")
            try ModelValidation.validRegions(model)
        }
        let unmirrored = CameraFramingConfiguration(zoom: 2, center: CGPoint(x: 0.25, y: 0.6))
        model.setCameraFraming(unmirrored)
        model.setMirrorsCamera(false)
        let mirroredCenter = CameraFramingConfiguration(zoom: 2, center: CGPoint(x: 0.75, y: 0.6))
        try ModelValidation.require(model.cameraFraming == mirroredCenter,
                                    "Changing mirroring did not reflect the crop center to preserve the same subject")
        model.setMirrorsCamera(false)
        try ModelValidation.require(model.cameraFraming == mirroredCenter,
                                    "Reapplying the same mirror setting moved the crop center again")
        model.setMirrorsCamera(true)
        try ModelValidation.require(model.cameraFraming == unmirrored,
                                    "Mirror roundtrip did not restore the original focal point")
        model.setCameraFraming(framing)
        let restored = RecorderModel()
        try ModelValidation.require(restored.cameraFraming == framing
                                    && restored.cameraConfiguration.framing == framing,
                                    "Camera zoom and crop center did not survive model recreation")
        let defaults = ModelValidation.defaults
        try ModelValidation.require(defaults.double(forKey: "cameraZoom") == framing.zoom
                                    && defaults.double(forKey: "cameraCropCenterX") == framing.center.x
                                    && defaults.double(forKey: "cameraCropCenterY") == framing.center.y,
                                    "Camera framing preferences do not describe the requested crop")
        model.setCameraFraming(CameraFramingConfiguration(zoom: 20, center: CGPoint(x: -5, y: 6)))
        try ModelValidation.require(model.cameraFraming.zoom == 4 && model.cameraFraming.center == CGPoint(x: 0, y: 1),
                                    "Camera zoom or center exceeded supported bounds")
        model.setCameraFraming(CameraFramingConfiguration(zoom: -2, center: CGPoint(x: 0.3, y: 0.6)))
        try ModelValidation.require(model.cameraFraming.zoom == 1 && model.cameraFraming.center == CGPoint(x: 0.3, y: 0.6),
                                    "Negative zoom was not clamped independently of a valid crop center")
        model.setCameraFraming(CameraFramingConfiguration(zoom: .nan, center: CGPoint(x: CGFloat.infinity, y: CGFloat.nan)))
        try ModelValidation.require(model.cameraFraming == CameraFramingConfiguration(),
                                    "Nonfinite camera framing did not reset to safe defaults")
        model.setCameraFraming(framing)
        model.setCameraFraming(CameraFramingConfiguration())
        let reset = RecorderModel()
        try ModelValidation.require(reset.cameraFraming == CameraFramingConfiguration()
                                    && reset.cameraConfiguration.framing == reset.cameraFraming,
                                    "Reset framing did not durably restore the default zoom and center")
        defaults.set(100.0, forKey: "cameraZoom")
        defaults.set(-100.0, forKey: "cameraCropCenterX")
        defaults.set(100.0, forKey: "cameraCropCenterY")
        let clamped = RecorderModel()
        try ModelValidation.require(clamped.cameraFraming.zoom == 4
                                    && clamped.cameraFraming.center == CGPoint(x: 0, y: 1),
                                    "Restoring invalid camera preferences did not clamp the crop")
        for instance in [model, restored, reset, clamped] {
            try ModelValidation.require(!instance.isPreviewing && !instance.isRecording && !instance.isFrameVisible
                                        && !instance.requestingCamera && instance.cameras.isEmpty,
                                        "Camera framing settings unexpectedly opened an input or visible window")
        }
        try ModelValidation.validRegions(model)
        print("Camera framing: zoom and pan work in all placements, persist and reset, clamp invalid settings, and leave source/overlay geometry, output, and microphone unchanged.")
    }

    @MainActor
    private static func validateCameraRect(_ model: RecorderModel, label: String) throws {
        let frame = model.cameraOverlay.rect(in: model.outputSize)
        let canvas = CGRect(origin: .zero, size: model.outputSize).insetBy(dx: -0.001, dy: -0.001)
        try ModelValidation.require(frame.width.isFinite && frame.height.isFinite
                                    && frame.width > 0 && frame.height > 0 && canvas.contains(frame),
                                    "\(label): camera overlay is empty, nonfinite, or outside the output")
        let expectedAspect: CGFloat = model.cameraOverlay.shape == .circle ? 1 : 4.0 / 3.0
        try ModelValidation.require(abs(frame.width / frame.height - expectedAspect) < 0.000001,
                                    "\(label): camera shape aspect ratio changed")
    }
}
