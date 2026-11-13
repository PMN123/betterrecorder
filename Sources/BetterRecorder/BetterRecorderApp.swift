import AppKit
import SwiftUI

@MainActor
enum AppServices {
    static let recorder = RecorderModel()
    static let meeting = MeetingModel()
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
        guard AppServices.recorder.isActive || AppServices.meeting.isActive else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await AppServices.recorder.stopRecording()
            await AppServices.meeting.stopMeeting()
            terminating = false
            let savedCleanly = !AppServices.recorder.isActive && !AppServices.meeting.isActive
                && AppServices.recorder.errorMessage == nil && AppServices.meeting.errorMessage == nil
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
    @StateObject private var meeting = AppServices.meeting

    var body: some Scene {
        Window("BetterRecorder", id: "recorder") {
            CaptureModeView(recorder: recorder, meeting: meeting)
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
                .disabled(meeting.isActive || meeting.state == .selecting)
                Button(recorder.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone") {
                    recorder.toggleMicrophoneMute()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!recorder.isRecording || !recorder.captureMicrophone)
                Button("Choose Screen or Window…") { recorder.chooseSource() }
                    .disabled(recorder.isActive || meeting.isActive || meeting.state == .selecting)
                Button("Open Recordings Folder") { recorder.revealOutputFolder() }
            }
            CommandMenu("Meeting") {
                Button(meeting.isActive ? "Stop Meeting" : "Start Meeting") {
                    Task {
                        if meeting.isActive { await meeting.stopMeeting() }
                        else if !meeting.hasSource { meeting.chooseSource() }
                        else { await meeting.startMeeting() }
                    }
                }
                .disabled(recorder.isActive || meeting.state == .stopping || (!meeting.isActive && !meeting.canStart))
                Button(meeting.isMicrophoneMuted ? "Unmute Meeting Microphone" : "Mute Meeting Microphone") {
                    meeting.toggleMicrophoneMute()
                }.disabled(!meeting.isListening || !meeting.captureMicrophone)
                Button("Open Meeting Transcript") { meeting.revealTranscript() }
                    .disabled(meeting.sessionFolder == nil)
            }
        }

        MenuBarExtra {
            RecorderMenu(model: recorder, meeting: meeting)
        } label: {
            Image(systemName: recorder.isActive || meeting.isActive ? "record.circle.fill" : "record.circle")
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel(recorder.isActive || meeting.isActive ? "BetterRecorder recording" : "BetterRecorder")
        }
    }
}

private struct RecorderMenu: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var meeting: MeetingModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isActive ? "Recording · \(model.durationText)" : "BetterRecorder")
        Button("Show BetterRecorder") {
            openWindow(id: "recorder")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        if meeting.isActive {
            Text("Meeting · \(meeting.durationText)")
            Button("Stop Meeting") { Task { await meeting.stopMeeting() } }
                .disabled(meeting.state == .stopping)
            if meeting.captureMicrophone {
                Button(meeting.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone") {
                    meeting.toggleMicrophoneMute()
                }.disabled(!meeting.isListening)
            }
        } else if model.isActive {
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
