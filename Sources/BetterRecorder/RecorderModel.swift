import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

struct MicrophoneDevice: Identifiable {
    let id: String
    let name: String
}

@MainActor
final class RecorderModel: NSObject, ObservableObject {
    enum RecordingState { case idle, selecting, countdown, starting, recording, finishing }

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var sourceName = "Choose a screen or window"
    @Published private(set) var hasSource = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var fileSize: Int64 = 0
    @Published private(set) var latestRecording: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var countdownRemaining = 0
    @Published var captureSystemAudio = true
    @Published var captureMicrophone = false
    @Published private(set) var microphones: [MicrophoneDevice] = []
    @Published var selectedMicrophoneID = ""
    @Published private(set) var isMicrophoneMuted = false
    @Published var showsCursor = true
    @Published var frameRate = 30
    @Published var usesCountdown = true
    @Published var outputFolder: URL {
        didSet { UserDefaults.standard.set(outputFolder.path, forKey: Self.folderKey) }
    }

    private static let folderKey = "BetterRecorder.outputFolder"
    private var filter: SCContentFilter?
    private var stream: SCStream?
    private var writer: CaptureWriter?
    private var finishingWriter = false
    private var deviceObservers: [NSObjectProtocol] = []
    private var pendingURL: URL?
    private var generation = 0
    private var stopRequested = false
    private var stopCompleted = false
    private var recordingFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var progressTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var startTimeoutTask: Task<Void, Never>?

