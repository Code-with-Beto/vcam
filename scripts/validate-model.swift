// Run from the project root. The temporary source copy redirects preferences to
// this validator's UUID-named suite; production source and app preferences stay intact.
// sed 's/UserDefaults\.standard/ModelValidation.defaults/g' vcam/RecorderModel.swift \
//   > /tmp/vcam-model-validation-source.swift
// xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 \
//   vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
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
            try await validateSideBySideClamping()
            try validateStackedClamping()
            try validateIndependentResize()
            try await validateLayoutTransitions()
            try await validateLayoutScaleRoundtrip()
            try validateSecondaryMetadata()
            try ModelValidation.require(application.windows.allSatisfy { !$0.isVisible },
                                        "Validation unexpectedly displayed a window")
            print("PASS: Model split roundtrips, display clamping, independent B sizing, layout/orientation aspects, and secondary persistence metadata. Preferences used an isolated temporary suite.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func validateNarrowSplit() throws {
        let model = try ModelValidation.makeModel()
        model.setLayout(.sideBySide)
        let first = model.captureFrame, second = model.secondaryCaptureFrame
        model.setSplitRatio(0.15)
        try ModelValidation.equalSize(model.captureFrame.size, CGSize(width: 54, height: 640),
                                      "A narrow split must not impose a 144-point minimum")
        try ModelValidation.validRegions(model)
        model.setSplitRatio(0.85)
        model.setSplitRatio(0.5)
        try ModelValidation.equalSize(model.captureFrame.size, first.size, "Narrow A roundtrip")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, second.size, "Narrow B roundtrip")
        try ModelValidation.validRegions(model)
        print("Narrow split: A 180×640 → 54×640 → 180×640; B restores its size.")
    }

    @MainActor
    private static func validateSideBySideClamping() async throws {
        let model = try ModelValidation.makeModel(width: 1000, height: 900)
        await model.setOrientation(.landscape)
        model.setLayout(.sideBySide)
        model.setFrameHeight(800)
        model.selectRegion(.secondary)
        model.setFrameHeight(600)
        model.selectRegion(.primary)
        let first = model.captureFrame.size, second = model.secondaryCaptureFrame.size
        model.setSplitRatio(0.85)
        try ModelValidation.require(model.captureFrame.height < first.height - 1,
                                    "Side-by-side fixture did not exercise display clamping")
        for ratio in [0.15, 0.5, 0.85, 0.15, 0.5] {
            model.setSplitRatio(ratio)
            try ModelValidation.validRegions(model)
        }
        try ModelValidation.equalSize(model.captureFrame.size, first, "Display-clamped side-by-side A roundtrip")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, second, "Display-clamped side-by-side B roundtrip")
        print("Side-by-side clamp: repeated 15–85% changes restore A's 800pt and B's 600pt heights.")
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
        for layout in [CaptureLayout.sideBySide, .stacked] {
            let model = try ModelValidation.makeModel()
            model.setLayout(layout)
            let first = model.captureFrame
            model.selectRegion(.secondary)
            model.setFrameHeight(400)
            try ModelValidation.require(model.captureFrame == first, "Resizing B changed A in \(layout.title)")
            try ModelValidation.require(abs(model.secondaryCaptureFrame.height - 400) < 0.001,
                                        "The height entry did not resize selected B")
            let resized = model.secondaryCaptureFrame.size
            model.setSplitRatio(0.15)
            model.setSplitRatio(0.5)
            try ModelValidation.equalSize(model.secondaryCaptureFrame.size, resized, "Explicit B scale after divider roundtrip")
            try ModelValidation.validRegions(model)
        }
        print("Region selection: explicit B sizing leaves A unchanged and establishes B's new split scale.")
    }

    @MainActor
    private static func validateLayoutTransitions() async throws {
        for resolution in OutputResolution.allCases {
            let model = try ModelValidation.makeModel(resolution: resolution)
            for orientation in [CaptureOrientation.portrait, .landscape, .portrait] {
                await model.setOrientation(orientation)
                for layout in [CaptureLayout.single, .sideBySide, .stacked, .single] {
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
        model.setLayout(.sideBySide)
        try ModelValidation.equalSize(model.captureFrame.size, CGSize(width: 360, height: 1280), "A scale through stacked → side by side")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, CGSize(width: 270, height: 960), "B scale through stacked → side by side")
        model.setLayout(.stacked)
        try ModelValidation.equalSize(model.captureFrame.size, first, "A layout roundtrip")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, second, "B layout roundtrip")
        model.setLayout(.sideBySide)
        model.setLayout(.single)
        try ModelValidation.equalSize(model.captureFrame.size, CGSize(width: 720, height: 1280), "A scale entering single mode")
        model.setLayout(.sideBySide)
        try ModelValidation.equalSize(model.captureFrame.size, CGSize(width: 360, height: 1280), "A side-by-side scale after single mode")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, CGSize(width: 270, height: 960), "B side-by-side scale after single mode")
        model.setLayout(.stacked)
        try ModelValidation.equalSize(model.captureFrame.size, first, "A scale after returning from single mode")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, second, "B scale after returning from single mode")
        await model.setOrientation(.landscape)
        try ModelValidation.equalSize(model.captureFrame.size, CGSize(width: 1280, height: 360), "A scale entering landscape")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, CGSize(width: 960, height: 270), "B scale entering landscape")
        await model.setOrientation(.portrait)
        try ModelValidation.equalSize(model.captureFrame.size, first, "A orientation roundtrip")
        try ModelValidation.equalSize(model.secondaryCaptureFrame.size, second, "B orientation roundtrip")
        try ModelValidation.validRegions(model)
        print("Layout/orientation roundtrips preserve independent A/B screen-points-per-output-pixel scales, including a visit to single mode.")
    }
}
