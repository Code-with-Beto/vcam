import SwiftUI
import AVFoundation

struct PermissionSetupView: View {
    @Bindable var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "viewfinder").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Let’s get vcam ready").font(.title2.weight(.semibold))
                    Text("Set up access once, then frame and record.").foregroundStyle(.secondary)
                }
            }
            permissionRow(
                title: "Screen recording",
                detail: "Required for the live preview and saved screen video.",
                granted: model.screenAccessGranted,
                button: model.requestedScreenAccess ? "Open Settings" : "Enable screen access"
            ) {
                if model.requestedScreenAccess { model.openScreenPermissions() }
                else { model.requestScreenAccess() }
            }
            Divider()
            permissionRow(
                title: "Microphone",
                detail: model.selectedMicrophoneID.isEmpty ? "Microphone is off. Your video will have no voice track." : "Records the microphone or audio interface you select.",
                granted: model.microphoneAuthorization == .authorized || model.selectedMicrophoneID.isEmpty,
                button: model.microphoneAuthorization == .notDetermined ? "Enable microphone" : "Open Settings"
            ) { Task { await model.requestMicrophoneAccess() } }
            .disabled(model.requestingMicrophone)
            if !model.selectedMicrophoneID.isEmpty && model.microphoneAuthorization != .authorized {
                Button("Continue without a microphone") {
                    model.selectedMicrophoneID = ""
                    model.refreshPermissions()
                }.buttonStyle(.link)
            }
            if model.requestedScreenAccess && !model.screenAccessGranted {
                VStack(alignment: .leading, spacing: 8) {
                    Label("If access is enabled but still not detected", systemImage: "arrow.clockwise")
                        .font(.callout.weight(.medium))
                    Text("macOS may need vcam to restart after screen access changes. Quit vcam, then run it again from Xcode with ⌘R.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Recheck access") { model.refreshPermissions() }
                        Button("Quit vcam") { NSApp.terminate(nil) }
                    }
                }
                .padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("You can position the frame without granting access. vcam only starts capture when you choose Start preview or Record.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Set up later") { model.showOnboarding = false }
                Spacer()
                Button("Recheck") { model.refreshPermissions() }
                Button("Ready to record") { model.showOnboarding = false }
                    .buttonStyle(.borderedProminent).disabled(!model.permissionsReady)
            }
        }
        .padding(28).frame(width: 520)
        .onAppear { model.refreshPermissions() }
    }

    private func permissionRow(title: String, detail: String, granted: Bool,
                               button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.green : Color.secondary).font(.title3)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if granted { Text("Ready").foregroundStyle(.green).font(.callout) }
            else { Button(button, action: action) }
        }
    }
}
