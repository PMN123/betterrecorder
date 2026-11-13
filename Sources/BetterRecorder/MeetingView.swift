import AppKit
import SwiftUI

struct CaptureModeView: View {
    @ObservedObject var recorder: RecorderModel
    @ObservedObject var meeting: MeetingModel
    @State private var selectedMode = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Capture mode", selection: $selectedMode) {
                Text("Screen recording").tag(0)
                Text("Meeting mode").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 330)
            .padding(.top, 17)
            .padding(.bottom, 4)
            .disabled(recorder.isActive || meeting.isActive || recorder.state == .selecting || meeting.state == .selecting)

            if selectedMode == 0 {
                ScrollView { RecorderView(model: recorder) }
                    .frame(width: 560, height: min(830, visibleHeight - 110))
            } else {
                MeetingView(model: meeting)
            }
        }
        .background(Palette.background)
    }

    private var visibleHeight: CGFloat {
        NSScreen.main?.visibleFrame.height ?? 900
    }
}

struct MeetingView: View {
    @ObservedObject var model: MeetingModel
    @State private var chatSearch = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                header
                audioControls
                chatControls
                transcript
                actionRow
                if let message = model.errorMessage { errorBanner(message) }
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                    Text("Audio stays on this Mac. Only transcript text goes to your selected chat.")
                }
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 28).padding(.top, 23).padding(.bottom, 25)
        }
        .frame(width: 660, height: min(790, (NSScreen.main?.visibleFrame.height ?? 900) - 110))
        .background(Palette.background)
        .foregroundStyle(.white).tint(Palette.mint)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshMicrophones()
        }
        .task(id: chatSearch) {
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                await model.refreshChats(searchTerm: chatSearch)
            } catch { }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "waveform")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(Palette.background)
                .frame(width: 47, height: 47)
                .background(Palette.mint, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("Meeting mode").font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("A live transcript for the Codex chat you choose.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer()
            if model.isActive {
                Text(model.durationText).monospacedDigit()
                    .font(.system(size: 17, weight: .medium, design: .rounded))
            }
        }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 16) {
                Toggle("Mac audio", isOn: $model.captureSystemAudio)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Toggle("Microphone", isOn: $model.captureMicrophone)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
                Text("AUDIO ONLY").font(.system(size: 9, weight: .semibold)).tracking(1.3)
                    .foregroundStyle(Palette.muted)
            }
            if model.captureMicrophone {
                Picker("Microphone", selection: $model.selectedMicrophoneID) {
                    Text("System default microphone").tag("")
                    ForEach(model.microphones) { device in Text(device.name).tag(device.id) }
                }
                .font(.system(size: 11)).controlSize(.small)
            }
            Button { model.chooseSource() } label: {
                HStack {
                    Image(systemName: "speaker.wave.2").foregroundStyle(Palette.mint)
                    Text(model.sourceName).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Palette.muted)
                }
                .font(.system(size: 12)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("Choose a screen in the Mac sharing picker for its audio. No video is saved.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
        .padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 13))
        .disabled(model.isActive || model.state == .selecting)
    }

    private var chatControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SEND TRANSCRIPT TO").font(.system(size: 9, weight: .medium))
                    .tracking(1.3).foregroundStyle(Palette.muted)
                Spacer()
                if model.isLoadingChats { ProgressView().controlSize(.mini) }
                Button { Task { await model.refreshChats(searchTerm: chatSearch) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundStyle(Palette.mint)
                .help("Refresh Codex chats").accessibilityLabel("Refresh Codex chats")
                .disabled(model.isLoadingChats || model.isActive)
            }
            TextField("Find a chat (match title capitalization)", text: $chatSearch)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                .disabled(model.isActive)
            Picker("Codex chat", selection: $model.selectedChatID) {
                Text("Choose an existing Codex chat…").tag("")
                ForEach(matchingChats) { chat in
                    Text(chat.title).tag(chat.id)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity).controlSize(.regular)
            .disabled(model.isActive)
            if !model.selectedChatID.isEmpty {
                Button("Open selected chat in Codex") { Task { await model.openSelectedChat() } }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.mint)
                    .disabled(model.isActive)
            }
            Text(model.lastChatStatus.isEmpty ? "Uses your current Codex sign-in. Your chat keeps its existing context." : model.lastChatStatus)
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 13))
    }

    private var matchingChats: [CodexChat] {
        let query = chatSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.chats }
        return model.chats.filter { $0.id == model.selectedChatID || $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Circle().fill(model.isListening ? Palette.red : Palette.muted.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(model.isListening ? "LIVE TRANSCRIPT" : "TRANSCRIPT")
                    .font(.system(size: 9, weight: .medium)).tracking(1.3).foregroundStyle(Palette.muted)
                Spacer()
                if model.sessionFolder != nil {
                    Button("Open transcript") { model.revealTranscript() }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.mint)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.transcriptText.isEmpty && model.interimText.isEmpty {
                            Text("Spoken words will appear here. Transcription runs locally on your Mac.")
                                .foregroundStyle(Palette.muted).padding(.top, 10)
                        } else {
                            Text(model.transcriptText).textSelection(.enabled)
                            if !model.interimText.isEmpty {
                                Text(model.interimText).foregroundStyle(Palette.muted)
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                    .font(.system(size: 12)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 210)
                .onChange(of: model.transcriptText) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
                .onChange(of: model.interimText) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
            }
        }
        .padding(16)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 13))
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    if model.isActive { await model.stopMeeting() }
                    else if !model.hasSource { model.chooseSource() }
                    else { await model.startMeeting() }
                }
            } label: {
                HStack(spacing: 9) {
                    if model.state == .preparing || model.state == .stopping { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.isActive ? "stop.fill" : "waveform") }
                    Text(actionTitle).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(model.isActive ? .white : Palette.background)
                .frame(maxWidth: .infinity).frame(height: 47)
                .background(model.isActive ? Palette.red : Palette.mint, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(model.state == .stopping || model.state == .selecting || (!model.isActive && model.hasSource && !model.canStart))
            if model.isActive && model.captureMicrophone {
                Button { model.toggleMicrophoneMute() } label: {
                    Image(systemName: model.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(model.isMicrophoneMuted ? Palette.red : Palette.mint)
                        .frame(width: 49, height: 47)
                        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).disabled(!model.isListening)
                .accessibilityLabel(model.isMicrophoneMuted ? "Unmute meeting microphone" : "Mute meeting microphone")
            }
        }
    }

    private var actionTitle: String {
        switch model.state {
        case .selecting: return "Choosing Mac audio…"
        case .preparing: return "Cancel setup"
        case .stopping: return "Finishing transcript…"
        case .listening: return "Stop meeting"
        case .idle: return model.hasSource ? "Start meeting & send transcript" : "Choose Mac audio"
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.red)
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.clearError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss meeting error")
        }
        .padding(12).background(Palette.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
