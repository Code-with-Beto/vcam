import AppKit
import AVFoundation
import CoreGraphics
import Observation
import UniformTypeIdentifiers

struct DisplayChoice: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat
}

struct MicrophoneChoice: Identifiable {
    let id: String
    let name: String
    let channels: Int
}

struct CameraChoice: Identifiable {
    let id: String
    let name: String
}

enum CaptureRegion: String, CaseIterable, Identifiable {
    case primary, secondary, tertiary
    var id: String { rawValue }
    var index: Int {
        switch self {
        case .primary: 0
        case .secondary: 1
        case .tertiary: 2
        }
    }
}

@MainActor
@Observable
final class RecorderModel {
    var displays: [DisplayChoice] = []
    var microphones: [MicrophoneChoice] = []
    private(set) var cameras: [CameraChoice] = []
    private(set) var selectedCameraID: String = ""
    private(set) var cameraPlacement: CameraPlacement = .off
    private(set) var cameraOverlay = CameraOverlayConfiguration()
    private(set) var cameraFraming = CameraFramingConfiguration()
    private(set) var cameraSourceSize = CGSize(width: 1920, height: 1080)
    var isAdjustingCameraCrop = false
    private(set) var mirrorsCamera = true
    private(set) var cameraAuthorization = AVAuthorizationStatus.notDetermined
    private(set) var requestingCamera = false
    var selectedDisplayID: CGDirectDisplayID = 0
    var selectedMicrophoneID: String {
        didSet { UserDefaults.standard.set(selectedMicrophoneID, forKey: "microphoneID") }
    }
    var framesPerSecond: Int {
        didSet { UserDefaults.standard.set(framesPerSecond, forKey: "framesPerSecond") }
    }
    var showsCursor: Bool {
        didSet { UserDefaults.standard.set(showsCursor, forKey: "showsCursor") }
    }
    var showsGuides: Bool {
        didSet {
            UserDefaults.standard.set(showsGuides, forKey: "showsGuides")
            refreshOverlay()
        }
    }
    var reservesCaptions: Bool = false {
        didSet { UserDefaults.standard.set(reservesCaptions, forKey: "reservesCaptions"); refreshOverlay() }
    }
    private(set) var orientation: CaptureOrientation = .portrait {
        didSet { UserDefaults.standard.set(orientation.rawValue, forKey: "orientation") }
    }
    var resolution: OutputResolution = .qhd {
        didSet {
            UserDefaults.standard.set(resolution.rawValue, forKey: "resolution")
            if hasPrepared {
                refitFrames()
                saveFramePosition()
                refreshOverlay()
            }
        }
    }
    var microphoneChannel = -1 {
        didSet { UserDefaults.standard.set(microphoneChannel, forKey: "microphoneChannel") }
    }
    var showOnboarding = false
    private(set) var screenAccessGranted = false
    private(set) var microphoneAuthorization = AVAuthorizationStatus.notDetermined
    private(set) var requestingMicrophone = false
    private(set) var requestedScreenAccess = false
    var frameWidth: Double
    private(set) var captureFrame = CGRect.zero
    private(set) var secondaryCaptureFrame = CGRect.zero
    private(set) var tertiaryCaptureFrame = CGRect.zero
    private(set) var layout: CaptureLayout = .single
    private(set) var splitRatio: Double = 0.5
    private(set) var secondSplitRatio: Double = 2.0 / 3.0
    private(set) var selectedRegion: CaptureRegion = .primary
    private(set) var isFrameVisible = false
    private(set) var isPreviewing = false {
        didSet { if !isPreviewing { isAdjustingCameraCrop = false } }
    }
    private(set) var isRecording = false
    private(set) var isBusy = false {
        didSet {
            refreshOverlay()
            if !isBusy {
                let waiters = transitionWaiters
                transitionWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    }
    @ObservationIgnored let previewSurface = CameraPreviewSurface()
    private(set) var audioLevel: Float = 0
    private(set) var audioDecibels: Float = -120
    private(set) var activeMicrophoneChannel: Int?
    private(set) var elapsedSeconds = 0
    private(set) var outputFolder: URL?
    private(set) var lastRecording: URL?
    var errorMessage: String?
    var notice: String?
    @ObservationIgnored var commitFrameEdits: (() -> Void)?

    @ObservationIgnored private let engine = CaptureEngine()
    @ObservationIgnored private let overlay = FrameOverlayController()
    @ObservationIgnored private let secondaryOverlay = FrameOverlayController()
    @ObservationIgnored private let tertiaryOverlay = FrameOverlayController()
    @ObservationIgnored private var shortcuts: GlobalShortcuts?
    @ObservationIgnored private var displayObserver: NSObjectProtocol?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var recordingStart: Date?
    @ObservationIgnored private var securityScopedFolder: URL?
    @ObservationIgnored private var lastRecordingFolder: URL?
    @ObservationIgnored private var hasPrepared = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var displayRevision = 0
    @ObservationIgnored private var captureRevision = 0
    // Keep the requested scale when a split temporarily runs into a display edge.
    // Returning the divider restores that scale instead of accumulating zoom changes.
    @ObservationIgnored private var primarySplitExtent: CGFloat = 0
    @ObservationIgnored private var secondarySplitExtent: CGFloat = 0
    @ObservationIgnored private var tertiarySplitExtent: CGFloat = 0
    @ObservationIgnored private var secondaryOutputCell: CGRect?
    @ObservationIgnored private var tertiaryOutputCell: CGRect?
    @ObservationIgnored private var twoRegionSplitRatio: Double = 0.5
    @ObservationIgnored private var threeRegionSplitRatio: Double = 1.0 / 3.0

    init() {
        let defaults = UserDefaults.standard
        selectedMicrophoneID = defaults.string(forKey: "microphoneID") ?? "__system_default__"
        if !defaults.bool(forKey: "defaultsV2") {
            defaults.set(30, forKey: "framesPerSecond")
            defaults.set(true, forKey: "defaultsV2")
        }
        framesPerSecond = defaults.integer(forKey: "framesPerSecond") == 60 ? 60 : 30
        showsCursor = defaults.object(forKey: "showsCursor") as? Bool ?? true
        showsGuides = defaults.object(forKey: "showsGuides") as? Bool ?? true
        frameWidth = defaults.object(forKey: "frameWidth") as? Double ?? 360
        orientation = CaptureOrientation(rawValue: defaults.string(forKey: "orientation") ?? "") ?? .portrait
        let savedLayout = defaults.string(forKey: "captureLayout") ?? ""
        // Preserve two sources when opening a setup saved before the horizontal
        // layout was removed. Subsequent launches use the supported stacked layout.
        layout = savedLayout == "sideBySide" ? .stacked : CaptureLayout(rawValue: savedLayout) ?? .single
        if savedLayout == "sideBySide" { defaults.set(layout.rawValue, forKey: "captureLayout") }
        let savedSplit = defaults.object(forKey: "splitRatio") as? Double
        twoRegionSplitRatio = CaptureLayout.clampedSplitRatio(
            defaults.object(forKey: "twoRegionSplitRatio") as? Double
                ?? (layout == .stackedThree ? 0.5 : savedSplit ?? 0.5))
        let triple = CaptureLayout.clampedTripleSplits(
            first: defaults.object(forKey: "threeRegionSplitRatio") as? Double
                ?? (layout == .stackedThree ? savedSplit ?? 1.0 / 3.0 : 1.0 / 3.0),
            second: defaults.object(forKey: "secondSplitRatio") as? Double ?? 2.0 / 3.0)
        threeRegionSplitRatio = triple.first
        secondSplitRatio = triple.second
        splitRatio = layout == .stackedThree ? triple.first : twoRegionSplitRatio
        resolution = OutputResolution(rawValue: defaults.integer(forKey: "resolution")) ?? .qhd
        reservesCaptions = defaults.bool(forKey: "reservesCaptions")
        microphoneChannel = defaults.object(forKey: "microphoneChannel") as? Int ?? -1
        selectedCameraID = defaults.string(forKey: "cameraID") ?? ""
        cameraPlacement = CameraPlacement(rawValue: defaults.string(forKey: "cameraPlacement") ?? "") ?? .off
        if layout == .single && cameraPlacement != .off && cameraPlacement != .overlay { cameraPlacement = .overlay }
        if layout == .stacked && cameraPlacement == .regionC { cameraPlacement = .regionB }
        mirrorsCamera = defaults.object(forKey: "mirrorsCamera") as? Bool ?? true
        cameraOverlay = CameraOverlayConfiguration(
            center: CGPoint(x: defaults.object(forKey: "cameraCenterX") as? Double ?? 0.78,
                            y: defaults.object(forKey: "cameraCenterY") as? Double ?? 0.20),
            widthFraction: defaults.object(forKey: "cameraWidthFraction") as? Double ?? 0.30,
            shape: CameraShape(rawValue: defaults.string(forKey: "cameraShape") ?? "") ?? .circle)
        cameraOverlay = cameraOverlay.clamped(in: outputSize)
        cameraFraming = CameraFramingConfiguration(
            zoom: defaults.object(forKey: "cameraZoom") as? Double ?? 1,
            center: CGPoint(x: defaults.object(forKey: "cameraCropCenterX") as? Double ?? 0.5,
                            y: defaults.object(forKey: "cameraCropCenterY") as? Double ?? 0.5)).clamped()
        restoreOutputFolder()
        engine.onCameraSourceSize = { [weak self] size in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
            self?.cameraSourceSize = size
        }
        engine.onPreviewPixelBuffer = { [weak self] buffer in self?.previewSurface.display(buffer) }
        engine.onAudioDecibels = { [weak self] level in self?.audioDecibels = level }
        engine.onAudioChannel = { [weak self] channel in self?.activeMicrophoneChannel = channel }
        engine.onAudioLevel = { [weak self] level in self?.audioLevel = level }
        engine.onFailure = { [weak self] message in
            guard let self else { return }
            Task { await self.handleCaptureFailure(message) }
        }
        engine.onCameraFailure = { [weak self] message in
            guard let self else { return }
            self.cameraPlacement = .off
            self.isAdjustingCameraCrop = false
            self.saveCameraSettings()
            if self.isFrameVisible { self.showFrame() }
            self.notice = message + (self.isRecording ? " Screen and microphone recording continue." : " Choose a camera to try again.")
        }
        for region in CaptureRegion.allCases {
            let handle = frameOverlay(for: region)
            handle.onFrameChanged = { [weak self] rect in
                guard let self else { return }
                self.setCaptureFrame(rect, for: region)
                self.updateComposition()
                self.saveFramePosition()
            }
            handle.onSelect = { [weak self] in self?.selectRegion(region) }
            handle.onToggleRecording = { [weak self] in Task { await self?.toggleRecording() } }
            handle.onHide = { [weak self] in self?.toggleFrame() }
            handle.onCancelRecording = { [weak self] in Task { await self?.cancelRecording() } }
            handle.onRestartRecording = { [weak self] in Task { await self?.restartRecording() } }
        }
    }

    var outputSize: CGSize { resolution.size(for: orientation) }
    var outputDimensions: String { "\(Int(outputSize.width)) × \(Int(outputSize.height))" }
    var guideBottomInset: CGFloat { reservesCaptions ? 0.20 : 0.08 }
    var microphoneChannels: Int { microphones.first { $0.id == selectedMicrophoneID }?.channels ?? 1 }
    var decibelText: String { audioDecibels <= -100 ? "−∞ dBFS" : String(format: "%.1f dBFS", audioDecibels) }
    var permissionsReady: Bool {
        screenAccessGranted && (selectedMicrophoneID.isEmpty || microphoneAuthorization == .authorized)
            && (cameraPlacement == .off || cameraAuthorization == .authorized)
    }
    var cameraConfiguration: CameraConfiguration {
        CameraConfiguration(deviceID: selectedCameraID.isEmpty ? nil : selectedCameraID,
            placement: cameraPlacement, overlay: cameraOverlay, mirrored: mirrorsCamera, framing: cameraFraming)
    }
    var activeRegionIsCamera: Bool { isCameraRegion(selectedRegion) }
    func isCameraRegion(_ region: CaptureRegion) -> Bool {
        hasTwoRegions && activeRegions.contains(region) && ((region == .primary && cameraPlacement == .regionA)
            || (region == .secondary && cameraPlacement == .regionB)
            || (region == .tertiary && cameraPlacement == .regionC))
    }
    var selectedDisplay: DisplayChoice? { displays.first { $0.id == selectedDisplayID } }
    var hasTwoRegions: Bool { layout.regionCount >= 2 }
    var activeRegions: [CaptureRegion] { Array(CaptureRegion.allCases.prefix(layout.regionCount)) }
    var activeCaptureFrame: CGRect { captureFrame(for: selectedRegion) }
    var activeOutputRect: CGRect { destinationRect(for: selectedRegion) }
    var activeAspectRatio: CGFloat { activeOutputRect.width / max(activeOutputRect.height, 1) }
    var activeAspectLabel: String { hasTwoRegions ? "Matches output panel" : orientation.ratioLabel + " linked" }
    var splitDescription: String {
        let first = Int((splitRatio * 100).rounded())
        if layout == .stackedThree {
            let second = Int((secondSplitRatio * 100).rounded())
            return "A \(first)% · B \(second - first)% · C \(100 - second)%"
        }
        return "A \(first)% · B \(100 - first)%"
    }
    var splitRatioRange: ClosedRange<Double> { 0.15...(layout == .stackedThree ? max(secondSplitRatio - 0.15, 0.15) : 0.85) }
    var secondSplitRatioRange: ClosedRange<Double> { min(splitRatio + 0.15, 0.85)...0.85 }
    var minimumFrameWidth: Double { min(hasTwoRegions ? min(180, 180 * activeAspectRatio) : 180, maximumFrameWidth) }
    var elapsedText: String { String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60) }
    var maximumFrameWidth: Double {
        guard let display = selectedDisplay else { return 540 }
        return min(display.visibleFrame.width, display.visibleFrame.height * activeAspectRatio)
    }
    var sourceSizeText: String {
        guard let display = selectedDisplay else { return "Select a display" }
        let frame = activeCaptureFrame
        return "\(Int((frame.width * display.scale).rounded())) × \(Int((frame.height * display.scale).rounded())) source pixels"
    }
    var isUpscaling: Bool {
        guard let display = selectedDisplay else { return false }
        return activeCaptureFrame.width * display.scale < activeOutputRect.width - 1 || activeCaptureFrame.height * display.scale < activeOutputRect.height - 1
    }
    var statusText: String {
        if isBusy { return "Working…" }
        if isRecording { return "Recording  \(elapsedText)" }
        if isPreviewing { return "Live preview" }
        return "Ready to frame"
    }

    func prepare() {
        guard !hasPrepared else { return }
        hasPrepared = true
        refreshDevices()
        restoreFrame()
        refreshPermissions()
        showOnboarding = !permissionsReady
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak model = self] _ in
            Task { @MainActor [weak model] in model?.refreshPermissions() }
        }
        shortcuts = GlobalShortcuts(
            toggleRecording: { [weak self] in Task { await self?.toggleRecording() } },
            toggleFrame: { [weak self] in self?.toggleFrame() }
        )
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.screenConfigurationChanged() }
        }
    }

    func refreshPermissions() {
        screenAccessGranted = CGPreflightScreenCaptureAccess()
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
    }

    private func presentOnboardingIfNeeded() -> Bool {
        refreshPermissions()
        if !permissionsReady { showOnboarding = true; return true }
        return false
    }

    func requestScreenAccess() {
        requestedScreenAccess = true
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
        if !screenAccessGranted { openScreenPermissions() }
    }

    func requestMicrophoneAccess() async {
        guard !requestingMicrophone else { return }
        requestingMicrophone = true
        defer { requestingMicrophone = false }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            openMicrophonePermissions()
        }
        refreshPermissions()
    }

    func openMicrophonePermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestCameraAccess() async {
        guard !requestingCamera, !isBusy, !isShuttingDown else { return }
        requestingCamera = true
        defer { requestingCamera = false }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        } else if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            openCameraPermissions()
        }
        refreshPermissions()
        refreshCameras()
    }

    func openCameraPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
        cameras = discovery.devices.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
        // Preserve a missing selection so reconnecting never silently uses another camera.
        if selectedCameraID.isEmpty {
            selectedCameraID = AVCaptureDevice.default(for: .video)?.uniqueID ?? cameras.first?.id ?? ""
        }
    }

    func setCameraPlacement(_ value: CameraPlacement) async {
        let value: CameraPlacement = !hasTwoRegions && value != .off && value != .overlay ? .overlay
            : layout == .stacked && value == .regionC ? .regionB : value
        guard value != cameraPlacement else { return }
        await reconfigureCamera(placement: value, deviceID: selectedCameraID)
    }

    func setCameraDevice(_ id: String) async {
        guard !isRecording, id != selectedCameraID else { return }
        await reconfigureCamera(placement: cameraPlacement, deviceID: id)
    }

    private func reconfigureCamera(placement: CameraPlacement, deviceID: String) async {
        guard !isBusy && !isShuttingDown else { return }
        commitFrameEdits?()
        refreshPermissions()
        // A permission request must never tear down an ongoing screen take.
        // Idle selections still configure the next preview and its onboarding.
        if isPreviewing && placement != .off && cameraAuthorization != .authorized {
            notice = "Enable Camera access in Setup, then choose its placement. Your recording can keep running."
            return
        }
        isBusy = true
        defer { isBusy = false }
        if isPreviewing {
            let requested = CameraConfiguration(deviceID: deviceID.isEmpty ? nil : deviceID,
                placement: placement, overlay: cameraOverlay, mirrored: mirrorsCamera, framing: cameraFraming)
            do {
                try await engine.setCamera(requested)
            } catch {
                cameraPlacement = .off
                isAdjustingCameraCrop = false
                saveCameraSettings()
                if isFrameVisible { showFrame() }
                notice = error.localizedDescription + (isRecording ? " Your screen recording is still running." : "")
                return
            }
        }
        cameraPlacement = placement
        if placement == .off { isAdjustingCameraCrop = false }
        selectedCameraID = deviceID
        saveCameraSettings()
        if isFrameVisible { showFrame() }
    }

    func setCameraOverlay(_ value: CameraOverlayConfiguration) {
        guard !isBusy && !isShuttingDown else { return }
        cameraOverlay = value.clamped(in: outputSize)
        saveCameraSettings()
        engine.updateCamera(cameraConfiguration)
    }

    func setMirrorsCamera(_ value: Bool) {
        guard !isBusy && !isShuttingDown, value != mirrorsCamera else { return }
        mirrorsCamera = value
        // Center is measured in the displayed, mirrored source. Reflect it too
        // so flipping the image keeps the same subject inside a zoomed crop.
        cameraFraming.center.x = 1 - cameraFraming.center.x
        saveCameraSettings()
        engine.updateCamera(cameraConfiguration)
    }

    func setCameraFraming(_ value: CameraFramingConfiguration) {
        guard !isBusy && !isShuttingDown else { return }
        cameraFraming = value.clamped()
        saveCameraSettings()
        engine.updateCamera(cameraConfiguration)
    }

    private func saveCameraSettings() {
        let defaults = UserDefaults.standard
        defaults.set(selectedCameraID, forKey: "cameraID")
        defaults.set(cameraPlacement.rawValue, forKey: "cameraPlacement")
        defaults.set(mirrorsCamera, forKey: "mirrorsCamera")
        defaults.set(cameraOverlay.center.x, forKey: "cameraCenterX")
        defaults.set(cameraOverlay.center.y, forKey: "cameraCenterY")
        defaults.set(cameraOverlay.widthFraction, forKey: "cameraWidthFraction")
        defaults.set(cameraOverlay.shape.rawValue, forKey: "cameraShape")
        defaults.set(cameraFraming.zoom, forKey: "cameraZoom")
        defaults.set(cameraFraming.center.x, forKey: "cameraCropCenterX")
        defaults.set(cameraFraming.center.y, forKey: "cameraCropCenterY")
    }

    func setFrameWidth(_ width: Double) {
        guard width.isFinite, width > 0, !isBusy && !isShuttingDown, !activeRegionIsCamera else { return }
        frameWidth = width
        resizeFrame()
    }

    func setFrameHeight(_ height: Double) { setFrameWidth(height * activeAspectRatio) }

    func regionTitle(_ region: CaptureRegion) -> String {
        if layout == .single { return "Frame" }
        switch region {
        case .primary: return "A · Top"
        case .secondary: return layout == .stackedThree ? "B · Middle" : "B · Bottom"
        case .tertiary: return "C · Bottom"
        }
    }

    func selectRegion(_ region: CaptureRegion) {
        guard !isBusy, selectedRegion != region, activeRegions.contains(region) else { return }
        commitFrameEdits?()
        selectedRegion = region
        frameWidth = activeCaptureFrame.width
        refreshOverlay()
    }

    func setLayout(_ value: CaptureLayout) {
        guard !isBusy && !isShuttingDown, value != layout else { return }
        commitFrameEdits?()
        let previousCells = rememberedOutputCells
        layout = value
        splitRatio = value == .stackedThree ? threeRegionSplitRatio : twoRegionSplitRatio
        if value == .single && cameraPlacement != .off && cameraPlacement != .overlay {
            cameraPlacement = .overlay
            saveCameraSettings()
        } else if value == .stacked && cameraPlacement == .regionC {
            cameraPlacement = .regionB
            saveCameraSettings()
        }
        if !activeRegions.contains(selectedRegion) { selectedRegion = activeRegions.last ?? .primary }
        remapFrames(from: previousCells)
        saveFramePosition()
        updateComposition()
        if isFrameVisible { showFrame() }
    }

    func setSplitRatio(_ value: Double) {
        guard hasTwoRegions && !isBusy && !isShuttingDown, value.isFinite else { return }
        let value = min(max(value, splitRatioRange.lowerBound), splitRatioRange.upperBound)
        guard abs(value - splitRatio) > 0.0001 else { return }
        commitFrameEdits?()
        splitRatio = value
        if layout == .stackedThree { threeRegionSplitRatio = value }
        else { twoRegionSplitRatio = value }
        refitFrames(preserveSplitScale: true)
        saveFramePosition()
        updateComposition()
        refreshOverlay()
    }

    func setSecondSplitRatio(_ value: Double) {
        guard layout == .stackedThree && !isBusy && !isShuttingDown, value.isFinite else { return }
        let value = min(max(value, secondSplitRatioRange.lowerBound), secondSplitRatioRange.upperBound)
        guard abs(value - secondSplitRatio) > 0.0001 else { return }
        commitFrameEdits?()
        secondSplitRatio = value
        refitFrames(preserveSplitScale: true)
        saveFramePosition()
        updateComposition()
        refreshOverlay()
    }

    func equalizeSplit() {
        guard hasTwoRegions && !isBusy && !isShuttingDown else { return }
        commitFrameEdits?()
        if layout == .stackedThree {
            splitRatio = 1.0 / 3.0
            threeRegionSplitRatio = splitRatio
            secondSplitRatio = 2.0 / 3.0
        } else {
            splitRatio = 0.5
            twoRegionSplitRatio = splitRatio
        }
        refitFrames(preserveSplitScale: true)
        saveFramePosition()
        updateComposition()
        refreshOverlay()
    }

    private var rememberedOutputCells: [CGRect] {
        [destinationRect(for: .primary), secondaryOutputCell ?? destinationRect(for: .secondary),
         tertiaryOutputCell ?? destinationRect(for: .tertiary)]
    }

    private func captureFrame(for region: CaptureRegion) -> CGRect {
        switch region {
        case .primary: captureFrame
        case .secondary: secondaryCaptureFrame
        case .tertiary: tertiaryCaptureFrame
        }
    }

    private func setCaptureFrame(_ frame: CGRect, for region: CaptureRegion) {
        switch region {
        case .primary: captureFrame = frame
        case .secondary: secondaryCaptureFrame = frame
        case .tertiary: tertiaryCaptureFrame = frame
        }
    }

    private func splitExtent(for region: CaptureRegion) -> CGFloat {
        switch region {
        case .primary: primarySplitExtent
        case .secondary: secondarySplitExtent
        case .tertiary: tertiarySplitExtent
        }
    }

    private func setSplitExtent(_ width: CGFloat, for region: CaptureRegion) {
        switch region {
        case .primary: primarySplitExtent = width
        case .secondary: secondarySplitExtent = width
        case .tertiary: tertiarySplitExtent = width
        }
    }

    private func frameOverlay(for region: CaptureRegion) -> FrameOverlayController {
        switch region {
        case .primary: overlay
        case .secondary: secondaryOverlay
        case .tertiary: tertiaryOverlay
        }
    }

    private func regionAccent(_ region: CaptureRegion) -> NSColor {
        switch region {
        case .primary: .systemCyan
        case .secondary: .systemOrange
        case .tertiary: .systemPurple
        }
    }

    private func destinationRect(for region: CaptureRegion) -> CGRect {
        let rects = layout.destinationRects(in: outputSize, splitRatio: splitRatio, secondSplitRatio: secondSplitRatio)
        return region.index < rects.count ? rects[region.index] : rects[0]
    }

    private func remapFrames(from previousCells: [CGRect]) {
        func remap(_ frame: CGRect, region: CaptureRegion, previous: CGRect) -> CGRect {
            guard !frame.isEmpty else { return frame }
            let cell = destinationRect(for: region)
            let width = frame.width * cell.width / max(previous.width, 1)
            let height = frame.height * cell.height / max(previous.height, 1)
            return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        }
        for region in activeRegions {
            setCaptureFrame(remap(captureFrame(for: region), region: region, previous: previousCells[region.index]), for: region)
        }
        refitFrames()
    }

    private func fittedFrame(_ frame: CGRect, for region: CaptureRegion,
                             requestedExtent: CGFloat? = nil) -> CGRect {
        guard let display = selectedDisplay else { return frame }
        let cell = destinationRect(for: region)
        let aspect = cell.width / max(cell.height, 1)
        let width = requestedExtent ?? frame.width
        return CaptureGeometry.frame(width: width,
            centeredAt: CGPoint(x: frame.midX, y: frame.midY),
            within: frameBounds(for: display), aspectRatio: aspect, minimumWidth: 1)
    }

    private func refitFrames(preserveSplitScale: Bool = false) {
        guard let display = selectedDisplay else { return }
        for region in activeRegions {
            let frame = captureFrame(for: region)
            let extent = splitExtent(for: region)
            if frame.isEmpty {
                let bounds = frameBounds(for: display)
                let cell = destinationRect(for: region)
                let aspect = cell.width / max(cell.height, 1)
                let centerX = region == .tertiary ? 0.75 : 0.25
                let initial = CaptureGeometry.frame(width: max(captureFrame.width, 1),
                    centeredAt: CGPoint(x: bounds.minX + bounds.width * centerX, y: bounds.midY),
                    within: bounds, aspectRatio: aspect, minimumWidth: 1)
                setCaptureFrame(initial, for: region)
            } else {
                setCaptureFrame(fittedFrame(frame, for: region,
                    requestedExtent: preserveSplitScale && extent > 0 ? extent : nil), for: region)
            }
            if region == .secondary { secondaryOutputCell = destinationRect(for: region) }
            if region == .tertiary { tertiaryOutputCell = destinationRect(for: region) }
        }
        if !preserveSplitScale {
            for region in activeRegions { setSplitExtent(captureFrame(for: region).width, for: region) }
        }
        frameWidth = activeCaptureFrame.width
    }

    private func updateComposition() {
        engine.updateComposition(primaryFrame: captureFrame,
            secondaryFrame: hasTwoRegions ? secondaryCaptureFrame : nil,
            layout: layout, splitRatio: splitRatio, camera: cameraConfiguration,
            tertiaryFrame: layout == .stackedThree ? tertiaryCaptureFrame : nil, secondSplitRatio: secondSplitRatio)
    }

    func setOrientation(_ value: CaptureOrientation) async {
        guard !isRecording && !isBusy && !isShuttingDown, orientation != value else { return }
        commitFrameEdits?()
        isBusy = true
        defer { isBusy = false }
        let wasPreviewing = isPreviewing
        if wasPreviewing {
            await engine.stopPreview()
            isPreviewing = false
            previewSurface.clear()
            audioLevel = 0
            audioDecibels = -120
        }
        guard !isShuttingDown, selectedDisplay != nil else { return }
        let previousCells = rememberedOutputCells
        orientation = value
        cameraOverlay = cameraOverlay.clamped(in: outputSize)
        saveCameraSettings()
        remapFrames(from: previousCells)
        saveFramePosition()
        refreshOverlay()
        if wasPreviewing {
            do { try await beginPreview() }
            catch { if !isShuttingDown { errorMessage = error.localizedDescription } }
        }
    }

    func refreshDevices() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let mode = CGDisplayCopyDisplayMode(id)
            let scale = mode.map { CGFloat($0.pixelWidth) / CGFloat($0.width) } ?? screen.backingScaleFactor
            return DisplayChoice(id: id, name: screen.localizedName, frame: screen.frame,
                                 visibleFrame: screen.visibleFrame, scale: scale)
        }
        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first?.id ?? 0
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                         mediaType: .audio, position: .unspecified)
        microphones = discovery.devices.map { device in
            let audio = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)
            return MicrophoneChoice(id: device.uniqueID, name: device.localizedName,
                                    channels: max(1, Int(audio?.pointee.mChannelsPerFrame ?? 1)))
        }
        if selectedMicrophoneID == "__system_default__" {
            selectedMicrophoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? ""
        }
        // Do not silently substitute a different microphone if a saved device is missing.
        if !selectedMicrophoneID.isEmpty && !microphones.contains(where: { $0.id == selectedMicrophoneID }) {
            notice = "Your saved microphone is unavailable. Select a microphone before recording."
            selectedMicrophoneID = ""
        }
        if microphoneChannel >= microphoneChannels { microphoneChannel = -1 }
        refreshCameras()
    }

    func selectDisplay(_ id: CGDirectDisplayID) {
        guard !isPreviewing && !isBusy && !isShuttingDown else { return }
        selectedDisplayID = id
        guard let display = selectedDisplay else { return }
        selectedRegion = .primary
        let cell = destinationRect(for: .primary)
        captureFrame = CaptureGeometry.initialFrame(in: frameBounds(for: display), preferredWidth: captureFrame.width,
            aspectRatio: cell.width / max(cell.height, 1))
        secondaryCaptureFrame = .zero
        secondaryOutputCell = nil
        tertiaryCaptureFrame = .zero
        tertiaryOutputCell = nil
        refitFrames()
        saveFramePosition()
        refreshOverlay()
    }

    func resizeFrame() {
        guard !isBusy && !isShuttingDown, !activeRegionIsCamera, let display = selectedDisplay else { return }
        frameWidth = min(max(frameWidth, minimumFrameWidth), maximumFrameWidth)
        let current = activeCaptureFrame
        let resized = CaptureGeometry.frame(width: frameWidth,
            centeredAt: CGPoint(x: current.midX, y: current.midY),
            within: frameBounds(for: display), aspectRatio: activeAspectRatio, minimumWidth: minimumFrameWidth)
        setCaptureFrame(resized, for: selectedRegion)
        setSplitExtent(resized.width, for: selectedRegion)
        frameWidth = activeCaptureFrame.width
        saveFramePosition()
        updateComposition()
        refreshOverlay()
    }

    func toggleFrame() {
        guard !isRecording && !isBusy && !isShuttingDown else { return }
        if isFrameVisible {
            for region in CaptureRegion.allCases { frameOverlay(for: region).hide() }
            isFrameVisible = false
        } else { showFrame() }
    }

    func showFrame() {
        guard !isShuttingDown, let display = selectedDisplay else { return }
        for region in CaptureRegion.allCases {
            let handle = frameOverlay(for: region)
            guard activeRegions.contains(region), !isCameraRegion(region) else { handle.hide(); continue }
            handle.show(frame: captureFrame(for: region), displayFrame: display.visibleFrame, guides: false,
                label: hasTwoRegions ? regionTitle(region) : nil, accent: regionAccent(region),
                isSelected: selectedRegion == region, busy: isBusy)
        }
        isFrameVisible = true
        refreshOverlay()
    }

    func togglePreview() async {
        guard !isBusy && !isRecording && !isShuttingDown else { return }
        if !isPreviewing { commitFrameEdits?() }
        if !isPreviewing && presentOnboardingIfNeeded() { return }
        isBusy = true
        defer { isBusy = false }
        if isPreviewing {
            await engine.stopPreview()
            isPreviewing = false
            previewSurface.clear()
            audioLevel = 0
            audioDecibels = -120
        } else {
            do { try await beginPreview() }
            catch { if !isShuttingDown { errorMessage = error.localizedDescription } }
        }
    }

    func toggleRecording() async {
        guard !isBusy && !isShuttingDown else { return }
        if isRecording {
            await finishRecording()
            return
        }
        commitFrameEdits?()
        if presentOnboardingIfNeeded() { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if outputFolder == nil { chooseOutputFolder() }
            guard let folder = outputFolder else { return }
            notice = nil
            if !isPreviewing { try await beginPreview() }
            guard !isShuttingDown else { return }
            let scoped = folder.startAccessingSecurityScopedResource()
            if scoped { securityScopedFolder = folder }
            try await startTake(in: folder)
        } catch {
            releaseOutputFolder()
            if !isShuttingDown { errorMessage = error.localizedDescription }
        }
    }

    private func startTake(in folder: URL) async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "vcam \(formatter.string(from: Date())) \(UUID().uuidString.prefix(8)).mp4"
        try await engine.startRecording(to: folder.appendingPathComponent(name))
        isRecording = true
        elapsedSeconds = 0
        recordingStart = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak model = self] _ in
            Task { @MainActor [weak model] in
                guard let model, let start = model.recordingStart else { return }
                model.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
        refreshOverlay()
    }

    private func clearTakeState() {
        isRecording = false
        timer?.invalidate()
        timer = nil
        recordingStart = nil
        elapsedSeconds = 0
    }

    func cancelRecording() async {
        guard isRecording && !isBusy && !isShuttingDown else { return }
        isBusy = true
        defer {
            clearTakeState()
            releaseOutputFolder()
            isBusy = false
        }
        do {
            try await engine.discardRecording()
            notice = "Take discarded. Preview is ready for another recording."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restartRecording() async {
        guard isRecording && !isBusy && !isShuttingDown, let folder = outputFolder else { return }
        isBusy = true
        defer {
            if !isRecording { releaseOutputFolder() }
            isBusy = false
        }
        do {
            // Keep folder access and capture inputs alive across both writers.
            // Discard targets only the active unfinished take, never lastRecording.
            do { try await engine.discardRecording() }
            catch { clearTakeState(); throw error }
            clearTakeState()
            guard !isShuttingDown else { return }
            try await startTake(in: folder)
            notice = "New take started. The previous take was discarded."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func finishRecording() async {
        guard isRecording && !isBusy else { return }
        isBusy = true
        defer {
            clearTakeState()
            releaseOutputFolder()
            isBusy = false
        }
        do {
            if let url = try await engine.stopRecording() {
                lastRecording = url
                lastRecordingFolder = outputFolder
                notice = "Saved \(url.lastPathComponent)"
                await openRecordingInQuickTime(url, folder: lastRecordingFolder)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseOutputFolder() {
        guard !isRecording else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose where vcam saves recordings"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputFolder ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: "outputFolderBookmark")
            outputFolder = url
        } catch { errorMessage = "Could not remember that folder: \(error.localizedDescription)" }
    }

    func revealLastRecording() {
        guard let lastRecording else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastRecording])
    }

    func openLastRecording() {
        guard let lastRecording else { return }
        let folder = lastRecordingFolder
        Task { await openRecordingInQuickTime(lastRecording, folder: folder) }
    }

    private func openRecordingInQuickTime(_ url: URL, folder: URL?) async {
        let workspace = NSWorkspace.shared
        guard let application = workspace.urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX") else {
            notice = "Saved \(url.lastPathComponent). QuickTime Player is unavailable. Use Reveal to find the video."
            return
        }
        // Keep the original folder's grant while Launch Services opens the file,
        // including when Play is used after selecting a different save folder.
        let hasAccess = folder?.startAccessingSecurityScopedResource() == true
        defer { if hasAccess { folder?.stopAccessingSecurityScopedResource() } }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await workspace.open([url], withApplicationAt: application, configuration: configuration)
        } catch {
            notice = "Saved \(url.lastPathComponent). QuickTime Player could not open it: \(error.localizedDescription)"
        }
    }

    func openScreenPermissions() {
        let pane = errorMessage?.contains("→ Microphone") == true ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func shutdown() async {
        isShuttingDown = true
        await waitForTransition()
        if isRecording { await finishRecording() }
        isBusy = true
        await engine.stopPreview()
        for region in CaptureRegion.allCases { frameOverlay(for: region).hide() }
        timer?.invalidate()
        releaseOutputFolder()
        isPreviewing = false
        isBusy = false
    }

    private func beginPreview() async throws {
        guard let display = selectedDisplay else { throw SetupError("Connect a display to start recording.") }
        let revision = displayRevision
        captureRevision += 1
        refreshPermissions()
        guard permissionsReady else {
            showOnboarding = true
            throw SetupError("Complete access for your enabled inputs in the setup panel, then start preview.")
        }
        if cameraPlacement != .off && !cameras.contains(where: { $0.id == selectedCameraID }) {
            throw SetupError("Choose a connected camera, or set Camera to Off to record only the screen.")
        }
        guard !isShuttingDown, revision == displayRevision else { throw CancellationError() }
        showFrame()
        try await engine.startPreview(configuration: CaptureConfiguration(
            displayID: display.id, displayFrame: display.frame, captureFrame: captureFrame,
            framesPerSecond: framesPerSecond,
            microphoneID: selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID,
            showsCursor: showsCursor, outputSize: outputSize,
            microphoneChannel: microphoneChannel < 0 ? nil : microphoneChannel,
            secondaryCaptureFrame: hasTwoRegions ? secondaryCaptureFrame : nil,
            layout: layout, splitRatio: splitRatio, camera: cameraConfiguration,
            tertiaryCaptureFrame: layout == .stackedThree ? tertiaryCaptureFrame : nil,
            secondSplitRatio: secondSplitRatio
        ))
        guard !isShuttingDown, revision == displayRevision else {
            await engine.stopPreview()
            throw CancellationError()
        }
        // Handles can move while ScreenCaptureKit is starting. Reconcile the
        // latest source frames after the worker exists, before exposing preview.
        updateComposition()
        engine.updateCamera(cameraConfiguration)
        isPreviewing = true
    }

    private func refreshOverlay() {
        guard isFrameVisible, let display = selectedDisplay else { return }
        for region in CaptureRegion.allCases {
            let handle = frameOverlay(for: region)
            guard activeRegions.contains(region), !isCameraRegion(region) else { handle.hide(); continue }
            handle.update(frame: captureFrame(for: region), displayFrame: display.visibleFrame,
                guides: false, recording: isRecording,
                label: hasTwoRegions ? regionTitle(region) : nil, accent: regionAccent(region),
                isSelected: selectedRegion == region, busy: isBusy)
        }
    }

    private func frameBounds(for display: DisplayChoice) -> CGRect {
        // Match the overlay's drag bounds so positions at an edge survive relaunch.
        display.visibleFrame
    }

    private func restoreFrame() {
        guard let display = selectedDisplay else { return }
        let defaults = UserDefaults.standard
        let savedID = defaults.integer(forKey: "frameDisplayID")
        if let savedDisplay = displays.first(where: { Int($0.id) == savedID }) {
            selectedDisplayID = savedDisplay.id
        }
        let target = selectedDisplay ?? display
        selectedRegion = .primary
        let primaryCell = destinationRect(for: .primary)
        let primaryAspect = primaryCell.width / max(primaryCell.height, 1)
        frameWidth = defaults.object(forKey: "frameWidth") as? Double ?? frameWidth
        if defaults.object(forKey: "frameX") != nil && Int(target.id) == savedID {
            captureFrame = CaptureGeometry.frame(width: frameWidth,
                                                 centeredAt: CGPoint(x: defaults.double(forKey: "frameX"),
                                                                     y: defaults.double(forKey: "frameY")),
                                                 within: frameBounds(for: target), aspectRatio: primaryAspect, minimumWidth: 1)
        } else {
            captureFrame = CaptureGeometry.initialFrame(in: frameBounds(for: target), preferredWidth: frameWidth, aspectRatio: primaryAspect)
        }
        secondaryCaptureFrame = .zero
        secondaryOutputCell = nil
        tertiaryCaptureFrame = .zero
        tertiaryOutputCell = nil
        for region in [CaptureRegion.secondary, .tertiary] {
            let prefix = region.rawValue
            let regionDisplayID = defaults.object(forKey: "\(prefix)FrameDisplayID") as? Int ?? savedID
            guard defaults.object(forKey: "\(prefix)FrameWidth") != nil, Int(target.id) == regionDisplayID else { continue }
            let cell = destinationRect(for: region)
            let width = defaults.double(forKey: "\(prefix)FrameWidth")
            let height = defaults.double(forKey: "\(prefix)FrameHeight")
            let aspect = height > 0 ? width / height : cell.width / max(cell.height, 1)
            let restored = CaptureGeometry.frame(width: width,
                centeredAt: CGPoint(x: defaults.double(forKey: "\(prefix)FrameX"), y: defaults.double(forKey: "\(prefix)FrameY")),
                within: frameBounds(for: target), aspectRatio: aspect, minimumWidth: 1)
            setCaptureFrame(restored, for: region)
            let outputWidth = defaults.double(forKey: "\(prefix)OutputWidth")
            let outputHeight = defaults.double(forKey: "\(prefix)OutputHeight")
            if outputWidth > 0 && outputHeight > 0 {
                let remembered = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
                if region == .secondary { secondaryOutputCell = remembered }
                else { tertiaryOutputCell = remembered }
            }
        }
        refitFrames()
    }

    private func saveFramePosition() {
        let defaults = UserDefaults.standard
        defaults.set(Int(selectedDisplayID), forKey: "frameDisplayID")
        defaults.set(captureFrame.midX, forKey: "frameX")
        defaults.set(captureFrame.midY, forKey: "frameY")
        defaults.set(captureFrame.width, forKey: "frameWidth")
        defaults.set(layout.rawValue, forKey: "captureLayout")
        defaults.set(splitRatio, forKey: "splitRatio")
        defaults.set(twoRegionSplitRatio, forKey: "twoRegionSplitRatio")
        defaults.set(threeRegionSplitRatio, forKey: "threeRegionSplitRatio")
        defaults.set(secondSplitRatio, forKey: "secondSplitRatio")
        for region in [CaptureRegion.secondary, .tertiary] {
            let frame = captureFrame(for: region)
            guard !frame.isEmpty else { continue }
            let prefix = region.rawValue
            defaults.set(Int(selectedDisplayID), forKey: "\(prefix)FrameDisplayID")
            defaults.set(frame.width, forKey: "\(prefix)FrameWidth")
            defaults.set(frame.height, forKey: "\(prefix)FrameHeight")
            defaults.set(frame.midX, forKey: "\(prefix)FrameX")
            defaults.set(frame.midY, forKey: "\(prefix)FrameY")
            if let cell = region == .secondary ? secondaryOutputCell : tertiaryOutputCell {
                defaults.set(cell.width, forKey: "\(prefix)OutputWidth")
                defaults.set(cell.height, forKey: "\(prefix)OutputHeight")
            }
        }
    }

    private func restoreOutputFolder() {
        guard let data = UserDefaults.standard.data(forKey: "outputFolderBookmark") else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            outputFolder = url
            if stale {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let refreshed = try url.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(refreshed, forKey: "outputFolderBookmark")
            }
        } catch { outputFolder = nil }
    }

    private func releaseOutputFolder() {
        securityScopedFolder?.stopAccessingSecurityScopedResource()
        securityScopedFolder = nil
    }

    private func handleCaptureFailure(_ message: String) async {
        let revision = captureRevision
        await waitForTransition()
        guard !isShuttingDown, revision == captureRevision else { return }
        // Keep a partial recording if the writer can still finalize it.
        if isRecording { await finishRecording() }
        isBusy = true
        defer { isBusy = false }
        await engine.stopPreview()
        isPreviewing = false
        audioLevel = 0
        previewSurface.clear()
        errorMessage = message
    }

    private func screenConfigurationChanged() async {
        displayRevision += 1
        await waitForTransition()
        guard !isShuttingDown else { return }
        if isRecording { await finishRecording() }
        isBusy = true
        defer { isBusy = false }
        if isPreviewing {
            await engine.stopPreview()
            isPreviewing = false
            previewSurface.clear()
            notice = "Your display configuration changed. Reposition the frame and start preview again."
        }
        refreshDevices()
        restoreFrame()
        refreshOverlay()
    }

    private func waitForTransition() async {
        while isBusy {
            await withCheckedContinuation { continuation in transitionWaiters.append(continuation) }
        }
    }
}

private struct SetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
