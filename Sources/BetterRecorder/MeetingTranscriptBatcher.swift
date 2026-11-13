import Foundation

enum MeetingTranscriptBatcher {
    static func take(from pending: inout String, limit: Int) -> String {
        var batch = ""
        while !pending.isEmpty {
            let newline = pending.firstIndex(of: "\n")
            let end = newline.map { pending.index(after: $0) } ?? pending.endIndex
            let line = String(pending[..<end])
            if batch.count + line.count <= limit {
                batch += line
                pending.removeSubrange(..<end)
                continue
            }
            if !batch.isEmpty { break }
            guard let separator = line.range(of: ": ") else { return "" }
            let label = String(line[..<separator.upperBound])
            let content = String(line[separator.upperBound...])
            let available = limit - label.count - 1
            guard available > 0 else { return "" }
            let count = min(available, content.count)
            let split = content.index(content.startIndex, offsetBy: count)
            batch = label + content[..<split] + "\n"
            pending.removeSubrange(..<end)
            let remainder = String(content[split...])
            if !remainder.isEmpty && remainder != "\n" { pending = label + remainder + pending }
            break
        }
        return batch
    }
}
