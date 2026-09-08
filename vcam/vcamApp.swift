import SwiftUI
import AppKit

@main
struct vcamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = RecorderModel()

    var body: some Scene {
        Window("vcam", id: "recorder") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 900)
        .defaultPosition(.center)
        .commands {
            CommandMenu("Capture") {
                Button("Start Recording") { Task { await model.toggleRecording() } }
                    .disabled(model.isRecording || model.isBusy)
                Button("Finish Take") { Task { await model.finishRecording() } }
                    .disabled(!model.isRecording || model.isBusy)
                Button("Restart Take") { Task { await model.restartRecording() } }
                    .disabled(!model.isRecording || model.isBusy)
                Button("Cancel Take", role: .destructive) { Task { await model.cancelRecording() } }
                    .disabled(!model.isRecording || model.isBusy)
                Divider()
                Button(model.isFrameVisible ? "Hide Frame" : "Show Frame") { model.toggleFrame() }
                    .disabled(model.isRecording || model.isBusy)
                Divider()
                Button("Show Last Recording in Finder") { model.revealLastRecording() }
                    .disabled(model.lastRecording == nil)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RecorderModel?
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        guard let model else { return .terminateNow }
        // Finish the movie before the process exits, including a quit from the Dock.
        isTerminating = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
