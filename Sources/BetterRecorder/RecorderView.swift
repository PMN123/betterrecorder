import AppKit
import SwiftUI

enum Palette {
    static let background = Color(red: 0.055, green: 0.071, blue: 0.086)
    static let panel = Color(red: 0.094, green: 0.114, blue: 0.133)
    static let mint = Color(red: 0.56, green: 0.95, blue: 0.79)
    static let muted = Color(red: 0.56, green: 0.61, blue: 0.66)
    static let red = Color(red: 1, green: 0.36, blue: 0.39)
}

struct RecorderView: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            hero
            sourceCard
            optionsCard
            folderRow
            actionRow
            footer
            if let message = model.errorMessage {
                errorBanner(message)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 34)
        .padding(.bottom, 25)
        .frame(width: 560)
        .background {
            ZStack {
                Palette.background
                RadialGradient(colors: [Palette.mint.opacity(0.075), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 420)
            }
        }
        .tint(Palette.mint)
        .foregroundStyle(.white)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshMicrophones()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Palette.mint)
                Image(systemName: "record.circle")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Palette.background)
            }
            .frame(width: 47, height: 47)
            VStack(alignment: .leading, spacing: 3) {
                Text("BetterRecorder").font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("Your screen. Your Mac’s sound.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Text("LOCAL RECORDER")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(Palette.muted)
        }
    }

    private var hero: some View {
        VStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(Palette.panel)
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.mint.opacity(0.2), lineWidth: 1))
                HStack(alignment: .center, spacing: 5) {
                    ForEach(Array([12.0, 23, 35, 18, 44, 29, 52, 36, 19, 32, 43, 24, 12].enumerated()), id: \.offset) { _, height in
                        Capsule()
                            .fill(Palette.mint.opacity(model.captureSystemAudio ? 0.8 : 0.15))
                            .frame(width: 5, height: height)
                    }
                }
                VStack {
                    HStack {
                        Circle().fill(model.isRecording ? Palette.red : Palette.mint.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Spacer()
                        Image(systemName: model.captureSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 9)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                }.padding(12)
            }
            .frame(width: 188, height: 104)
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.muted.opacity(0.4))
                    .frame(width: 40, height: 3).offset(y: 8)
            }
            .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(heroTitle)
                    .font(.system(size: model.isActive ? 33 : 23, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 6) {
                    if model.isRecording {
                        Circle().fill(Palette.red).frame(width: 6, height: 6)
                    }
                    Text(heroSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }.padding(.top, 9)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var heroTitle: String {
        switch model.state {
        case .countdown: return "\(model.countdownRemaining)"
        case .starting: return "Starting…"
        case .recording: return model.durationText
        case .finishing: return "Saving…"
        case .selecting: return "Pick your view."
        case .idle: return "Ready when you are."
        }
    }

    private var heroSubtitle: String {
        if model.isRecording {
            let mic = model.captureMicrophone ? (model.isMicrophoneMuted ? " · Mic muted" : " · Mic on") : ""
            return "Recording\(mic)"
        }
        if model.state == .countdown { return "Recording begins in a moment" }
        if model.state == .finishing { return "Finishing your MP4 file" }
        if model.state == .selecting { return "Choose a screen or window in the Mac picker" }
        return "Capture a screen or window, with sound included."
    }

    private var sourceCard: some View {
        Button { model.chooseSource() } label: {
            HStack(spacing: 13) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 22)).foregroundStyle(Palette.mint)
                    .frame(width: 29)
                VStack(alignment: .leading, spacing: 5) {
                    Text("RECORDING SOURCE")
                        .font(.system(size: 9, weight: .medium)).tracking(1.4)
                        .foregroundStyle(Palette.muted)
                    Text(model.sourceName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(16)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.055), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(model.isActive || model.state == .selecting)
        .accessibilityLabel("Choose screen or window")
    }

    private var optionsCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2").font(.system(size: 16)).frame(width: 23)
                    .foregroundStyle(Palette.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("System audio").font(.system(size: 13, weight: .medium))
                    Text("Sound from apps playing on your Mac.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Toggle("System audio", isOn: $model.captureSystemAudio).labelsHidden().toggleStyle(.switch)
                    .controlSize(.small)
            }
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            HStack(spacing: 12) {
                Image(systemName: "mic").font(.system(size: 16)).frame(width: 23)
                    .foregroundStyle(Palette.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Microphone").font(.system(size: 13, weight: .medium))
                    Text("Add your voice. Mute or unmute while recording.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Toggle("Record microphone", isOn: $model.captureMicrophone)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if model.captureMicrophone {
                HStack(spacing: 9) {
                    Picker("Microphone source", selection: $model.selectedMicrophoneID) {
                        Text("System default microphone").tag("")
                        ForEach(model.microphones) { microphone in
                            Text(microphone.name).tag(microphone.id)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.refreshMicrophones() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help("Refresh microphone sources").accessibilityLabel("Refresh microphone sources")
                }
                .padding(.leading, 35)
            }
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            HStack(spacing: 20) {
                Toggle("Show cursor", isOn: $model.showsCursor)
                    .font(.system(size: 11)).toggleStyle(.checkbox)
                Toggle("3-second countdown", isOn: $model.usesCountdown)
                    .font(.system(size: 11)).toggleStyle(.checkbox)
                Spacer(minLength: 0)
                Picker("Frame rate", selection: $model.frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 81).controlSize(.small)
            }
        }
        .padding(16)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        .disabled(model.isActive)
    }

    private var folderRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder").foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text("SAVE TO").font(.system(size: 8, weight: .medium)).tracking(1.1)
                    .foregroundStyle(Palette.muted)
                Text(folderDisplayName).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Change…") { model.chooseOutputFolder() }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.mint)
                .disabled(model.isActive)
        }
        .padding(.horizontal, 3)
    }

    private var folderDisplayName: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = model.outputFolder.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            actionButton
            if model.isActive && model.captureMicrophone {
                Button { model.toggleMicrophoneMute() } label: {
                    VStack(spacing: 3) {
                        Image(systemName: model.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 16, weight: .medium))
                        Text(model.isMicrophoneMuted ? "Unmute" : "Mute")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(model.isMicrophoneMuted ? Palette.red : Palette.mint)
                    .frame(width: 65, height: 49)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!model.isRecording)
                .help(model.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone")
                .accessibilityLabel(model.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone")
            }
        }
    }

    private var actionButton: some View {
        Button {
            Task {
                if model.isActive { await model.stopRecording() }
                else if model.hasSource { await model.startRecording() }
                else { model.chooseSource() }
            }
        } label: {
            HStack(spacing: 10) {
                if model.state == .finishing || model.state == .starting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.isActive ? "stop.fill" : "record.circle")
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(actionTitle).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(model.isActive ? .white : Palette.background)
            .frame(maxWidth: .infinity).frame(height: 49)
            .background(model.isActive ? Palette.red.opacity(0.9) : Palette.mint, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(model.state == .finishing || model.state == .selecting)
        .accessibilityLabel(actionTitle)
    }

    private var actionTitle: String {
        if model.state == .countdown { return "Cancel countdown" }
        if model.state == .finishing { return "Saving recording…" }
        if model.isActive { return "Stop & save recording" }
        if model.state == .selecting { return "Choosing source…" }
        return model.hasSource ? "Start recording" : "Choose screen or window"
    }

    private var footer: some View {
        Group {
            if let recording = model.latestRecording {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recording saved").font(.system(size: 11, weight: .medium))
                        Text(recording.lastPathComponent).font(.system(size: 10))
                            .foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Spacer()
                    Button { model.openLatestRecording() } label: { Image(systemName: "play.circle") }
                        .help("Play recording").accessibilityLabel("Play latest recording")
                    Button { model.revealLatestRecording() } label: { Image(systemName: "folder") }
                        .help("Show in Finder").accessibilityLabel("Show latest recording in Finder")
                }
                .buttonStyle(.plain).font(.system(size: 17))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                    Text("Saved on this Mac · MP4 · Up to 4K")
                }
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 31)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.red)
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.clearError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss error")
        }
        .padding(12)
        .background(Palette.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}
