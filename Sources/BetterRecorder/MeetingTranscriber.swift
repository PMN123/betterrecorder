import AVFoundation
import CoreMedia
import Foundation
import Speech

struct TranscriptionUpdate: Sendable {
    let source: String
    let text: String
    let isFinal: Bool
    let startTime: TimeInterval
    let endTime: TimeInterval
}

@available(macOS 26.0, *)
final class MeetingTranscriber: @unchecked Sendable {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false
        func mark() { lock.withLock { timedOut = true } }
        var value: Bool { lock.withLock { timedOut } }
    }

    private let sourceName: String
    private let onUpdate: @Sendable (TranscriptionUpdate) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "BetterRecorder.meeting-transcriber")
    private let lock = NSLock()
    private var accepting = false
    private var queuedSeconds: Double = 0
    private var bufferedSeconds: Double = 0
    private var failed = false
    private var cancelled = false
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private struct BufferedInput: Sendable { let input: AnalyzerInput; let duration: Double }
    private struct InputSequence: AsyncSequence, Sendable {
        typealias Element = AnalyzerInput
        let stream: AsyncStream<BufferedInput>
        let consumed: @Sendable (Double) -> Void
        struct Iterator: AsyncIteratorProtocol {
            var iterator: AsyncStream<BufferedInput>.Iterator
            let consumed: @Sendable (Double) -> Void
            mutating func next() async -> AnalyzerInput? {
                guard let item = await iterator.next() else { return nil }
                consumed(item.duration)
                return item.input
            }
        }
        func makeAsyncIterator() -> Iterator { Iterator(iterator: stream.makeAsyncIterator(), consumed: consumed) }
    }
    private var continuation: AsyncStream<BufferedInput>.Continuation?
    // The following properties are confined to queue.
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var firstPTS: CMTime?
    private var nextOutputPTS: CMTime?

    init(sourceName: String, onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void,
         onFailure: @escaping @Sendable (Error) -> Void) {
        self.sourceName = sourceName
        self.onUpdate = onUpdate
        self.onFailure = onFailure
    }

    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw Failure(message: "On-device transcription is unavailable on this Mac. Check that macOS supports SpeechAnalyzer and try again.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) else {
            throw Failure(message: "The English (United States) on-device speech model is unavailable on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]
        if await AssetInventory.status(forModules: modules) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: modules) == .installed else {
                throw Failure(message: "The on-device English speech model could not be installed. Check your network connection and available storage, then try again.")
            }
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw Failure(message: "No compatible on-device speech audio format is available.")
        }
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<BufferedInput>.makeStream(bufferingPolicy: .bufferingOldest(512))
        let inputSequence = InputSequence(stream: stream) { [weak self] duration in
            self?.lock.withLock { self?.bufferedSeconds -= duration }
        }
        let source = sourceName
        let callback = onUpdate
        let resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let start = CMTimeGetSeconds(result.range.start)
                    let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                    callback(TranscriptionUpdate(source: source, text: String(result.text.characters),
                        isFinal: result.isFinal, startTime: start.isFinite ? start : 0,
                        endTime: end.isFinite ? end : 0))
                }
            } catch {
                self?.report(error)
            }
        }
        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            continuation.finish()
            resultTask.cancel()
            throw error
        }
        let activated = lock.withLock { () -> Bool in
            guard !cancelled && !failed else { return false }
            self.analyzer = analyzer
            self.resultTask = resultTask
            self.continuation = continuation
            self.targetFormat = format
            self.accepting = true
            return true
        }
        if !activated {
            continuation.finish()
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        }
    }

    // Called by a capture queue. Retaining the sample until the serial conversion queue
    // runs keeps its underlying audio data alive without blocking the capture callback.
    func append(_ sample: CMSampleBuffer) {
        let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
        let seconds = duration.isFinite && duration > 0 ? duration : 0.1
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if queuedSeconds + bufferedSeconds + seconds > 5 {
            lock.unlock()
            report(Failure(message: "Transcription could not keep up with captured audio. Stop and start the meeting again."))
            return
        }
        queuedSeconds += seconds
        queue.async { [self, sample] in
            defer { lock.lock(); queuedSeconds -= seconds; lock.unlock() }
            do { try convertAndAppend(sample, duration: seconds) } catch { report(error) }
        }
        lock.unlock()
    }

    private func convertAndAppend(_ sample: CMSampleBuffer, duration: Double) throws {
        guard let targetFormat, let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else {
            throw Failure(message: "The captured audio format is unsupported for transcription.")
        }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        input.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
        guard status == noErr else { throw Failure(message: "Could not read captured audio for transcription (\(status)).") }
        if inputFormat != format || converter == nil {
            guard let newConverter = AVAudioConverter(from: format, to: targetFormat) else {
                throw Failure(message: "Could not convert captured audio for on-device transcription.")
            }
            inputFormat = format
            converter = newConverter
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(ceil(Double(frames) * targetFormat.sampleRate / format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw Failure(message: "Could not allocate transcription audio buffer.")
        }
        var supplied = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard conversionStatus != .error else { throw conversionError ?? Failure(message: "Could not convert captured audio.") as NSError }
        guard output.frameLength > 0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if firstPTS == nil, pts.isValid { firstPTS = pts }
        var relative: CMTime? = firstPTS.flatMap { pts.isValid ? CMTimeSubtract(pts, $0) : nil }
        if let next = nextOutputPTS, let proposed = relative, CMTimeCompare(proposed, next) < 0 { relative = next }
        if let relative {
            let duration = CMTime(value: Int64(output.frameLength), timescale: CMTimeScale(targetFormat.sampleRate))
            nextOutputPTS = CMTimeAdd(relative, duration)
        }
        lock.lock()
        bufferedSeconds += duration
        let yielded = continuation?.yield(BufferedInput(input: AnalyzerInput(buffer: output, bufferStartTime: relative), duration: duration))
        if case .enqueued = yielded { } else { bufferedSeconds -= duration }
        lock.unlock()
        if case .dropped = yielded {
            throw Failure(message: "Transcription could not keep up with captured audio. Stop and start the meeting again.")
        }
    }

    func finish() async throws {
        lock.withLock { accepting = false }
        // Drain everything already accepted before terminating the analyzer's stream.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
        let (continuation, analyzer, resultTask, hadFailure) = lock.withLock {
            let state = (self.continuation, self.analyzer, self.resultTask, failed)
            self.continuation = nil
            return state
        }
        continuation?.finish()
        guard let analyzer else { return }
        if hadFailure {
            await analyzer.cancelAndFinishNow()
            resultTask?.cancel()
            throw Failure(message: "Transcription stopped because audio could not be processed completely.")
        }
        let timeoutFlag = TimeoutFlag()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled {
                timeoutFlag.mark()
                await analyzer.cancelAndFinishNow()
            }
        }
        defer { timeout.cancel() }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await resultTask?.value
        } catch {
            if timeoutFlag.value { throw Failure(message: "Transcription took too long to finish; some final words may be missing.") }
            throw error
        }
        if timeoutFlag.value { throw Failure(message: "Transcription took too long to finish; some final words may be missing.") }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        accepting = false
        let continuation = self.continuation
        self.continuation = nil
        let analyzer = self.analyzer
        let task = self.resultTask
        lock.unlock()
        continuation?.finish()
        task?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }

    private func report(_ error: Error) {
        lock.lock()
        guard !failed else { lock.unlock(); return }
        failed = true
        accepting = false
        lock.unlock()
        onFailure(error)
    }
}
