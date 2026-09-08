import SwiftUI

struct ContentView: View {
    @Bindable var model: RecorderModel
    @State private var widthText = ""
    @State private var heightText = ""
    @FocusState private var dimensionFocus: Dimension?
    private enum Dimension { case width, height }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 24) {
                preview
                ScrollView { settings.padding(.trailing, 4) }
                    .frame(height: 540)
            }
            .padding(24)
            Divider()
            footer
        }
        .frame(width: 870)
        .background(.background)
        .task { model.prepare(); syncDimensions(); model.commitFrameEdits = { commitDimensions() } }
        .onDisappear { model.commitFrameEdits = nil }
        .onChange(of: model.activeCaptureFrame) { _, _ in syncDimensions(force: true) }
        .onChange(of: model.selectedRegion) { _, _ in syncDimensions(force: true) }
        .onChange(of: dimensionFocus) { previous, _ in
            if previous == .width { applyWidth() }
            if previous == .height { applyHeight() }
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
            Image(systemName: "viewfinder").font(.system(size: 24, weight: .medium)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("vcam").font(.system(size: 21, weight: .semibold, design: .rounded))
                Text("A camera for your screen").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refreshPermissions(); model.showOnboarding = true } label: {
                Label(model.permissionsReady ? "Access ready" : "Set up access", systemImage: model.permissionsReady ? "checkmark.shield" : "lock.open")
            }
            .disabled(model.isRecording || model.isBusy)
            HStack(spacing: 7) {
                Circle().fill(model.isRecording ? Color.red : model.isPreviewing ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(model.statusText).font(.callout.monospacedDigit())
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Output preview").font(.callout.weight(.medium))
                SettingHelp("Output preview", "A live view of what will be saved. The native video preview refreshes at up to 30 fps. Guides and vcam controls never appear in the recording.")
                Spacer()
                Text(model.orientation.ratioLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                CameraPreview(surface: model.previewSurface).opacity(model.isPreviewing ? 1 : 0)
                if !model.isPreviewing {
                    VStack(spacing: 14) {
                        Image(systemName: "rectangle.portrait.dashed").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.secondary)
                        Text("Frame your next take").font(.headline)
                        Text("Place your frames over any app.\nStart preview to see your shot.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(model.hasTwoRegions ? "Show frames" : "Show frame") { model.showFrame() }.disabled(model.isBusy)
                    }.padding(14)
                }
            }
            .frame(width: 256, height: model.orientation == .portrait ? 455 : 256 * 9 / 16)
            .overlay {
                if model.isPreviewing {
                    CompositionDivider(layout: model.layout,
                        splitRatio: Binding(get: { model.splitRatio }, set: { model.setSplitRatio($0) }),
                        isEnabled: !model.isBusy)
                    if model.cameraPlacement == .overlay {
                        CameraOverlayControls(
                            configuration: Binding(get: { model.cameraOverlay }, set: { model.setCameraOverlay($0) }),
                            outputSize: model.outputSize, isEnabled: !model.isBusy)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.10)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.isPreviewing ? "Live video preview" : "Preview is off")
            Text(model.outputDimensions + " output pixels").font(.caption.monospacedDigit())
            Text(model.cameraPlacement == .overlay
                 ? "Drag your camera to move it, or drag its corner to resize. Placement changes are recorded."
                 : model.hasTwoRegions ? "Both regions are saved in one video. Drag the preview divider to adjust the split, even while recording." : "Guides are only for you. The full frame is recorded.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(width: 256)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Display").frame(width: 90, alignment: .leading)
                Picker("Display", selection: Binding(get: { model.selectedDisplayID }, set: { model.selectDisplay($0) })) {
                    ForEach(model.displays) { display in Text(display.name).tag(display.id) }
                }.labelsHidden().disabled(model.isPreviewing || model.isBusy)
                SettingHelp("Display", "Choose the display to capture. Both regions can move independently anywhere inside this display. Stop preview before switching displays.")
            }
            HStack {
                Text("Orientation").frame(width: 90, alignment: .leading)
                Picker("Orientation", selection: Binding(get: { model.orientation }, set: { value in Task { await model.setOrientation(value) } })) {
                    ForEach(CaptureOrientation.allCases) { Text($0.title + " " + $0.ratioLabel).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).disabled(model.isRecording || model.isBusy)
                SettingHelp("Orientation", "Portrait is 9:16 for vertical videos. Landscape is 16:9. Changing orientation reshapes the frame and swaps the output dimensions. Stop recording before changing it.")
            }
            HStack {
                Text("Output").frame(width: 90, alignment: .leading)
                Picker("Resolution", selection: $model.resolution) {
                    ForEach(OutputResolution.allCases) { resolution in
                        let size = resolution.size(for: model.orientation)
                        Text("\(resolution.title)  ·  \(Int(size.width)) × \(Int(size.height))").tag(resolution)
                    }
                }.labelsHidden().disabled(model.isPreviewing || model.isBusy)
                SettingHelp("Output resolution", "The dimensions of the saved video, in pixels. Here 2K means 1440p: 1440 × 2560 in portrait. It stores more detail when the captured area has enough source pixels, with more GPU work and larger files.")
            }
            HStack {
                Text("Frame rate").frame(width: 90, alignment: .leading)
                Picker("Frame rate", selection: $model.framesPerSecond) {
                    Text("30 fps · default").tag(30)
                    Text("60 fps · smoother motion").tag(60)
                }.labelsHidden().disabled(model.isPreviewing || model.isBusy)
                SettingHelp("Frame rate", "30 frames per second is the default for ordinary screen demos. 60 fps records smoother fast scrolling and motion, using more processing and storage. Preview is capped at 30 fps.")
            }
            Divider()
            compositionSettings
            Divider()
            CameraSettingsView(model: model)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if model.hasTwoRegions {
                    HStack {
                        Text("Edit region").frame(width: 90, alignment: .leading)
                        Picker("Edit region", selection: Binding(get: { model.selectedRegion }, set: { model.selectRegion($0) })) {
                            ForEach(CaptureRegion.allCases) { Text(model.regionTitle($0)).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).disabled(model.isBusy)
                        SettingHelp("Edit region", "Blue A is the left or top view; orange B is the right or bottom view. Select a region to change its capture size, or drag its handle on screen to move it independently. Each handle has its own horizontal and vertical movement lock.")
                    }
                }
                if model.activeRegionIsCamera {
                    Label("Camera fills \(model.regionTitle(model.selectedRegion))", systemImage: "video.fill")
                        .font(.callout.weight(.medium))
                    Text("Use the split to resize this panel. The camera is cropped to fill without stretching.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text(model.hasTwoRegions ? "\(model.regionTitle(model.selectedRegion)) size" : "Frame size").font(.callout.weight(.medium))
                        SettingHelp("Frame size and points", "Points (pt) measure the region's size on your Mac, not the saved video's resolution. On a 2× Retina display, 540 × 960 pt contains 1080 × 1920 source pixels. Width and height stay linked to this region's part of the output, so content keeps its shape. Larger frames fit more content; smaller ones magnify it.")
                        Spacer()
                        Text(model.activeAspectLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("W").foregroundStyle(.secondary)
                        TextField("Width", text: $widthText).frame(width: 74).focused($dimensionFocus, equals: .width).onSubmit { applyWidth() }
                            .accessibilityLabel("Frame width in screen points")
                        Text("×").foregroundStyle(.secondary)
                        Text("H").foregroundStyle(.secondary)
                        TextField("Height", text: $heightText).frame(width: 74).focused($dimensionFocus, equals: .height).onSubmit { applyHeight() }
                            .accessibilityLabel("Frame height in screen points")
                        Text("pt").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { model.frameWidth }, set: { model.setFrameWidth($0) }),
                               in: model.minimumFrameWidth...max(model.minimumFrameWidth, model.maximumFrameWidth), step: 2)
                            .accessibilityLabel("Recording frame size")
                    }.disabled(model.isRecording || model.isBusy)
                    HStack(spacing: 5) {
                        Image(systemName: model.isUpscaling ? "arrow.up.right" : "checkmark.circle")
                        Text(model.sourceSizeText + (model.isUpscaling ? " · scaled up to \(model.hasTwoRegions ? "panel" : "output")" : ""))
                    }.font(.caption).foregroundStyle(model.isUpscaling ? Color.orange : Color.secondary)
                }
            }
            Divider()
            HStack {
                Text("Microphone").frame(width: 90, alignment: .leading)
                Picker("Microphone", selection: $model.selectedMicrophoneID) {
                    Text("No microphone").tag("")
                    ForEach(model.microphones) { Text($0.name).tag($0.id) }
                }.labelsHidden().disabled(model.isPreviewing || model.isBusy)
                    .onChange(of: model.selectedMicrophoneID) { _, _ in model.microphoneChannel = -1; model.refreshPermissions() }
                Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel("Refresh microphones").disabled(model.isPreviewing || model.isBusy)
                SettingHelp("Microphone", "Choose your physical microphone or audio interface. Start preview and speak to check the meter before recording. Screen access and microphone access are separate permissions.")
            }
            if model.microphoneChannels > 1 && !model.selectedMicrophoneID.isEmpty {
                HStack {
                    Text("Input channel").frame(width: 90, alignment: .leading)
                    Picker("Input channel", selection: $model.microphoneChannel) {
                        Text("Auto · inputs 1–2").tag(-1)
                        ForEach(0..<model.microphoneChannels, id: \.self) { Text("Input \($0 + 1)").tag($0) }
                    }.labelsHidden().disabled(model.isPreviewing || model.isBusy)
                    SettingHelp("Input channel", "Audio interfaces can expose several inputs. Choose the one your microphone is plugged into. Auto uses the strongest of the first two inputs and locks that choice for the take. On the Scarlett, channels 3–4 are loopback channels.")
                }
            }
            HStack(spacing: 9) {
                AudioMeter(level: model.audioLevel)
                Text(model.selectedMicrophoneID.isEmpty ? "Mic off" : model.isPreviewing ? model.decibelText : "Preview to test")
                    .font(.caption.monospacedDigit()).frame(minWidth: 86, alignment: .trailing)
                SettingHelp("Peak level · dBFS", "This shows the microphone's digital peak level, not room loudness. 0 dBFS is the maximum and can clip. A value near −∞ means no input signal. Check the selected input channel if the meter does not move when you speak.")
            }
            if model.isPreviewing, model.microphoneChannels > 1, let channel = model.activeMicrophoneChannel {
                Text("Listening to input \(channel + 1)").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Toggle("Edge guides", isOn: $model.showsGuides).toggleStyle(.switch).controlSize(.small)
                SettingHelp("Edge guides", "A small 8% margin on each side helps keep important details away from platform controls and device cropping. Everything inside the outer recording frame is saved, including the shaded margins. These are general composition guides, not guaranteed platform safe zones.")
                Toggle("Reserve caption space", isOn: $model.reservesCaptions).toggleStyle(.switch).controlSize(.small).disabled(!model.showsGuides)
                SettingHelp("Caption space", "Optionally reserve the lower 20% for subtitles or platform labels. This is a visual reminder only. No content is removed from the recording.")
            }
            HStack {
                Toggle("Show cursor", isOn: $model.showsCursor).toggleStyle(.switch).controlSize(.small).disabled(model.isPreviewing || model.isBusy)
                SettingHelp("Cursor", "Include your mouse pointer in the video. The floating frame and its controls remain excluded. Stop preview before changing this setting.")
                Spacer()
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(model.outputFolder?.lastPathComponent ?? "Save folder").lineLimit(1).help(model.outputFolder?.path ?? "Choose an output folder")
                Button(model.outputFolder == nil ? "Choose…" : "Change…") { model.chooseOutputFolder() }.disabled(model.isRecording || model.isBusy)
                SettingHelp("Save folder", "Choose where recordings are saved. vcam remembers permission for this folder. Each take gets a unique filename and opens in QuickTime Player after saving. Use Play to reopen it or Reveal to find the file.")
            }
            if model.isPreviewing && !model.isRecording {
                Text("Stop preview to change output, frame rate, microphone, or cursor.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).controlSize(.regular)
    }

    private var compositionSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layout").frame(width: 90, alignment: .leading)
                CompositionLayoutPicker(selection: Binding(get: { model.layout }, set: { model.setLayout($0) }),
                    isEnabled: !model.isRecording && !model.isBusy)
                SettingHelp("Layout", "Single records one region. Side by side places A on the left and B on the right. Stacked places A above B. Two movable frames capture separate parts of the same display into one video. Stop recording before changing layouts.")
            }
            if model.hasTwoRegions {
                HStack {
                    Text("Split").frame(width: 90, alignment: .leading)
                    Slider(value: Binding(get: { model.splitRatio }, set: { model.setSplitRatio($0) }), in: 0.15...0.85)
                        .accessibilityLabel("Region A share of output")
                        .accessibilityValue(model.splitDescription)
                    Text(model.splitDescription).font(.caption.monospacedDigit()).frame(width: 110)
                    Button("50/50") { model.setSplitRatio(0.5) }
                    SettingHelp("Split", "Give either region 15% to 85% of the output. Drag the divider in the live preview or use this slider, including during recording. Source frames resize around their centers to match, with no stretching. The divider and region labels are guides only and are not saved.")
                }.disabled(model.isBusy)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let notice = model.notice {
                HStack {
                    Text(notice).font(.caption).lineLimit(2)
                    Spacer()
                    if model.lastRecording != nil {
                        Button("Play") { model.openLastRecording() }
                        Button("Reveal") { model.revealLastRecording() }
                    }
                }
            }
            HStack(spacing: 10) {
                Button(model.isFrameVisible ? (model.hasTwoRegions ? "Hide frames" : "Hide frame") : (model.hasTwoRegions ? "Show frames" : "Show frame")) { model.toggleFrame() }.disabled(model.isRecording || model.isBusy)
                Text("⇧⌘F").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.isPreviewing ? "Stop preview" : "Start preview") { Task { await model.togglePreview() } }
                    .disabled(model.isRecording || model.isBusy || model.displays.isEmpty)
                Button { Task { await model.toggleRecording() } } label: {
                    Label(model.isRecording ? "Stop & save" : "Record", systemImage: model.isRecording ? "stop.fill" : "record.circle").frame(minWidth: 112)
                }.buttonStyle(.borderedProminent).tint(model.isRecording ? .red : .accentColor)
                    .disabled(model.isBusy || model.displays.isEmpty).help("Record or stop: Shift-Command-R")
                Text("⇧⌘R").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
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
