import SwiftUI
import AVFoundation

/// Camera is optional; choosing a placement is the point where access matters.
struct CameraSettingsView: View {
    @Bindable var model: RecorderModel

    private var canChangeSource: Bool { !model.isRecording && !model.isBusy && !model.requestingCamera }
    private var canAdjust: Bool { !model.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Camera").frame(width: 90, alignment: .leading)
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
                .labelsHidden().disabled(!canChangeSource)
                SettingHelp("Camera placement", "Add your camera as a floating overlay, or let it fill either region of a split composition. The camera is saved in the video. Off keeps camera access optional. Stop recording before changing the camera or its placement.")
            }

            if model.cameraPlacement != .off {
                if model.cameraAuthorization != .authorized {
                    permissionControls
                } else {
                    deviceControls
                }

                if model.cameraPlacement == .overlay {
                    overlayControls
                }

                HStack {
                    Toggle("Mirror camera", isOn: Binding(
                        get: { model.mirrorsCamera }, set: { model.setMirrorsCamera($0) }
                    ))
                    .toggleStyle(.checkbox).disabled(!canAdjust)
                    SettingHelp("Mirror camera", "Flip the camera horizontally in both the preview and saved video. Turn this off when showing text or objects that need to read correctly. You can change this during a take.")
                    Spacer()
                }
            }
        }
    }

    private var deviceControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Device").frame(width: 90, alignment: .leading)
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
                Button("Continue without camera") {
                    Task { await model.setCameraPlacement(.off) }
                }.buttonStyle(.link)
            }.disabled(!canChangeSource)
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
            HStack {
                Text("Shape").frame(width: 90, alignment: .leading)
                Picker("Camera overlay shape", selection: Binding(
                    get: { model.cameraOverlay.shape },
                    set: { shape in updateOverlay { $0.shape = shape } }
                )) {
                    ForEach(CameraShape.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
                SettingHelp("Camera shape", "The circle uses a square crop. The rounded rectangle uses a 4:3 crop. Both fill their frame, so the edges of the camera image may be cropped.")
            }
            HStack(spacing: 8) {
                Text("Size").frame(width: 90, alignment: .leading)
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
                Text("Position").frame(width: 90, alignment: .leading)
                cornerButton("Top left", symbol: "arrow.up.left", right: false, bottom: false)
                cornerButton("Top right", symbol: "arrow.up.right", right: true, bottom: false)
                cornerButton("Bottom left", symbol: "arrow.down.left", right: false, bottom: true)
                cornerButton("Bottom right", symbol: "arrow.down.right", right: true, bottom: true)
                Spacer(minLength: 0)
                SettingHelp("Camera position", "Jump to a corner with a small inset, or drag the camera anywhere in the live preview. The entire camera stays inside the output frame. Check platform captions and controls when choosing a position.")
            }
        }.disabled(!canAdjust)
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
