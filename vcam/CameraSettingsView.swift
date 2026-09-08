import SwiftUI
import AVFoundation

enum CameraSettingsSection { case live, setup }

/// The source is configured before recording; composition stays adjustable live.
struct CameraSettingsView: View {
    @Bindable var model: RecorderModel
    var section: CameraSettingsSection = .live

    private var canChangeSource: Bool { !model.isRecording && !model.isBusy && !model.requestingCamera }
    private var canChangePlacement: Bool { !model.isBusy && !model.requestingCamera }
    private var canAdjust: Bool { !model.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Text(section == .live ? "Camera" : "Camera device").font(.headline)
                SettingHelp("Camera", "Choose the camera device in Setup. Use Live to add a floating camera, fill either split region, or turn it off during a take. Camera and microphone selections are independent.")
                Spacer()
            }
            if section == .live {
                placementControls
                if model.cameraPlacement != .off {
                    if model.cameraAuthorization != .authorized { permissionControls }
                    if model.cameraPlacement == .overlay { overlayControls }
                    framingControls
                    HStack {
                        Toggle("Mirror camera", isOn: Binding(
                            get: { model.mirrorsCamera }, set: { model.setMirrorsCamera($0) }
                        ))
                        .toggleStyle(.checkbox).disabled(!canAdjust)
                        SettingHelp("Mirror camera", "Flip the camera horizontally in both the preview and saved video. Turn this off when showing text or objects that need to read correctly. You can change this during a take.")
                        Spacer()
                    }
                }
            } else {
                if model.cameraAuthorization == .authorized {
                    deviceControls
                    Text(model.isRecording ? "Finish this take before switching camera devices." : "Choose the device here, then add it to your composition in Live.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    permissionControls
                }
            }
        }
    }

    private var placementControls: some View {
        HStack(spacing: 8) {
            Picker("Camera placement", selection: Binding(
                get: { model.cameraPlacement },
                set: { value in Task { await model.setCameraPlacement(value) } }
            )) {
                Text("Off").tag(CameraPlacement.off)
                Text("Floating overlay").tag(CameraPlacement.overlay)
                if model.hasTwoRegions {
                    Text("Replace \(model.regionTitle(.primary))").tag(CameraPlacement.regionA)
                    Text("Replace \(model.regionTitle(.secondary))").tag(CameraPlacement.regionB)
                }
            }
            .labelsHidden().disabled(!canChangePlacement)
            SettingHelp("Camera placement", "Add a floating camera or fill either region of a split composition. Placement changes appear in the current take. Off leaves screen recording running without the camera. To use another device, finish the take and choose it in Setup.")
        }
    }

    private var deviceControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Camera device", selection: Binding(
                    get: { model.selectedCameraID },
                    set: { value in Task { await model.setCameraDevice(value) } }
                )) {
                    if model.selectedCameraID.isEmpty || !model.cameras.contains(where: { $0.id == model.selectedCameraID }) {
                        Text(model.cameras.isEmpty ? "No camera available" : "Choose a camera")
                            .tag(model.selectedCameraID)
                    }
                    ForEach(model.cameras) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().disabled(!canChangeSource || model.cameras.isEmpty)
                Button { model.refreshCameras() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(!canChangeSource)
                    .accessibilityLabel("Refresh cameras")
                    .help("Refresh connected cameras")
                SettingHelp("Camera device", "Choose a built-in, USB, or available Continuity Camera. Camera capture starts with preview or recording, targeting 1080p at up to 30 fps. A 60 fps screen recording uses the latest available camera frame. If a camera is missing, connect it and refresh the list.")
            }
            if model.cameras.isEmpty {
                Text("Connect a camera, then refresh the list. You can also set Camera to Off and record your screen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(permissionDetail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if model.cameraAuthorization == .notDetermined {
                    Button(model.requestingCamera ? "Requesting access…" : "Enable camera") {
                        Task { await model.requestCameraAccess() }
                    }
                } else {
                    Button("Open Camera Settings") { model.openCameraPermissions() }
                }
                if model.cameraPlacement != .off {
                    Button("Continue without camera") {
                        Task { await model.setCameraPlacement(.off) }
                    }.buttonStyle(.link)
                }
            }.disabled(!canChangePlacement)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var permissionDetail: String {
        switch model.cameraAuthorization {
        case .notDetermined: return "Allow camera access to include yourself in the video. Screen recording also works with the camera off."
        case .restricted: return "Camera access is restricted on this Mac. You can continue recording your screen with the camera off."
        default: return "Camera access is off in macOS Settings. Enable it for vcam, or continue with the camera off."
        }
    }

    private var overlayControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text("Shape").font(.callout)
                    SettingHelp("Camera shape", "The circle uses a square crop. The rounded rectangle uses a 4:3 crop. Both fill their frame, so the edges of the camera image may be cropped.")
                    Spacer()
                }
                Picker("Camera overlay shape", selection: Binding(
                    get: { model.cameraOverlay.shape },
                    set: { shape in updateOverlay { $0.shape = shape } }
                )) {
                    ForEach(CameraShape.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            HStack(spacing: 8) {
                Text("Size").frame(width: 54, alignment: .leading)
                Slider(value: Binding(
                    get: { model.cameraOverlay.widthFraction },
                    set: { width in updateOverlay { $0.widthFraction = width } }
                ), in: 0.15...0.65)
                .accessibilityLabel("Camera overlay size")
                .accessibilityValue("\(Int((model.cameraOverlay.widthFraction * 100).rounded())) percent")
                Text("\(Int((model.cameraOverlay.widthFraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                SettingHelp("Camera size", "Camera width is 15–65% of the video's shorter dimension. This keeps its size consistent when switching orientation. Drag the camera in the preview to move it, or drag its corner handle to resize it, even while recording.")
            }
            HStack(spacing: 7) {
                Text("Position").frame(width: 54, alignment: .leading)
                cornerButton("Top left", symbol: "arrow.up.left", right: false, bottom: false)
                cornerButton("Top right", symbol: "arrow.up.right", right: true, bottom: false)
                cornerButton("Bottom left", symbol: "arrow.down.left", right: false, bottom: true)
                cornerButton("Bottom right", symbol: "arrow.down.right", right: true, bottom: true)
                Spacer(minLength: 0)
                SettingHelp("Camera position", "Jump to a corner with a small inset, or drag the camera anywhere in the live preview. The entire camera stays inside the output frame. Check platform captions and controls when choosing a position.")
            }
        }.disabled(!canAdjust)
    }

    private var framingControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("Zoom").frame(width: 54, alignment: .leading)
                Slider(value: Binding(
                    get: { model.cameraFraming.zoom },
                    set: { zoom in
                        var value = model.cameraFraming
                        value.zoom = zoom
                        model.setCameraFraming(value)
                    }
                ), in: 1...4)
                .accessibilityLabel("Camera zoom")
                .accessibilityValue(zoomDescription)
                Text(zoomDescription).font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
                SettingHelp("Camera crop and zoom", "Zoom crops into the camera image without changing the size of its overlay or panel. Choose Adjust crop, then drag inside the camera in the preview to position your face. These changes appear in the current take. Higher zoom uses fewer source pixels, so a closer camera can look sharper.")
            }
            HStack(spacing: 10) {
                Button {
                    if model.isAdjustingCameraCrop {
                        model.isAdjustingCameraCrop = false
                    } else {
                        Task {
                            if !model.isPreviewing { await model.togglePreview() }
                            if model.isPreviewing && model.cameraPlacement != .off {
                                model.isAdjustingCameraCrop = true
                            }
                        }
                    }
                } label: {
                    Label(model.isAdjustingCameraCrop ? "Done" : "Adjust crop",
                          systemImage: model.isAdjustingCameraCrop ? "checkmark" : "crop")
                }
                .disabled(model.requestingCamera)
                .help(model.isAdjustingCameraCrop ? "Finish framing the camera and return to moving its frame." : "Drag the camera image in the preview to frame your face. Starts preview if needed.")
                Button("Reset") { model.setCameraFraming(CameraFramingConfiguration()) }
                    .accessibilityLabel("Reset camera crop and zoom")
                    .help("Reset camera zoom to 1× and center the image.")
                Spacer(minLength: 0)
            }
            if model.isAdjustingCameraCrop {
                Text("Drag inside the camera image to frame your face. The frame stays in place until you choose Done.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(!canAdjust)
    }

    private var zoomDescription: String {
        String(format: "%.1f×", model.cameraFraming.zoom)
    }

    private func cornerButton(_ title: String, symbol: String, right: Bool, bottom: Bool) -> some View {
        Button {
            updateOverlay { value in
                let output = model.outputSize
                let rect = value.rect(in: output)
                let margin = min(output.width, output.height) * 0.035
                let x = (rect.width / 2 + margin) / max(output.width, 1)
                let y = (rect.height / 2 + margin) / max(output.height, 1)
                value.center = CGPoint(x: right ? 1 - x : x, y: bottom ? 1 - y : y)
            }
        } label: {
            Image(systemName: symbol).frame(width: 20, height: 16)
        }
        .accessibilityLabel("Move camera to \(title.lowercased())")
        .help(title)
    }

    private func updateOverlay(_ update: (inout CameraOverlayConfiguration) -> Void) {
        var value = model.cameraOverlay
        update(&value)
        model.setCameraOverlay(value.clamped(in: model.outputSize))
    }
}
