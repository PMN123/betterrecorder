import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// All mutable capture and encoder state belongs to `queue`, including SCStream callbacks.
final class CaptureWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "BetterRecorder.capture-writer", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var startedHandler: (() -> Void)?
    private var failureHandler: ((Error) -> Void)?
    var onStarted: (() -> Void)? {
        get { onQueue { startedHandler } }
        set { onQueue { startedHandler = newValue } }
    }
    var onFailure: ((Error) -> Void)? {
        get { onQueue { failureHandler } }
        set { onQueue { failureHandler = newValue } }
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return body() }
        return queue.sync(execute: body)
    }

    private let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let frameDuration: CMTime
    private let captureSystemAudio: Bool
    private let captureMicrophone: Bool
    private let mixFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    private var converters: [Int: AVAudioConverter] = [:]
    private var chunks: [AudioChunk] = []
    private var bufferedFrames = 0
    private var startTime: CMTime?
    private var lastVideo: CMSampleBuffer?
    private var lastVideoTime: CMTime?
    private var mixedFrame: Int64 = 0
    private var muteChanges: [(time: Double, muted: Bool)] = [(-Double.infinity, false)]
    private var timer: DispatchSourceTimer?
    private var finishing = false
    private var finalizing = false
    private var stopTime: CMTime?
    private var terminalResult: Result<URL, Error>?
    private var finishWaiters: [CheckedContinuation<URL, Error>] = []
    private var didReportFailure = false
    private var stalledSince: Double?

    private struct AudioChunk {
        let time: CMTime
        let microphone: Bool
        let left: [Float]
        let right: [Float]
        var count: Int { left.count }
    }

    private enum CaptureError: LocalizedError {
        case invalidConfiguration, cannotAddInput, noVideo, audioConversion, audioBuffer, encoderStalled, cancelled, emptyFile
        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: return "The recording dimensions or frame rate are invalid."
            case .cannotAddInput: return "The video or audio encoder could not be configured."
            case .noVideo: return "No screen frames were received."
            case .audioConversion: return "Captured audio could not be converted for recording."
            case .audioBuffer: return "Captured audio could not be prepared for recording."
            case .encoderStalled: return "The recording encoder stopped accepting media."
            case .cancelled: return "Recording was cancelled."
            case .emptyFile: return "The recording file is empty or incomplete."
            }
        }
    }

    init(url: URL, width: Int, height: Int, frameRate: Int, captureSystemAudio: Bool, captureMicrophone: Bool) throws {
        guard width > 0, height > 0, frameRate > 0 else { throw CaptureError.invalidConfiguration }
        self.url = url
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, min(40_000_000, width * height * frameRate / 5)),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        if captureSystemAudio || captureMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = true
            audioInput = input
        } else {
            audioInput = nil
        }
        super.init()
        queue.setSpecific(key: queueKey, value: true)
        guard writer.canAdd(videoInput) else { throw CaptureError.cannotAddInput }
        writer.add(videoInput)
        if let audioInput {
            guard writer.canAdd(audioInput) else { throw CaptureError.cannotAddInput }
            writer.add(audioInput)
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        // Capture the button's host timestamp before dispatch, so queue delay cannot expose speech.
        let time = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        queue.async { [self] in
            guard terminalResult == nil, !finishing, muteChanges.last?.muted != muted else { return }
            muteChanges.append((time, muted))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard terminalResult == nil, !finishing, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch outputType {
        case .screen: acceptVideo(sampleBuffer)
        case .audio: if captureSystemAudio { acceptAudio(sampleBuffer, microphone: false) }
        case .microphone: if captureMicrophone { acceptAudio(sampleBuffer, microphone: true) }
        @unknown default: break
        }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let terminalResult { continuation.resume(with: terminalResult); return }
                finishWaiters.append(continuation)
                guard !finishing else { return }
                finishing = true
                guard let startTime, let lastVideoTime else { fail(CaptureError.noVideo); return }
                stopTime = CMTimeMaximum(CMClockGetTime(CMClockGetHostTimeClock()), CMTimeAdd(lastVideoTime, frameDuration))
                if let stopTime, CMTimeCompare(stopTime, startTime) <= 0 { fail(CaptureError.noVideo); return }
                pump()
                queue.asyncAfter(deadline: .now() + 25) { [weak self] in
                    guard let self, self.terminalResult == nil else { return }
                    self.fail(CaptureError.encoderStalled)
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            guard terminalResult == nil else { return }
            fail(CaptureError.cancelled, report: false)
        }
    }

    func snapshot() async -> (elapsed: TimeInterval, fileSize: Int64) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let end = stopTime ?? CMClockGetTime(CMClockGetHostTimeClock())
                let elapsed = startTime.map { max(0, CMTimeSubtract(end, $0).seconds) } ?? 0
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
                continuation.resume(returning: (elapsed, size))
            }
        }
    }

    private func acceptVideo(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              CMSampleBufferGetImageBuffer(sample) != nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { return }
        if let lastVideoTime, CMTimeCompare(pts, lastVideoTime) <= 0 { return }
        if startTime == nil {
            guard writer.startWriting() else { fail(writer.error ?? CaptureError.cannotAddInput); return }
            writer.startSession(atSourceTime: pts)
            startTime = pts
        }
        guard videoInput.isReadyForMoreMediaData else {
            if writer.status == .failed { fail(writer.error ?? CaptureError.encoderStalled) }
            return
        }
        guard videoInput.append(sample) else { fail(writer.error ?? CaptureError.encoderStalled); return }
        let first = lastVideo == nil
        lastVideo = sample
        lastVideoTime = pts
        if first {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(20))
            source.setEventHandler { [weak self] in self?.pump() }
            timer = source
            source.resume()
            onStarted?()
        }
    }

    private func acceptAudio(_ sample: CMSampleBuffer, microphone: Bool) {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let count = CMSampleBufferGetNumSamples(sample)
        guard pts.isNumeric, count > 0, count <= 192_000 else { return }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard inputFormat.sampleRate > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)) else {
            fail(CaptureError.audioConversion); return
        }
        input.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: input.mutableAudioBufferList) == noErr else {
            fail(CaptureError.audioConversion); return
        }
        let key = microphone ? 1 : 0
        if converters[key]?.inputFormat != inputFormat {
            guard let converter = AVAudioConverter(from: inputFormat, to: mixFormat) else { fail(CaptureError.audioConversion); return }
            converter.primeMethod = .none
            converters[key] = converter
        }
        guard let converter = converters[key],
              let output = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: AVAudioFrameCount(ceil(Double(count) * 48_000 / inputFormat.sampleRate) + 128)) else {
            fail(CaptureError.audioConversion); return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, let channels = output.floatChannelData else { fail(error ?? CaptureError.audioConversion); return }
        let frames = Int(output.frameLength)
        guard frames > 0 else { return }
        chunks.append(AudioChunk(time: pts, microphone: microphone,
                                 left: Array(UnsafeBufferPointer(start: channels[0], count: frames)),
                                 right: Array(UnsafeBufferPointer(start: channels[1], count: frames))))
        bufferedFrames += frames
        // Bound startup and encoder-backpressure memory (five seconds per source).
        if bufferedFrames > 48_000 * 10 { fail(CaptureError.encoderStalled) }
    }

    private func pump() {
        guard terminalResult == nil, !finalizing, let startTime, lastVideo != nil else { return }
        guard writer.status == .writing else { fail(writer.error ?? CaptureError.encoderStalled); return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let end = stopTime ?? CMTimeSubtract(now, CMTime(seconds: 0.2, preferredTimescale: 48_000))
        let target = max(0, Int64((CMTimeSubtract(end, startTime).seconds * 48_000).rounded(.down)))
        if let audioInput {
            var produced = 0
            // Limit one turn's work so capture callbacks and mute changes can run.
            while mixedFrame < target, audioInput.isReadyForMoreMediaData, produced < 32 {
                let frames = Int(min(1_024, target - mixedFrame))
                do {
                    let sample = try mixedSample(frames: frames, startTime: startTime)
                    guard audioInput.append(sample) else { fail(writer.error ?? CaptureError.encoderStalled); return }
                } catch { fail(error); return }
                mixedFrame += Int64(frames)
                produced += 1
                discardConsumedAudio(startTime: startTime)
            }
            if mixedFrame < target {
                if stalledSince == nil { stalledSince = now.seconds }
                if let stalledSince, now.seconds - stalledSince > 8 { fail(CaptureError.encoderStalled); return }
                return
            }
            stalledSince = nil
        }
        guard finishing, let stopTime, let lastVideo, let lastVideoTime else { return }
        guard videoInput.isReadyForMoreMediaData else { return }
        // A static desktop may supply a single frame. Repeat it at the end so the
        // MP4 video track covers the whole wall-clock recording, including its audio.
        let finalPTS = CMTimeSubtract(stopTime, frameDuration)
        if CMTimeCompare(finalPTS, lastVideoTime) > 0 {
            var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: finalPTS, decodeTimeStamp: .invalid)
            var finalSample: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastVideo, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &finalSample)
            guard status == noErr, let finalSample, videoInput.append(finalSample) else { fail(writer.error ?? CaptureError.encoderStalled); return }
        }
        finalizing = true
        timer?.cancel()
        timer = nil
        writer.endSession(atSourceTime: stopTime)
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        chunks.removeAll()
        converters.removeAll()
        writer.finishWriting { [self] in
            queue.async { [self] in
                guard terminalResult == nil else { return }
                guard writer.status == .completed else { fail(writer.error ?? CaptureError.emptyFile); return }
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
                guard size > 0 else { fail(CaptureError.emptyFile); return }
                complete(.success(url))
            }
        }
    }

    private func mixedSample(frames: Int, startTime: CMTime) throws -> CMSampleBuffer {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: AVAudioFrameCount(frames)), let channels = pcm.floatChannelData else { throw CaptureError.audioBuffer }
        pcm.frameLength = AVAudioFrameCount(frames)
        channels[0].initialize(repeating: 0, count: frames)
        channels[1].initialize(repeating: 0, count: frames)
        var micAudible = [Bool](repeating: true, count: frames)
        var changeIndex = 0
        for index in 0..<frames {
            let time = startTime.seconds + Double(mixedFrame + Int64(index)) / 48_000
            while changeIndex + 1 < muteChanges.count, muteChanges[changeIndex + 1].time <= time { changeIndex += 1 }
            micAudible[index] = !muteChanges[changeIndex].muted
        }
        for chunk in chunks {
            let first = Int64((CMTimeSubtract(chunk.time, startTime).seconds * 48_000).rounded())
            let lower = max(mixedFrame, first)
            let upper = min(mixedFrame + Int64(frames), first + Int64(chunk.count))
            guard lower < upper else { continue }
            for frame in lower..<upper {
                let destination = Int(frame - mixedFrame)
                if chunk.microphone && !micAudible[destination] { continue }
                let source = Int(frame - first)
                channels[0][destination] += chunk.left[source]
                channels[1][destination] += chunk.right[source]
            }
        }
        for index in 0..<frames {
            channels[0][index] = min(1, max(-1, channels[0][index]))
            channels[1][index] = min(1, max(-1, channels[1][index]))
        }
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: mixFormat.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
              let description else { throw CaptureError.audioBuffer }
        let pts = CMTimeAdd(startTime, CMTime(value: mixedFrame, timescale: 48_000))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
              let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr,
              CMSampleBufferSetDataReady(sample) == noErr else { throw CaptureError.audioBuffer }
        return sample
    }

    private func discardConsumedAudio(startTime: CMTime) {
        chunks.removeAll { chunk in
            let end = CMTimeSubtract(chunk.time, startTime).seconds * 48_000 + Double(chunk.count)
            if end <= Double(mixedFrame) { bufferedFrames -= chunk.count; return true }
            return false
        }
        let time = startTime.seconds + Double(mixedFrame) / 48_000
        while muteChanges.count > 1, muteChanges[1].time <= time { muteChanges.removeFirst() }
    }

    private func fail(_ error: Error, report: Bool = true) {
        guard terminalResult == nil else { return }
        timer?.cancel()
        timer = nil
        writer.cancelWriting()
        chunks.removeAll()
        converters.removeAll()
        lastVideo = nil
        // This URL is owned exclusively by the AVAssetWriter created above.
        try? FileManager.default.removeItem(at: url)
        complete(.failure(error))
        if report, !didReportFailure { didReportFailure = true; onFailure?(error) }
    }

    private func complete(_ result: Result<URL, Error>) {
        terminalResult = result
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }
}
