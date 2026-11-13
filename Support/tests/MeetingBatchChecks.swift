import Foundation

@main
struct MeetingBatchChecks {
    static func main() {
        let first = "[00:00:01] Mac audio: "
        let second = "[00:00:02] Microphone: "
        let spoken = String(repeating: "👩🏽‍💻 café नमस्ते ", count: 500)
        var pending = first + spoken + "\n" + second + "A separate speaker.\n"
        var reconstructed = ""
        var secondSeen = false
        var chunks = 0
        while !pending.isEmpty {
            let batch = MeetingTranscriptBatcher.take(from: &pending, limit: 120)
            precondition(!batch.isEmpty && batch.count <= 120)
            for line in batch.split(separator: "\n") {
                if line.hasPrefix(first) { reconstructed += line.dropFirst(first.count) }
                else {
                    precondition(line == second + "A separate speaker.")
                    precondition(!secondSeen)
                    secondSeen = true
                }
            }
            chunks += 1
            precondition(chunks < 1_000)
        }
        precondition(reconstructed == spoken && secondSeen)
        var complete = first + "Short sentence.\n" + second + "Reply.\n"
        precondition(MeetingTranscriptBatcher.take(from: &complete, limit: 200).contains(second))
        precondition(complete.isEmpty)
        print("PASS: transcript batches preserve source labels, Unicode text, and separate speakers")
    }
}
