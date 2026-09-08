import SwiftUI

struct ContentView: View {
    @Bindable var model: RecorderModel
    @State private var panel: ControlPanel = .live
    @State private var widthText = ""
    @State private var heightText = ""
    @FocusState private var dimensionFocus: Dimension?
    private enum Dimension { case width, height }
    private enum ControlPanel: String, CaseIterable, Identifiable {
        case live = "Live", setup = "Setup"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                preview.padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                sidebar.frame(width: 390)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 700)
        .background(.background)
        .task { model.prepare(); syncDimensions(); model.commitFrameEdits = { commitDimensions() } }
        .onDisappear { model.commitFrameEdits = nil }
        .onChange(of: model.activeCaptureFrame) { _, _ in syncDimensions(force: true) }
        .onChange(of: model.selectedRegion) { _, _ in syncDimensions(force: true) }
        .onChange(of: dimensionFocus) { previous, _ in
            if previous == .width { applyWidth() }
            if previous == .height { applyHeight() }
        }
        .onChange(of: panel) { _, _ in commitDimensions(); dimensionFocus = nil }
        .onChange(of: model.isRecording) { _, recording in
            if recording { panel = .live }
        }
        .sheet(isPresented: $model.showOnboarding) { PermissionSetupView(model: model) }
        .alert("vcam needs your attention", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("Review access") { model.showOnboarding = true; model.errorMessage = nil }
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "viewfinder").font(.system(size: 23, weight: .medium)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("vcam").font(.system(size: 21, weight: .semibold, design: .rounded))
                Text("\(model.outputDimensions) · \(model.framesPerSecond) fps")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refreshPermissions(); model.showOnboarding = true } label: {
                Label(model.permissionsReady ? "Access ready" : "Set up access",
                      systemImage: model.permissionsReady ? "checkmark.shield" : "lock.open")
            }
            .disabled(model.isRecording || model.isBusy)
            HStack(spacing: 8) {
                Circle().fill(model.isRecording ? Color.red : model.isPreviewing ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(model.isRecording ? "Recording  \(model.elapsedText)" : model.statusText)
                    .font(.callout.monospacedDigit())
                if model.isBusy && model.isRecording { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output preview").font(.callout.weight(.semibold))
                SettingHelp("Output preview", "Resize this window to enlarge the preview. The saved dimensions and on-screen capture frames stay unchanged. The native preview refreshes at up to 30 fps. Guides and vcam controls are never recorded.")
                Spacer()
                Toggle(isOn: $model.showsGuides) {
                    Label("Safe areas", systemImage: "rectangle.dashed")
                }
                .toggleStyle(.button).controlSize(.small)
                .help("Show safe-area guides on the final composition. These guides are never recorded.")
                .accessibilityLabel("Show preview safe-area guides")
                Button(model.isFrameVisible ? "Hide frames" : "Show frames") { model.toggleFrame() }
                    .controlSize(.small).disabled(model.isRecording || model.isBusy)
                    .help("Show or hide capture frames: Shift-Command-F")
            }
            GeometryReader { geometry in
                let aspect = model.outputSize.width / max(model.outputSize.height, 1)
                let width = max(1, min(geometry.size.width, geometry.size.height * aspect))
                previewCanvas
                    .frame(width: width, height: width / aspect)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            Text(previewHint)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var previewCanvas: some View {
        ZStack {
            Color.black
            CameraPreview(surface: model.previewSurface).opacity(model.isPreviewing ? 1 : 0)
            if !model.isPreviewing {
                VStack(spacing: 14) {
                    Image(systemName: model.orientation == .portrait ? "rectangle.portrait.dashed" : "rectangle.dashed")
                        .font(.system(size: 40, weight: .ultraLight))
                    Text("Frame your next take").font(.headline)
                    Text("Place your frames over any app.\nStart preview to see your shot.")
                        .font(.callout).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.7)).padding(20)
            }
        }
        .overlay {
            ZStack {
                if model.showsGuides {
                    SafeAreaPreviewGuide(reservesCaptions: model.reservesCaptions)
                }
                CompositionDivider(layout: model.layout, outputSize: model.outputSize,
                    splitRatio: Binding(get: { model.splitRatio }, set: { model.setSplitRatio($0) }),
                    secondSplitRatio: Binding(get: { model.secondSplitRatio }, set: { model.setSecondSplitRatio($0) }),
                    splitRatioRange: model.splitRatioRange,
                    secondSplitRatioRange: model.secondSplitRatioRange,
                    isEnabled: !model.isBusy && !model.isAdjustingCameraCrop)
                if model.isPreviewing {
                    if model.isAdjustingCameraCrop, let destination = cameraDestinationRect {
                        CameraCropControls(
                            framing: Binding(get: { model.cameraFraming }, set: { model.setCameraFraming($0) }),
                            sourceSize: model.cameraSourceSize, outputSize: model.outputSize,
                            destination: destination,
                            shape: model.cameraPlacement == .overlay ? model.cameraOverlay.shape : nil,
                            isEnabled: !model.isBusy)
                        .id(cameraInteractionID)
                    } else if model.cameraPlacement == .overlay {
                        CameraOverlayControls(
                            configuration: Binding(get: { model.cameraOverlay }, set: { model.setCameraOverlay($0) }),
                            outputSize: model.outputSize, isEnabled: !model.isBusy)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.isPreviewing ? "Live video preview" : "Preview is off")
    }

    private var previewHint: String {
        if model.isAdjustingCameraCrop {
            return "Drag inside the camera to frame your face. Use Zoom in Live to crop closer, then choose Done. The camera frame stays in place."
        }
        if model.cameraPlacement == .overlay {
            return "Drag the camera to move it; use its corner to resize. \(model.hasTwoRegions ? splitPreviewHint : "Changes appear in your take.")"
        }
        return model.hasTwoRegions
            ? "\(splitPreviewHint) Move each capture frame independently on your display."
            : "The full capture frame is recorded. Resize this window for a larger preview."
    }

    private var splitPreviewHint: String {
        model.activeRegions.count == 3
            ? "Drag either divider to resize the three panels."
            : "Drag the divider to adjust the split."
    }

    private var cameraDestinationRect: CGRect? {
        switch model.cameraPlacement {
        case .off: return nil
        case .overlay: return model.cameraOverlay.rect(in: model.outputSize)
        case .regionA, .regionB, .regionC:
            let regions = model.layout.destinationRects(in: model.outputSize, splitRatio: model.splitRatio,
                                                        secondSplitRatio: model.secondSplitRatio)
            let index = model.cameraPlacement == .regionC ? 2 : model.cameraPlacement == .regionB ? 1 : 0
            return regions.indices.contains(index) ? regions[index] : nil
        }
    }

    private var cameraInteractionID: String {
        // Recreate GestureState when the source's coordinate system changes.
        // An in-progress drag must not reuse its origin after mirroring or
        // replacing a region with the floating camera.
        "\(model.selectedCameraID):\(model.cameraPlacement.rawValue):\(model.layout.rawValue):\(model.cameraOverlay.shape.rawValue):\(model.mirrorsCamera)"
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Controls", selection: $panel) {
                ForEach(ControlPanel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(panel == .live ? "Adjust your composition before or during a take." : "Choose your sources and recording format.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if panel == .live {
                        liveSettings
                    } else {
                        setupSettings
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .scrollIndicators(.automatic)
        }
        .background(.quaternary.opacity(0.12))
    }

    private var liveSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            compositionSettings
            Divider()
            frameSettings
            Divider()
            CameraSettingsView(model: model, section: .live)
        }
    }

    private var compositionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingTitle("Layout", help: "Record one region, stack A above B, or stack three panels with A at the top, B in the middle, and C at the bottom. Replace any stacked panel with your camera. Switch layouts during a take; the saved video keeps the same resolution and orientation.")
            CompositionLayoutPicker(
                selection: Binding(get: { model.layout }, set: { model.setLayout($0) }),
                isEnabled: !model.isBusy)
            if model.hasTwoRegions {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Panel heights").font(.callout)
                        SettingHelp("Panel heights", "Drag a preview divider or use these sliders during a take. Divider positions are measured from the top of the video. Every panel keeps at least 15% of its height, and the dividers cannot cross. Source frames resize to match without stretching. The dividers are never recorded.")
                        Spacer()
                        Button(model.activeRegions.count == 3 ? "Equal thirds" : "50/50") {
                            model.equalizeSplit()
                        }.controlSize(.small)
                    }
                    Text(model.splitDescription).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if model.activeRegions.count == 3 {
                        splitSlider("Top divider",
                            value: Binding(get: { model.splitRatio }, set: { model.setSplitRatio($0) }),
                            range: model.splitRatioRange)
                        splitSlider("Bottom divider",
                            value: Binding(get: { model.secondSplitRatio }, set: { model.setSecondSplitRatio($0) }),
                            range: model.secondSplitRatioRange)
                    } else {
                        Slider(value: Binding(get: { model.splitRatio }, set: { model.setSplitRatio($0) }),
                               in: model.splitRatioRange)
                            .accessibilityLabel("Region A share of output").accessibilityValue(model.splitDescription)
                    }
                }.disabled(model.isBusy)
            }
        }
    }

