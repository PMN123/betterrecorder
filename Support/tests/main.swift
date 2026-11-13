import AVFoundation
import CoreMedia
import ScreenCaptureKit

func video(_ pts: CMTime) -> CMSampleBuffer {
    var optionalPixel: CVPixelBuffer?
    CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optionalPixel)
    let pixel = optionalPixel!
    CVPixelBufferLockBaseAddress(pixel, [])
    memset(CVPixelBufferGetBaseAddress(pixel), 80, CVPixelBufferGetDataSize(pixel))
    CVPixelBufferUnlockBaseAddress(pixel, [])
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
    let list = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true)!
    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: CFMutableDictionary.self)
    let key = SCStreamFrameInfo.status.rawValue as NSString
    let status = NSNumber(value: SCFrameStatus.complete.rawValue)
    CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(status).toOpaque())
    return sample!
}

func audio(_ pts: CMTime, rate: Double, first: Int, count: Int, frequency: Double, amplitude: Float, channels: AVAudioChannelCount) -> CMSampleBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
    pcm.frameLength = AVAudioFrameCount(count)
    for channel in 0..<Int(channels) {
        for frame in 0..<count { pcm.floatChannelData![channel][frame] = amplitude * Float(sin(Double(first + frame) / rate * frequency * 2 * .pi)) }
    }
    var desc: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: CMTimeAdd(pts, CMTime(value: Int64(first), timescale: CMTimeScale(rate))), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: desc, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
    CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList)
    CMSampleBufferSetDataReady(sample!)
    return sample!
}

func run() async throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BETTERRECORDER_CHECK_DIR"]!).appendingPathComponent("mixed.mp4")
    try? FileManager.default.removeItem(at: url)
    let writer = try CaptureWriter(url: url, width: 320, height: 240, frameRate: 30, captureSystemAudio: true, captureMicrophone: true)
    writer.onStarted = { print("STARTED") }
    writer.onFailure = { print("FAILURE: \($0)") }
    let start = CMClockGetTime(CMClockGetHostTimeClock())
    writer.testVideo(video(start))
    // Exercise the UI's progress polling before finalization. URL resource-value
    // caching must not leave a zero-byte size cached for the completed file.
    _ = await writer.snapshot()
    for first in stride(from: 0, to: 96_000, by: 1_024) {
        writer.testAudio(audio(start, rate: 48_000, first: first, count: min(1_024,96_000-first), frequency: 440, amplitude: 0.15, channels: 2), mic: false)
    }
    for first in stride(from: 0, to: 88_200, by: 1_024) {
        writer.testAudio(audio(start, rate: 44_100, first: first, count: min(1_024,88_200-first), frequency: 880, amplitude: 0.2, channels: 1), mic: true)
    }
    try await Task.sleep(nanoseconds: 600_000_000)
    writer.setMicrophoneMuted(true)
    try await Task.sleep(nanoseconds: 600_000_000)
    writer.setMicrophoneMuted(false)
    try await Task.sleep(nanoseconds: 800_000_000)
    let output = try await writer.finish()
    let asset = AVURLAsset(url: output)
    let tracks = try await asset.load(.tracks)
    let duration = try await asset.load(.duration).seconds
    print("duration=\(duration), video=\(tracks.filter{$0.mediaType == .video}.count), audio=\(tracks.filter{$0.mediaType == .audio}.count)")
    guard duration >= 2, tracks.filter({$0.mediaType == .audio}).count == 1 else { fatalError("Invalid output") }
    let reader = try AVAssetReader(asset: asset)
    let track = tracks.first{$0.mediaType == .audio}!
    let outputAudio = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48_000, AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false])
    reader.add(outputAudio)
    guard reader.startReading() else { throw reader.error! }
    var values: [Float] = []
    while let sample = outputAudio.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
        let length = CMBlockBufferGetDataLength(block)
        var buffer = [Float](repeating: 0, count: length / 4)
        buffer.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        values.append(contentsOf: buffer)
    }
    func amplitude(_ frequency: Double, _ lower: Double, _ upper: Double) -> Double {
        let begin = Int(lower*48_000), end = min(Int(upper*48_000), values.count/2)
        var real=0.0, imag=0.0
        for index in begin..<end {
            real += Double(values[index*2])*cos(Double(index)*frequency*2 * .pi/48_000)
            imag += Double(values[index*2])*sin(Double(index)*frequency*2 * .pi/48_000)
        }
        return 2 * hypot(real,imag)/Double(end-begin)
    }
    let before=amplitude(880,0.15,0.4), muted=amplitude(880,0.85,1.1), after=amplitude(880,1.5,1.8), system=amplitude(440,0.85,1.1)
    print("microphone before=\(before) muted=\(muted) after=\(after); system while muted=\(system)")
    guard before>0.1, muted<0.01, after>0.1, system>0.1 else { fatalError("Mute or conversion failed") }
    print("PASS")
}
let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    do { try await run() } catch { print("ERROR: \(error)"); exit(1) }
    semaphore.signal()
}
semaphore.wait()