    override init() {
        let saved = UserDefaults.standard.string(forKey: Self.folderKey)
        outputFolder = saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/BetterRecorder", isDirectory: true)
        super.init()
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        if let bundleID = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundleID] }
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        refreshMicrophones()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshMicrophones() }
            })
        }
    }

    func refreshMicrophones() {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        microphones = session.devices.map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func toggleMicrophoneMute() {
        guard state == .recording, captureMicrophone, let writer else { return }
        isMicrophoneMuted.toggle()
        writer.setMicrophoneMuted(isMicrophoneMuted)
    }

    var isActive: Bool { state == .countdown || state == .starting || state == .recording || state == .finishing }
    var isRecording: Bool { state == .recording }
    var canRecord: Bool { state == .idle && hasSource }
    var durationText: String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
    var fileSizeText: String { ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) }
    var statusText: String {
        switch state {
        case .idle: return hasSource ? "Ready to record" : "Choose what to record"
        case .selecting: return "Choose a screen or window"
        case .countdown: return "Starting in \(countdownRemaining)"
        case .starting: return "Starting recording…"
        case .recording: return "Recording"
        case .finishing: return "Finishing recording…"
        }
    }

    func chooseSource() {
        guard state == .idle else { return }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        configuration.allowsChangingSelectedContent = false
        if let id = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [id] }
        SCContentSharingPicker.shared.defaultConfiguration = configuration
        errorMessage = nil
        state = .selecting
        SCContentSharingPicker.shared.present()
    }

    func startRecording() async {
        guard canRecord, let filter else { return }
        generation += 1
        let currentGeneration = generation
        errorMessage = nil
        elapsed = 0
        fileSize = 0
        stopRequested = false
        stopCompleted = false
        recordingFinished = false
        finishingWriter = false
        isMicrophoneMuted = false
        if usesCountdown {
            state = .countdown
            for count in stride(from: 3, through: 1, by: -1) {
                countdownRemaining = count
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch {
                    if generation == currentGeneration { state = .idle; countdownRemaining = 0 }
                    return
                }
                guard generation == currentGeneration, state == .countdown else { return }
            }
            countdownRemaining = 0
        }
        state = .starting
        do {
            if captureMicrophone {
                let allowed: Bool
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: allowed = true
                case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
                default: allowed = false
                }
                guard generation == currentGeneration, state == .starting else { return }
                guard allowed else { throw RecorderError.microphoneDenied }
                refreshMicrophones()
                if !selectedMicrophoneID.isEmpty && !microphones.contains(where: { $0.id == selectedMicrophoneID }) {
                    throw RecorderError.microphoneUnavailable
                }
            }
            armStartTimeout()
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let filename = "BetterRecorder \(formatter.string(from: Date())) \(UUID().uuidString.prefix(6)).mp4"
            let url = outputFolder.appendingPathComponent(filename)
            let width = Double(filter.contentRect.width) * Double(filter.pointPixelScale)
            let height = Double(filter.contentRect.height) * Double(filter.pointPixelScale)
            guard width.isFinite, height.isFinite, width >= 2, height >= 2 else {
                throw RecorderError.invalidDimensions
            }
            let scale = min(1, 3840 / max(width, height))
            let config = SCStreamConfiguration()
            config.width = max(2, Int(width * scale) / 2 * 2)
            config.height = max(2, Int(height * scale) / 2 * 2)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate == 60 ? 60 : 30))
            config.showsCursor = showsCursor
            config.capturesAudio = captureSystemAudio
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
            config.captureMicrophone = captureMicrophone
            if captureMicrophone && !selectedMicrophoneID.isEmpty {
                config.microphoneCaptureDeviceID = selectedMicrophoneID
            }
            let newWriter = try CaptureWriter(url: url, width: config.width, height: config.height,
                                              frameRate: frameRate == 60 ? 60 : 30,
                                              captureSystemAudio: captureSystemAudio,
                                              captureMicrophone: captureMicrophone)
            newWriter.onStarted = { [weak self, weak newWriter] in
                Task { @MainActor in
                    guard let self, let newWriter, self.writer === newWriter, self.state == .starting else { return }
                    self.startTimeoutTask?.cancel(); self.startTimeoutTask = nil
                    self.state = .recording
                    self.startProgressUpdates(for: newWriter)
                }
            }
            newWriter.onFailure = { [weak self, weak newWriter] error in
                Task { @MainActor in
                    guard let self, let newWriter, self.writer === newWriter else { return }
                    self.fail("Recording failed: \(error.localizedDescription)")
                }
            }
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(newWriter, type: .screen, sampleHandlerQueue: newWriter.queue)
            if captureSystemAudio { try newStream.addStreamOutput(newWriter, type: .audio, sampleHandlerQueue: newWriter.queue) }
            if captureMicrophone { try newStream.addStreamOutput(newWriter, type: .microphone, sampleHandlerQueue: newWriter.queue) }
            pendingURL = url
            stream = newStream
            writer = newWriter
            try await newStream.startCapture()
            guard generation == currentGeneration, stream === newStream else { return }
            if stopRequested { await finishCapture(newStream) }
        } catch {
            guard generation == currentGeneration else { return }
            if state == .finishing && stopCompleted { return }
            fail("Couldn’t start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() async {
        switch state {
        case .countdown:
            generation += 1
            countdownRemaining = 0
            state = .idle
        case .starting:
            if stream == nil {
                resetSession()
            } else {
                stopRequested = true
                state = .finishing
                await waitForCompletion()
            }
        case .recording:
            guard let stream else { fail("The recording stream is unavailable."); return }
            state = .finishing
            Task { await finishCapture(stream) }
            await waitForCompletion()
        case .finishing:
            await waitForCompletion()
        default: break
        }
    }

    private func finishCapture(_ stream: SCStream) async {
        armTimeout()
        do {
            try await stream.stopCapture()
            guard self.stream === stream else { return }
            stopCompleted = true
            finishWriter()
        } catch {
            guard self.stream === stream else { return }
            if stopCompleted { return }
            fail("Couldn’t stop recording cleanly: \(error.localizedDescription)")
        }
    }

    private func finishWriter() {
        guard !finishingWriter, let writer else { return }
        finishingWriter = true
        let expected = generation
        Task {
            do {
                let url = try await writer.finish()
                guard generation == expected, self.writer === writer else { return }
                guard url == pendingURL else { fail("The recording was saved to an unexpected location."); return }
                recordingFinished = true
                completeIfReady()
            } catch {
                guard generation == expected, self.writer === writer else { return }
                fail("Couldn’t finish recording: \(error.localizedDescription)")
            }
        }
    }

    private func startProgressUpdates(for writer: CaptureWriter) {
        progressTask = Task { @MainActor [weak self, weak writer] in
            while !Task.isCancelled, let self, let writer, self.writer === writer {
                let snapshot = await writer.snapshot()
                guard self.writer === writer else { return }
                self.elapsed = snapshot.elapsed
                self.fileSize = snapshot.fileSize
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func waitForCompletion() async {
        guard state == .finishing else { return }
        armTimeout()
        await withCheckedContinuation { waiters.append($0) }
    }

    private func armStartTimeout() {
        let expected = generation
        startTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.generation == expected, self.state == .starting else { return }
            self.fail("The recording did not start in time.")
        }
    }

    private func armTimeout() {
        guard timeoutTask == nil else { return }
        let expected = generation
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.generation == expected, self.state == .finishing else { return }
            self.fail("The recording did not finish in time and could not be saved.")
        }
    }

    private func completeIfReady() {
        guard state == .finishing, stopCompleted, recordingFinished, let url = pendingURL else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { fail("The recording finished but the output file is empty or unavailable."); return }
        latestRecording = url
        fileSize = Int64(size)
        resetSession()
    }

    private func fail(_ message: String) {
        errorMessage = message
        let oldStream = stream
        writer?.cancel()
        resetSession()
        if let oldStream { Task { try? await oldStream.stopCapture() } }
    }

    private func resetSession() {
        generation += 1
        progressTask?.cancel(); progressTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        startTimeoutTask?.cancel(); startTimeoutTask = nil
        stream = nil
        writer = nil
        finishingWriter = false
        pendingURL = nil
        stopRequested = false
        state = .idle
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func chooseOutputFolder() {
        guard !isActive else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputFolder
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url }
    }
    func revealOutputFolder() {
        do {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(outputFolder)
        } catch { errorMessage = "Couldn’t open the output folder: \(error.localizedDescription)" }
    }
    func revealLatestRecording() { if let url = latestRecording { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func openLatestRecording() { if let url = latestRecording { NSWorkspace.shared.open(url) } }
    func clearError() { errorMessage = nil }

    private enum RecorderError: LocalizedError {
        case invalidDimensions, microphoneDenied, microphoneUnavailable
        var errorDescription: String? {
            switch self {
            case .invalidDimensions: return "The selected source has an invalid size. Choose it again."
            case .microphoneDenied: return "Microphone access is denied. Enable BetterRecorder in System Settings → Privacy & Security → Microphone."
            case .microphoneUnavailable: return "The selected microphone is disconnected. Choose an available microphone."
            }
        }
    }
}

extension RecorderModel: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in if self.state == .selecting { self.state = .idle } }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard self.state == .selecting, stream == nil else { return }
            self.filter = filter
            self.hasSource = true
            if filter.style == .window {
                if #available(macOS 15.2, *), let title = filter.includedWindows.first?.title, !title.isEmpty {
                    self.sourceName = title
                } else {
                    self.sourceName = "Selected window"
                }
            } else {
                self.sourceName = "Selected screen"
            }
            self.state = .idle
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            guard self.state == .selecting else { return }
            self.state = .idle
            self.errorMessage = "Couldn’t open the source picker: \(error.localizedDescription)"
        }
    }
}

extension RecorderModel: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.userStopped.rawValue {
                self.state = .finishing
                self.startTimeoutTask?.cancel(); self.startTimeoutTask = nil
                self.stopCompleted = true
                self.armTimeout()
                self.finishWriter()
            } else {
                self.fail("Recording stopped unexpectedly: \(error.localizedDescription)")
            }
        }
    }
}