    private func splitSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent from the top")
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
        }
    }

    private var frameSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingTitle("Capture region", help: "Select a region to change how much of your display it captures. Drag its floating handle on screen to move it. Each handle also has horizontal and vertical movement locks. These changes work during recording.")
            if model.hasTwoRegions {
                Picker("Edit region", selection: Binding(get: { model.selectedRegion }, set: { model.selectRegion($0) })) {
                    ForEach(model.activeRegions) { Text(model.regionTitle($0)).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).disabled(model.isBusy)
            }
            if model.activeRegionIsCamera {
                Label("Camera fills \(model.regionTitle(model.selectedRegion))", systemImage: "video.fill")
                    .font(.callout.weight(.medium))
                Text("Use the split to resize this panel. Use Camera's Zoom and Adjust crop controls to frame your face.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Text("Frame size").font(.callout)
                    SettingHelp("Frame size and points", "Points (pt) measure the captured region on your Mac, not output resolution. On a 2× Retina display, 540 × 960 pt contains 1080 × 1920 source pixels. Width and height stay linked to this region's output shape. Larger frames show more content; smaller frames magnify it.")
                    Spacer()
                    Text(model.activeAspectLabel).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("W").foregroundStyle(.secondary)
                    TextField("Width", text: $widthText).focused($dimensionFocus, equals: .width).onSubmit { applyWidth() }
                        .accessibilityLabel("Frame width in screen points")
                    Text("×").foregroundStyle(.secondary)
                    Text("H").foregroundStyle(.secondary)
                    TextField("Height", text: $heightText).focused($dimensionFocus, equals: .height).onSubmit { applyHeight() }
                        .accessibilityLabel("Frame height in screen points")
                    Text("pt").foregroundStyle(.secondary)
                }.disabled(model.isBusy)
                Slider(value: Binding(get: { model.frameWidth }, set: { model.setFrameWidth($0) }),
                       in: model.minimumFrameWidth...max(model.minimumFrameWidth, model.maximumFrameWidth), step: 2)
                    .accessibilityLabel("Recording frame size").disabled(model.isBusy)
                Label(model.sourceSizeText + (model.isUpscaling ? " · scaled up" : ""),
                      systemImage: model.isUpscaling ? "arrow.up.right" : "checkmark.circle")
                    .font(.caption).foregroundStyle(model.isUpscaling ? Color.orange : Color.secondary)
            }
        }
    }

    private var setupSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.isRecording || model.isPreviewing {
                Label(model.isRecording ? "Finish the take to change recording format or devices." : "Stop preview to change display, output, audio, or cursor.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            outputSettings
            Divider()
            CameraSettingsView(model: model, section: .setup)
            Divider()
            microphoneSettings
            Divider()
            guideSettings
            Divider()
            folderSettings
        }
    }

    private var outputSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recording format").font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                settingTitle("Display", help: "Choose the display to capture. All screen regions can move independently inside this display. Stop preview before switching displays.", prominent: false)
                Picker("Display", selection: Binding(get: { model.selectedDisplayID }, set: { model.selectDisplay($0) })) {
                    ForEach(model.displays) { Text($0.name).tag($0.id) }
                }.labelsHidden().disabled(model.isPreviewing || model.isBusy)
            }
            VStack(alignment: .leading, spacing: 7) {
                settingTitle("Orientation", help: "Portrait is 9:16; landscape is 16:9. This sets the shape of the saved video. Stop recording before changing orientation.", prominent: false)
                Picker("Orientation", selection: Binding(get: { model.orientation }, set: { value in Task { await model.setOrientation(value) } })) {
                    ForEach(CaptureOrientation.allCases) { Text($0.title + " " + $0.ratioLabel).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).disabled(model.isRecording || model.isBusy)
            }
            VStack(alignment: .leading, spacing: 7) {
                settingTitle("Output resolution", help: "The dimensions of the saved video, in pixels. 2K here means 1440p: 1440 × 2560 in portrait. It preserves more detail when the capture region contains enough source pixels, with larger files and more GPU work.", prominent: false)
                Picker("Resolution", selection: $model.resolution) {
                    ForEach(OutputResolution.allCases) { resolution in
                        let size = resolution.size(for: model.orientation)
                        Text("\(resolution.title) · \(Int(size.width)) × \(Int(size.height))").tag(resolution)
                    }
                }.labelsHidden().disabled(model.isPreviewing || model.isBusy)
            }
            VStack(alignment: .leading, spacing: 7) {
                settingTitle("Frame rate", help: "30 fps is the default for screen demos. 60 fps records smoother motion with more processing and storage. The live preview refreshes at up to 30 fps.", prominent: false)
                Picker("Frame rate", selection: $model.framesPerSecond) {
                    Text("30 fps · default").tag(30)
                    Text("60 fps · smoother motion").tag(60)
                }.labelsHidden().disabled(model.isPreviewing || model.isBusy)
            }
        }
    }

    private var microphoneSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingTitle("Microphone", help: "Choose your microphone or audio interface. Start preview and speak to check the meter at the bottom of this window. Camera and microphone selections are independent.")
            HStack {
                Picker("Microphone", selection: $model.selectedMicrophoneID) {
                    Text("No microphone").tag("")
                    ForEach(model.microphones) { Text($0.name).tag($0.id) }
                }.labelsHidden()
                    .onChange(of: model.selectedMicrophoneID) { _, _ in model.microphoneChannel = -1; model.refreshPermissions() }
                Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel("Refresh microphones")
            }.disabled(model.isPreviewing || model.isBusy)
            if model.microphoneChannels > 1 && !model.selectedMicrophoneID.isEmpty {
                settingTitle("Input channel", help: "Choose the input your microphone uses. Auto selects the strongest of the first two channels and locks that choice for the take. On the Scarlett, inputs 3–4 are loopback channels.", prominent: false)
                Picker("Input channel", selection: $model.microphoneChannel) {
                    Text("Auto · inputs 1–2").tag(-1)
                    ForEach(0..<model.microphoneChannels, id: \.self) { Text("Input \($0 + 1)").tag($0) }
                }.labelsHidden().disabled(model.isPreviewing || model.isBusy)
            }
            if model.isPreviewing, model.microphoneChannels > 1, let channel = model.activeMicrophoneChannel {
                Text("Listening to input \(channel + 1)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var guideSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Guides & cursor").font(.headline)
            HStack {
                Toggle("Preview safe areas", isOn: $model.showsGuides)
                SettingHelp("Preview safe areas", "An 8% margin on the final output preview helps you place important content away from the edges. The guide spans the complete video, including all stacked panels. The full frame is saved without the guide or its shading. Platform controls vary, so this is a composition aid rather than a guaranteed platform safe zone.")
            }
            HStack {
                Toggle("Reserve caption space", isOn: $model.reservesCaptions).disabled(!model.showsGuides)
                SettingHelp("Caption space", "Mark the lower 20% of the final output preview for subtitles or platform labels. The guide appears only in the preview; every panel is still recorded in full.")
            }
            HStack {
                Toggle("Show cursor", isOn: $model.showsCursor).disabled(model.isPreviewing || model.isBusy)
                SettingHelp("Cursor", "Include your mouse pointer in the saved video. Capture frames and vcam controls stay excluded. Stop preview before changing this setting.")
            }
        }.toggleStyle(.switch).controlSize(.small)
    }

    private var folderSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingTitle("Save folder", help: "Each take gets a unique filename and opens in QuickTime Player after saving. vcam remembers access to this folder. Finish the current take before changing it.")
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(model.outputFolder?.lastPathComponent ?? "Choose a folder")
                    .lineLimit(1).truncationMode(.middle).help(model.outputFolder?.path ?? "Choose an output folder")
                Spacer()
                Button(model.outputFolder == nil ? "Choose…" : "Change…") { model.chooseOutputFolder() }
                    .disabled(model.isRecording || model.isBusy)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let notice = model.notice {
                HStack {
                    Text(notice).font(.caption).lineLimit(2)
                    Spacer()
                    if model.lastRecording != nil && !model.isRecording {
                        Button("Play") { model.openLastRecording() }
                        Button("Reveal") { model.revealLastRecording() }
                    }
                }.controlSize(.small)
            }
            HStack(spacing: 16) {
                microphoneMonitor
                Spacer(minLength: 16)
                if model.isRecording {
                    Button("Cancel take", role: .destructive) { Task { await model.cancelRecording() } }
                        .help("Discard this take and return to preview. No video from this take is saved.")
                    Button { Task { await model.restartRecording() } } label: {
                        Label("Restart take", systemImage: "arrow.counterclockwise")
                    }.help("Discard this take and immediately start a new recording.")
                    Button { Task { await model.finishRecording() } } label: {
                        Label("Finish", systemImage: "stop.fill").frame(minWidth: 78)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .help("Save this take and open it in QuickTime Player. Shift-Command-R")
                } else {
                    Button(model.isPreviewing ? "Stop preview" : "Start preview") { Task { await model.togglePreview() } }
                        .disabled(model.displays.isEmpty)
                    Button { Task { await model.toggleRecording() } } label: {
                        Label("Record", systemImage: "record.circle").frame(minWidth: 78)
                    }
                    .buttonStyle(.borderedProminent).disabled(model.displays.isEmpty)
                    .help("Start a recording: Shift-Command-R")
                }
            }
            .controlSize(.large).disabled(model.isBusy)
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var microphoneMonitor: some View {
        HStack(spacing: 10) {
            Image(systemName: model.selectedMicrophoneID.isEmpty ? "mic.slash" : "mic")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model.selectedMicrophoneID.isEmpty ? "Mic off" : model.isPreviewing ? model.decibelText : "Preview to test")
                        .font(.caption.monospacedDigit())
                    Spacer(minLength: 4)
                    SettingHelp("Peak level · dBFS", "This meter shows the microphone's digital peak level. 0 dBFS is the maximum and can clip. A reading near −∞ means no signal. Check your microphone and input channel in Setup if speaking does not move the meter.")
                }
                AudioMeter(level: model.audioLevel)
            }.frame(width: 180)
        }
    }

    private func settingTitle(_ title: String, help: String, prominent: Bool = true) -> some View {
        HStack(spacing: 7) {
            Text(title).font(prominent ? .headline : .callout)
            SettingHelp(title, help)
            Spacer(minLength: 0)
        }
    }

    private func syncDimensions(force: Bool = false) {
        if force || dimensionFocus != .width { widthText = dimensionString(model.activeCaptureFrame.width) }
        if force || dimensionFocus != .height { heightText = dimensionString(model.activeCaptureFrame.height) }
    }
    private func applyWidth() {
        if widthText != dimensionString(model.activeCaptureFrame.width), let number = Double(widthText) { model.setFrameWidth(number) }
        syncDimensions(force: true)
    }
    private func applyHeight() {
        if heightText != dimensionString(model.activeCaptureFrame.height), let number = Double(heightText) { model.setFrameHeight(number) }
        syncDimensions(force: true)
    }
    private func commitDimensions() {
        if dimensionFocus == .width { applyWidth() }
        if dimensionFocus == .height { applyHeight() }
    }
    private func dimensionString(_ value: CGFloat) -> String {
        Double(value).formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

struct SettingHelp: View {
    let title: String
    let detail: String
    @State private var isOpen = false
    init(_ title: String, _ detail: String) { self.title = title; self.detail = detail }
    var body: some View {
        Button { isOpen.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
            .buttonStyle(.plain).help(detail).accessibilityLabel("About \(title)")
            .popover(isPresented: $isOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(width: 300)
            }
    }
}

private struct AudioMeter: View {
    let level: Float
    private var normalized: Float { min(max((20 * log10(max(level, 0.000001)) + 60) / 60, 0), 1) }
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<28, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Float(index) / 28 < normalized ? (index > 25 ? Color.red : index > 21 ? Color.orange : Color.green) : Color.primary.opacity(0.09))
                    .frame(height: 10)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Microphone peak level")
    }
}
