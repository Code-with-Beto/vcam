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
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: "resolution") }
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
    @ObservationIgnored private var shortcuts: GlobalShortcuts?
    @ObservationIgnored private var displayObserver: NSObjectProtocol?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var recordingStart: Date?
    @ObservationIgnored private var securityScopedFolder: URL?
    @ObservationIgnored private var hasPrepared = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var displayRevision = 0
    @ObservationIgnored private var captureRevision = 0

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
            self.engine.updateCrop(rect)
            self.saveFramePosition()
        }
        overlay.onToggleRecording = { [weak self] in
            Task { await self?.toggleRecording() }
        }
        overlay.onHide = { [weak self] in self?.toggleFrame() }
    }

    var outputSize: CGSize { resolution.size(for: orientation) }
    var outputDimensions: String { "\(Int(outputSize.width)) × \(Int(outputSize.height))" }
    var guideBottomInset: CGFloat { reservesCaptions ? 0.20 : 0.08 }
    var microphoneChannels: Int { microphones.first { $0.id == selectedMicrophoneID }?.channels ?? 1 }
    var decibelText: String { audioDecibels <= -100 ? "−∞ dBFS" : String(format: "%.1f dBFS", audioDecibels) }
    var permissionsReady: Bool { screenAccessGranted && (selectedMicrophoneID.isEmpty || microphoneAuthorization == .authorized) }
    var selectedDisplay: DisplayChoice? { displays.first { $0.id == selectedDisplayID } }
    var elapsedText: String { String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60) }
    var maximumFrameWidth: Double {
        guard let display = selectedDisplay else { return 540 }
        return min(display.visibleFrame.width, display.visibleFrame.height * orientation.aspectRatio)
    }
    var sourceSizeText: String {
        guard let display = selectedDisplay else { return "Select a display" }
        return "\(Int((captureFrame.width * display.scale).rounded())) × \(Int((captureFrame.height * display.scale).rounded())) source pixels"
    }
    var isUpscaling: Bool {
        guard let display = selectedDisplay else { return false }
        return captureFrame.width * display.scale < outputSize.width - 1 || captureFrame.height * display.scale < outputSize.height - 1
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

    func setFrameHeight(_ height: Double) { setFrameWidth(height * orientation.aspectRatio) }

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
        guard !isShuttingDown, let display = selectedDisplay else { return }
        orientation = value
        let oldHeight = captureFrame.height
        frameWidth = min(oldHeight, maximumFrameWidth)
        captureFrame = CaptureGeometry.frame(width: frameWidth,
            centeredAt: CGPoint(x: captureFrame.midX, y: captureFrame.midY),
            within: frameBounds(for: display), aspectRatio: value.aspectRatio)
        UserDefaults.standard.set(frameWidth, forKey: "frameWidth")
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
        frameWidth = min(frameWidth, maximumFrameWidth)
        captureFrame = CaptureGeometry.initialFrame(in: frameBounds(for: display), preferredWidth: frameWidth, aspectRatio: orientation.aspectRatio)
        saveFramePosition()
        refreshOverlay()
    }

    func resizeFrame() {
        guard !isRecording && !isBusy, let display = selectedDisplay else { return }
        frameWidth = min(max(frameWidth, 180), maximumFrameWidth)
        captureFrame = CaptureGeometry.frame(width: frameWidth,
                                             centeredAt: CGPoint(x: captureFrame.midX, y: captureFrame.midY),
                                             within: frameBounds(for: display), aspectRatio: orientation.aspectRatio)
        UserDefaults.standard.set(frameWidth, forKey: "frameWidth")
        saveFramePosition()
        engine.updateCrop(captureFrame)
        refreshOverlay()
    }

    func toggleFrame() {
        guard !isRecording && !isBusy && !isShuttingDown else { return }
        if isFrameVisible {
            overlay.hide()
            isFrameVisible = false
        } else { showFrame() }
    }

    func showFrame() {
        guard !isShuttingDown, let display = selectedDisplay else { return }
        overlay.show(frame: captureFrame, displayFrame: display.visibleFrame, guides: showsGuides, guideBottomInset: guideBottomInset)
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
                notice = "Saved \(url.lastPathComponent)"
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
        NSWorkspace.shared.open(lastRecording)
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
            microphoneChannel: microphoneChannel < 0 ? nil : microphoneChannel
        ))
        guard !isShuttingDown, revision == displayRevision else {
            await engine.stopPreview()
            throw CancellationError()
        }
        isPreviewing = true
    }

    private func refreshOverlay() {
        guard isFrameVisible, let display = selectedDisplay else { return }
        overlay.update(frame: captureFrame, displayFrame: display.visibleFrame,
                       guides: showsGuides, recording: isRecording, guideBottomInset: guideBottomInset)
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
        frameWidth = min(max(frameWidth, 180), maximumFrameWidth)
        if defaults.object(forKey: "frameX") != nil && Int(target.id) == savedID {
            captureFrame = CaptureGeometry.frame(width: frameWidth,
                                                 centeredAt: CGPoint(x: defaults.double(forKey: "frameX"),
                                                                     y: defaults.double(forKey: "frameY")),
                                                 within: frameBounds(for: target), aspectRatio: orientation.aspectRatio)
        } else {
            captureFrame = CaptureGeometry.initialFrame(in: frameBounds(for: target), preferredWidth: frameWidth, aspectRatio: orientation.aspectRatio)
        }
    }

    private func saveFramePosition() {
        let defaults = UserDefaults.standard
        defaults.set(Int(selectedDisplayID), forKey: "frameDisplayID")
        defaults.set(captureFrame.midX, forKey: "frameX")
        defaults.set(captureFrame.midY, forKey: "frameY")
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
