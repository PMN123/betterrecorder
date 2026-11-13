import AppKit
import SwiftUI

@MainActor
enum AppServices {
    static let recorder = RecorderModel()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppServices.recorder.isActive else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await AppServices.recorder.stopRecording()
            terminating = false
            let savedCleanly = !AppServices.recorder.isActive && AppServices.recorder.errorMessage == nil
            sender.reply(toApplicationShouldTerminate: savedCleanly)
            if !savedCleanly {
                sender.windows.first(where: { $0.title == "BetterRecorder" })?.makeKeyAndOrderFront(nil)
                sender.activate(ignoringOtherApps: true)
            }
        }
        return .terminateLater
    }
}

@main
struct BetterRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = AppServices.recorder

    var body: some Scene {
        Window("BetterRecorder", id: "recorder") {
            RecorderView(model: recorder)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Recording") {
                Button(recorder.isActive ? "Stop Recording" : "Start Recording") {
                    Task {
                        if recorder.isActive { await recorder.stopRecording() }
                        else if recorder.hasSource { await recorder.startRecording() }
                        else { recorder.chooseSource() }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(recorder.state == .finishing || recorder.state == .selecting)
                Button(recorder.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone") {
                    recorder.toggleMicrophoneMute()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!recorder.isRecording || !recorder.captureMicrophone)
                Button("Choose Screen or Window…") { recorder.chooseSource() }
                    .disabled(recorder.isActive)
                Button("Open Recordings Folder") { recorder.revealOutputFolder() }
            }
        }

        MenuBarExtra {
            RecorderMenu(model: recorder)
        } label: {
            Image(systemName: recorder.isActive ? "record.circle.fill" : "record.circle")
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel(recorder.isActive ? "BetterRecorder recording" : "BetterRecorder")
        }
    }
}

private struct RecorderMenu: View {
    @ObservedObject var model: RecorderModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isActive ? "Recording · \(model.durationText)" : "BetterRecorder")
        Button("Show BetterRecorder") {
            openWindow(id: "recorder")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        if model.isActive {
            Button(model.state == .finishing ? "Saving…" : "Stop & Save Recording") {
                Task { await model.stopRecording() }
            }
            .disabled(model.state == .finishing)
            if model.captureMicrophone {
                Button(model.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone") {
                    model.toggleMicrophoneMute()
                }
                .disabled(!model.isRecording)
            }
        } else {
            Button(model.hasSource ? "Start Recording" : "Choose Screen or Window…") {
                if model.hasSource { Task { await model.startRecording() } }
                else { model.chooseSource() }
            }
            .disabled(model.state == .selecting)
        }
        Button("Open Recordings Folder") { model.revealOutputFolder() }
        Divider()
        Button("Quit BetterRecorder") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
