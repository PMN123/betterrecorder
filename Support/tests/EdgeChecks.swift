import AVFoundation
import CoreMedia
import ScreenCaptureKit

@main struct Checks {
    static func main() async throws {
        let directory=URL(fileURLWithPath: ProcessInfo.processInfo.environment["BETTERRECORDER_CHECK_DIR"]!)
        let emptyURL=directory.appendingPathComponent("empty.mp4")
        try? FileManager.default.removeItem(at:emptyURL)
        let empty=try CaptureWriter(url:emptyURL,width:320,height:240,frameRate:30,captureSystemAudio:false,captureMicrophone:false)
        var failures=0
        empty.onFailure = { _ in failures += 1 }
        do { _ = try await empty.finish(); fatalError("Empty capture succeeded") } catch { print("Empty capture rejected: \(error.localizedDescription)") }
        do { _ = try await empty.finish(); fatalError("Repeated empty capture succeeded") } catch { }
        guard failures==1, !FileManager.default.fileExists(atPath:emptyURL.path) else { fatalError("Failure cleanup") }
        let cancelURL=directory.appendingPathComponent("cancelled.mp4")
        try? FileManager.default.removeItem(at:cancelURL)
        let cancelled=try CaptureWriter(url:cancelURL,width:320,height:240,frameRate:30,captureSystemAudio:true,captureMicrophone:true)
        cancelled.cancel()
        do { _ = try await cancelled.finish(); fatalError("Cancelled capture succeeded") } catch { print("Cancelled capture rejected") }
        guard !FileManager.default.fileExists(atPath:cancelURL.path) else { fatalError("Cancellation cleanup") }
        print("EDGE PASS")
    }
}
