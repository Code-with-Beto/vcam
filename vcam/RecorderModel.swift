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

enum CaptureRegion: String, CaseIterable, Identifiable {
    case primary, secondary
    var id: String { rawValue }
}

@MainActor
@Observable
final class RecorderModel {
    var displays: [DisplayChoice] = []
    var microphones: [MicrophoneChoice] = []
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
                refitFrames(preserveHeight: layout == .sideBySide)
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
    private(set) var layout: CaptureLayout = .single
    private(set) var splitRatio: Double = 0.5
    private(set) var selectedRegion: CaptureRegion = .primary
    private(set) var isFrameVisible = false
    private(set) var isPreviewing = false
    private(set) var isRecording = false
    private(set) var isBusy = false {
        didSet {
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
    @ObservationIgnored private var secondaryOutputCell: CGRect?

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
        layout = CaptureLayout(rawValue: defaults.string(forKey: "captureLayout") ?? "") ?? .single
        let savedSplit = defaults.object(forKey: "splitRatio") as? Double ?? 0.5
        splitRatio = savedSplit.isFinite ? min(max(savedSplit, 0.15), 0.85) : 0.5
        resolution = OutputResolution(rawValue: defaults.integer(forKey: "resolution")) ?? .qhd
        reservesCaptions = defaults.bool(forKey: "reservesCaptions")
        microphoneChannel = defaults.object(forKey: "microphoneChannel") as? Int ?? -1
        restoreOutputFolder()
        engine.onPreviewPixelBuffer = { [weak self] buffer in self?.previewSurface.display(buffer) }
        engine.onAudioDecibels = { [weak self] level in self?.audioDecibels = level }
        engine.onAudioChannel = { [weak self] channel in self?.activeMicrophoneChannel = channel }
        engine.onAudioLevel = { [weak self] level in self?.audioLevel = level }
        engine.onFailure = { [weak self] message in
            guard let self else { return }
            Task { await self.handleCaptureFailure(message) }
        }
        overlay.onFrameChanged = { [weak self] rect in
            guard let self else { return }
            self.captureFrame = rect
            self.updateComposition()
            self.saveFramePosition()
        }
        secondaryOverlay.onFrameChanged = { [weak self] rect in
            guard let self else { return }
            self.secondaryCaptureFrame = rect
            self.updateComposition()
            self.saveFramePosition()
        }
        overlay.onSelect = { [weak self] in self?.selectRegion(.primary) }
        secondaryOverlay.onSelect = { [weak self] in self?.selectRegion(.secondary) }
        overlay.onToggleRecording = { [weak self] in
            Task { await self?.toggleRecording() }
        }
        overlay.onHide = { [weak self] in self?.toggleFrame() }
        secondaryOverlay.onToggleRecording = { [weak self] in
            Task { await self?.toggleRecording() }
        }
        secondaryOverlay.onHide = { [weak self] in self?.toggleFrame() }
    }

    var outputSize: CGSize { resolution.size(for: orientation) }
    var outputDimensions: String { "\(Int(outputSize.width)) × \(Int(outputSize.height))" }
    var guideBottomInset: CGFloat { reservesCaptions ? 0.20 : 0.08 }
    var microphoneChannels: Int { microphones.first { $0.id == selectedMicrophoneID }?.channels ?? 1 }
    var decibelText: String { audioDecibels <= -100 ? "−∞ dBFS" : String(format: "%.1f dBFS", audioDecibels) }
    var permissionsReady: Bool { screenAccessGranted && (selectedMicrophoneID.isEmpty || microphoneAuthorization == .authorized) }
    var selectedDisplay: DisplayChoice? { displays.first { $0.id == selectedDisplayID } }
    var hasTwoRegions: Bool { layout != .single }
    var activeCaptureFrame: CGRect { selectedRegion == .primary ? captureFrame : secondaryCaptureFrame }
    var activeOutputRect: CGRect { destinationRect(for: selectedRegion) }
    var activeAspectRatio: CGFloat { activeOutputRect.width / max(activeOutputRect.height, 1) }
    var activeAspectLabel: String { hasTwoRegions ? "Matches output panel" : orientation.ratioLabel + " linked" }
    var splitDescription: String { "A \(Int((splitRatio * 100).rounded()))% · B \(100 - Int((splitRatio * 100).rounded()))%" }
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

    func setFrameWidth(_ width: Double) {
        guard width.isFinite, width > 0, !isRecording && !isBusy else { return }
        frameWidth = width
        resizeFrame()
    }

    func setFrameHeight(_ height: Double) { setFrameWidth(height * activeAspectRatio) }

    func regionTitle(_ region: CaptureRegion) -> String {
        if layout == .single { return "Frame" }
        if layout == .stacked { return region == .primary ? "A · Top" : "B · Bottom" }
        return region == .primary ? "A · Left" : "B · Right"
    }

    func selectRegion(_ region: CaptureRegion) {
        guard !isBusy, selectedRegion != region, region == .primary || hasTwoRegions else { return }
        commitFrameEdits?()
        selectedRegion = region
        frameWidth = activeCaptureFrame.width
        refreshOverlay()
    }

    func setLayout(_ value: CaptureLayout) {
        guard !isRecording && !isBusy && !isShuttingDown, value != layout else { return }
        commitFrameEdits?()
        let previousCells = [destinationRect(for: .primary), secondaryOutputCell ?? destinationRect(for: .secondary)]
        layout = value
        if value == .single { selectedRegion = .primary }
        remapFrames(from: previousCells)
        saveFramePosition()
        updateComposition()
        if isFrameVisible { showFrame() }
    }

    func setSplitRatio(_ value: Double) {
        guard hasTwoRegions && !isBusy && !isShuttingDown, value.isFinite else { return }
        let value = min(max(value, 0.15), 0.85)
        guard abs(value - splitRatio) > 0.0001 else { return }
        commitFrameEdits?()
        splitRatio = value
        refitFrames(preserveHeight: layout == .sideBySide, preserveSplitScale: true)
        saveFramePosition()
        updateComposition()
        refreshOverlay()
    }

    private func destinationRect(for region: CaptureRegion) -> CGRect {
        let rects = layout.destinationRects(in: outputSize, splitRatio: splitRatio)
        return region == .secondary && rects.count > 1 ? rects[1] : rects[0]
    }

    private func remapFrames(from previousCells: [CGRect]) {
        func remap(_ frame: CGRect, region: CaptureRegion, previous: CGRect) -> CGRect {
            guard !frame.isEmpty else { return frame }
            let cell = destinationRect(for: region)
            let width = frame.width * cell.width / max(previous.width, 1)
            let height = frame.height * cell.height / max(previous.height, 1)
            return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        }
        captureFrame = remap(captureFrame, region: .primary, previous: previousCells[0])
        if hasTwoRegions {
            secondaryCaptureFrame = remap(secondaryCaptureFrame, region: .secondary, previous: previousCells[1])
        }
        refitFrames(preserveHeight: false)
    }

    private func fittedFrame(_ frame: CGRect, for region: CaptureRegion, preserveHeight: Bool,
                             requestedExtent: CGFloat? = nil) -> CGRect {
        guard let display = selectedDisplay else { return frame }
        let cell = destinationRect(for: region)
        let aspect = cell.width / max(cell.height, 1)
        let extent = requestedExtent ?? (preserveHeight ? frame.height : frame.width)
        let width = preserveHeight ? extent * aspect : extent
        return CaptureGeometry.frame(width: width,
            centeredAt: CGPoint(x: frame.midX, y: frame.midY),
            within: frameBounds(for: display), aspectRatio: aspect, minimumWidth: 1)
    }

    private func refitFrames(preserveHeight: Bool, preserveSplitScale: Bool = false) {
        guard let display = selectedDisplay else { return }
        captureFrame = fittedFrame(captureFrame, for: .primary, preserveHeight: preserveHeight,
            requestedExtent: preserveSplitScale && primarySplitExtent > 0 ? primarySplitExtent : nil)
        if hasTwoRegions {
            if secondaryCaptureFrame.isEmpty {
                let bounds = frameBounds(for: display)
                let cell = destinationRect(for: .secondary)
                let aspect = cell.width / max(cell.height, 1)
                let width = layout == .sideBySide ? captureFrame.height * aspect : captureFrame.width
                secondaryCaptureFrame = CaptureGeometry.frame(width: width,
                    centeredAt: CGPoint(x: bounds.minX + bounds.width * 0.25, y: bounds.midY),
                    within: bounds, aspectRatio: aspect, minimumWidth: 1)
            } else {
                secondaryCaptureFrame = fittedFrame(secondaryCaptureFrame, for: .secondary, preserveHeight: preserveHeight,
                    requestedExtent: preserveSplitScale && secondarySplitExtent > 0 ? secondarySplitExtent : nil)
            }
            secondaryOutputCell = destinationRect(for: .secondary)
        }
        if !preserveSplitScale {
            primarySplitExtent = layout == .sideBySide ? captureFrame.height : captureFrame.width
            secondarySplitExtent = layout == .sideBySide ? secondaryCaptureFrame.height : secondaryCaptureFrame.width
        }
        frameWidth = activeCaptureFrame.width
    }

    private func updateComposition() {
        engine.updateComposition(primaryFrame: captureFrame,
            secondaryFrame: hasTwoRegions ? secondaryCaptureFrame : nil,
            layout: layout, splitRatio: splitRatio)
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
        let previousCells = CaptureRegion.allCases.map { destinationRect(for: $0) }
        orientation = value
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
        refitFrames(preserveHeight: false)
        saveFramePosition()
        refreshOverlay()
    }

    func resizeFrame() {
        guard !isRecording && !isBusy, let display = selectedDisplay else { return }
        frameWidth = min(max(frameWidth, minimumFrameWidth), maximumFrameWidth)
        let current = activeCaptureFrame
        let resized = CaptureGeometry.frame(width: frameWidth,
            centeredAt: CGPoint(x: current.midX, y: current.midY),
            within: frameBounds(for: display), aspectRatio: activeAspectRatio, minimumWidth: minimumFrameWidth)
        if selectedRegion == .primary {
            captureFrame = resized
            primarySplitExtent = layout == .sideBySide ? resized.height : resized.width
        } else {
            secondaryCaptureFrame = resized
            secondarySplitExtent = layout == .sideBySide ? resized.height : resized.width
        }
        frameWidth = activeCaptureFrame.width
        saveFramePosition()
        updateComposition()
        refreshOverlay()
    }

    func toggleFrame() {
        guard !isRecording && !isBusy && !isShuttingDown else { return }
        if isFrameVisible {
            overlay.hide()
            secondaryOverlay.hide()
            isFrameVisible = false
        } else { showFrame() }
    }

    func showFrame() {
        guard !isShuttingDown, let display = selectedDisplay else { return }
        overlay.show(frame: captureFrame, displayFrame: display.visibleFrame, guides: showsGuides,
            guideBottomInset: layout == .stacked ? 0.08 : guideBottomInset,
            label: hasTwoRegions ? regionTitle(.primary) : nil, accent: .systemCyan,
            isSelected: selectedRegion == .primary)
        if hasTwoRegions {
            secondaryOverlay.show(frame: secondaryCaptureFrame, displayFrame: display.visibleFrame, guides: showsGuides,
                guideBottomInset: guideBottomInset, label: regionTitle(.secondary), accent: .systemOrange,
                isSelected: selectedRegion == .secondary)
        } else { secondaryOverlay.hide() }
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
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let name = "vcam \(formatter.string(from: Date())) \(UUID().uuidString.prefix(4)).mp4"
            try await engine.startRecording(to: folder.appendingPathComponent(name))
            isRecording = true
            elapsedSeconds = 0
            recordingStart = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak model = self] _ in
                Task { @MainActor [weak model] in
                    guard let model, let start = model.recordingStart else { return }
                    model.elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
            }
            refreshOverlay()
        } catch {
            releaseOutputFolder()
            if !isShuttingDown { errorMessage = error.localizedDescription }
        }
    }

    func finishRecording() async {
        guard isRecording && !isBusy else { return }
        isBusy = true
        defer {
            isRecording = false
            isBusy = false
            timer?.invalidate()
            timer = nil
            recordingStart = nil
            releaseOutputFolder()
            refreshOverlay()
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
        overlay.hide()
        secondaryOverlay.hide()
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
            throw SetupError("Complete screen and microphone access in the setup panel, then start preview.")
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
            layout: layout, splitRatio: splitRatio
        ))
        guard !isShuttingDown, revision == displayRevision else {
            await engine.stopPreview()
            throw CancellationError()
        }
        // Handles can move while ScreenCaptureKit is starting. Reconcile the
        // latest source frames after the worker exists, before exposing preview.
        updateComposition()
        isPreviewing = true
    }

    private func refreshOverlay() {
        guard isFrameVisible, let display = selectedDisplay else { return }
        overlay.update(frame: captureFrame, displayFrame: display.visibleFrame,
            guides: showsGuides, recording: isRecording,
            guideBottomInset: layout == .stacked ? 0.08 : guideBottomInset,
            label: hasTwoRegions ? regionTitle(.primary) : nil, accent: .systemCyan,
            isSelected: selectedRegion == .primary)
        if hasTwoRegions {
            secondaryOverlay.update(frame: secondaryCaptureFrame, displayFrame: display.visibleFrame,
                guides: showsGuides, recording: isRecording, guideBottomInset: guideBottomInset,
                label: regionTitle(.secondary), accent: .systemOrange, isSelected: selectedRegion == .secondary)
        } else { secondaryOverlay.hide() }
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
        let secondaryDisplayID = defaults.object(forKey: "secondaryFrameDisplayID") as? Int ?? savedID
        if defaults.object(forKey: "secondaryFrameWidth") != nil, Int(target.id) == secondaryDisplayID {
            let cell = destinationRect(for: .secondary)
            let width = defaults.double(forKey: "secondaryFrameWidth")
            let height = defaults.double(forKey: "secondaryFrameHeight")
            let aspect = height > 0 ? width / height : cell.width / max(cell.height, 1)
            secondaryCaptureFrame = CaptureGeometry.frame(width: width,
                centeredAt: CGPoint(x: defaults.double(forKey: "secondaryFrameX"), y: defaults.double(forKey: "secondaryFrameY")),
                within: frameBounds(for: target), aspectRatio: aspect, minimumWidth: 1)
            let outputWidth = defaults.double(forKey: "secondaryOutputWidth")
            let outputHeight = defaults.double(forKey: "secondaryOutputHeight")
            if outputWidth > 0 && outputHeight > 0 {
                secondaryOutputCell = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
            }
        }
        refitFrames(preserveHeight: false)
    }

    private func saveFramePosition() {
        let defaults = UserDefaults.standard
        defaults.set(Int(selectedDisplayID), forKey: "frameDisplayID")
        defaults.set(captureFrame.midX, forKey: "frameX")
        defaults.set(captureFrame.midY, forKey: "frameY")
        defaults.set(captureFrame.width, forKey: "frameWidth")
        defaults.set(layout.rawValue, forKey: "captureLayout")
        defaults.set(splitRatio, forKey: "splitRatio")
        if !secondaryCaptureFrame.isEmpty {
            defaults.set(Int(selectedDisplayID), forKey: "secondaryFrameDisplayID")
            defaults.set(secondaryCaptureFrame.width, forKey: "secondaryFrameWidth")
            defaults.set(secondaryCaptureFrame.height, forKey: "secondaryFrameHeight")
            defaults.set(secondaryCaptureFrame.midX, forKey: "secondaryFrameX")
            defaults.set(secondaryCaptureFrame.midY, forKey: "secondaryFrameY")
            if let cell = secondaryOutputCell {
                defaults.set(cell.width, forKey: "secondaryOutputWidth")
                defaults.set(cell.height, forKey: "secondaryOutputHeight")
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
