import Foundation
import AppKit
import Darwin

/// Only metadata needed by the user's chat picker. Transcript/history is never fetched.
struct CodexChat: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let cwd: String?
    let updatedAt: Date?
}

struct ChatDeliveryReceipt: Sendable {
    enum Status: Sendable { case queued }
    let status: Status
    /// Queue acceptance does not prove that Codex has begun or finished processing it.
    let processingConfirmed: Bool
    let detail: String
    var message: String { detail }
    var resumed: Bool { processingConfirmed }
}

enum CodexChatBridgeError: LocalizedError {
    case executableMissing, notLoggedInWithChatGPT, invalidTarget, emptyMessage
    case unavailable, timedOut, outputLimit, protocolError, commandFailed
    case deliveryUnconfirmed

    var errorDescription: String? {
        switch self {
        case .executableMissing: "Install Codex or choose its executable to connect your chats."
        case .notLoggedInWithChatGPT: "Sign in to Codex with your ChatGPT account, then reconnect."
        case .invalidTarget: "That chat is no longer available. Choose it again."
        case .emptyMessage: "There is no transcript text to send."
        case .unavailable: "Codex could not be reached. Open Codex and try reconnecting."
        case .timedOut: "Codex took too long to respond. Delivery may be uncertain; check the chat before retrying."
        case .outputLimit: "Codex returned more data than expected. Reconnect before continuing."
        case .protocolError: "This Codex version returned an unsupported response. Update Codex and reconnect."
        case .commandFailed: "Codex could not queue the transcript. Check that the selected chat is available."
        case .deliveryUnconfirmed: "Codex did not confirm queue acceptance. Check the chat before retrying this text."
        }
    }
}

/// Uses the installed CLI and its existing ChatGPT login; it never reads credentials,
/// requests a model override, or creates a chat. Supply runners to test without sending.
final class CodexChatBridge: @unchecked Sendable {
    struct CommandResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }
    typealias CommandRunner = @Sendable (URL, [String]) async throws -> CommandResult
    /// Returns the JSON-RPC result object (not its envelope).
    typealias RPCRunner = @Sendable (URL, String, Data) async throws -> Data

    private let executable: URL?
    private let commandRunner: CommandRunner
    private let rpcRunner: RPCRunner

    init(executable: URL? = CodexChatBridge.findExecutable(),
         commandRunner: @escaping CommandRunner = { try await CodexChatBridge.runCommand($0, $1) },
         rpcRunner: @escaping RPCRunner = { try await CodexChatBridge.runMetadataRequest($0, $1, $2) }) {
        self.executable = executable
        self.commandRunner = commandRunner
        self.rpcRunner = rpcRunner
    }

    static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        candidates += [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func validateConnection() async throws {
        guard let executable else { throw CodexChatBridgeError.executableMissing }
        let result = try await commandRunner(executable, ["login", "status"])
        let status = result.stdout + "\n" + result.stderr
        guard result.exitCode == 0,
              status.range(of: "Logged in using ChatGPT", options: .caseInsensitive) != nil else {
            throw CodexChatBridgeError.notLoggedInWithChatGPT
        }
    }

    func listChats(searchTerm: String? = nil) async throws -> [CodexChat] {
        guard let executable else { throw CodexChatBridgeError.executableMissing }
        var chats: [CodexChat] = []
        var seen = Set<String>()
        var cursor: String?
        // The server searches titles before pagination, including older chats.
        let query = searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bound both work and data: at most 200 matching user-facing, unarchived chats.
        for _ in 0..<2 {
            try Task.checkCancellation()
            var params: [String: Any] = [
                "limit": 100, "sortKey": "updated_at", "sortDirection": "desc",
                "archived": false, "sourceKinds": ["cli", "vscode", "appServer"],
                "useStateDbOnly": true, "modelProviders": []
            ]
            if let query, !query.isEmpty { params["searchTerm"] = query }
            if let cursor { params["cursor"] = cursor }
            let data = try await rpcRunner(executable, "thread/list", JSONSerialization.data(withJSONObject: params))
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = result["data"] as? [[String: Any]] else {
                throw CodexChatBridgeError.protocolError
            }
            for row in rows {
                guard let chat = Self.chat(from: row), seen.insert(chat.id).inserted else { continue }
                chats.append(chat)
            }
            guard let next = result["nextCursor"] as? String, !next.isEmpty, next != cursor else { break }
            cursor = next
        }
        return Array(chats.prefix(200))
    }

    /// Invoke from an explicit user action. Opening the canonical desktop link helps
    /// the existing desktop process load the selected chat; it never creates a chat.
    /// A successful open means macOS accepted the link, not that processing started.
    @MainActor
    func openChat(_ chat: CodexChat) async throws {
        _ = try await readChat(id: chat.id)
        guard let url = URL(string: "codex://threads/\(chat.id)") else {
            throw CodexChatBridgeError.invalidTarget
        }
        guard NSWorkspace.shared.open(url) else { throw CodexChatBridgeError.unavailable }
    }

    /// Call only after the user explicitly selects this chat. Never automatically retry
    /// a failure: the queue may already contain the message when a process times out.
    func send(message: String, to chat: CodexChat) async throws -> ChatDeliveryReceipt {
        guard UUID(uuidString: chat.id) != nil else { throw CodexChatBridgeError.invalidTarget }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexChatBridgeError.emptyMessage
        }
        guard let executable else { throw CodexChatBridgeError.executableMissing }
        try await validateConnection()
        // A title is display text, never a routing key. Read the exact selected UUID,
        // so an older selected chat is not rejected by the recent-list page limit.
        // Codex's queue endpoint independently rejects archived/deleted targets.
        _ = try await readChat(id: chat.id)
        try Task.checkCancellation()
        let result = try await commandRunner(executable, ["queue", "--thread", chat.id, "--message", message, "--resume"])
        guard result.exitCode == 0 else { throw CodexChatBridgeError.commandFailed }
        let output = result.stdout + "\n" + result.stderr
        guard output.range(of: "Queued message", options: .caseInsensitive) != nil else {
            throw CodexChatBridgeError.deliveryUnconfirmed
        }
        let warning = output.range(of: "warn", options: .caseInsensitive) != nil ||
            output.range(of: "failed", options: .caseInsensitive) != nil
        return ChatDeliveryReceipt(status: .queued, processingConfirmed: false,
            detail: warning
                ? "Queued in Codex. Keep the selected chat open; resume it if paused."
                : "Queued in Codex. Processing has not been confirmed.")
    }

    private func readChat(id: String) async throws -> CodexChat {
        guard UUID(uuidString: id) != nil else { throw CodexChatBridgeError.invalidTarget }
        guard let executable else { throw CodexChatBridgeError.executableMissing }
        let params = try JSONSerialization.data(withJSONObject: ["threadId": id, "includeTurns": false])
        let data = try await rpcRunner(executable, "thread/read", params)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let row = result["thread"] as? [String: Any],
              let chat = Self.chat(from: row), chat.id == id else {
            throw CodexChatBridgeError.invalidTarget
        }
        return chat
    }

    private static func chat(from row: [String: Any]) -> CodexChat? {
        guard let id = row["id"] as? String, UUID(uuidString: id) != nil,
              row["ephemeral"] as? Bool != true,
              row["archived"] as? Bool != true else { return nil }
        if let source = row["source"] as? String,
           !["cli", "vscode", "appServer"].contains(source) { return nil }
        // Newer servers expose ancestry explicitly. Fail closed for spawned agents.
        for key in ["parentThreadId", "parent_thread_id", "agentNickname", "agentRole"] {
            if let value = row[key], !(value is NSNull) { return nil }
        }
        if let source = row["source"] as? [String: Any],
           source.keys.contains(where: { $0.lowercased().contains("subagent") }) { return nil }
        let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Do not use preview: it may contain private message text rather than a title.
        let title = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled chat (\(id.prefix(8)))"
        let updatedAt = (row["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return CodexChat(id: id, title: title, cwd: row["cwd"] as? String, updatedAt: updatedAt)
    }

    private static func runCommand(_ executable: URL, _ arguments: [String]) async throws -> CommandResult {
        let task = Task.detached(priority: .utility) {
            let process = try CodexBridgeProcess(executable: executable, arguments: arguments)
            defer { process.close() }
            try process.waitForExit()
            return CommandResult(exitCode: process.exitCode, stdout: process.stdout, stderr: process.stderr)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private static func runMetadataRequest(_ executable: URL, _ method: String, _ params: Data) async throws -> Data {
        // The fallback server is a short-lived metadata reader, never a thread owner.
        // This allowlist prevents future callers accidentally starting/resuming a turn.
        guard ["thread/list", "thread/read"].contains(method) else { throw CodexChatBridgeError.protocolError }
        let task = Task.detached(priority: .utility) {
            do {
                return try metadataRequest(executable, arguments: ["app-server", "proxy"], method: method, params: params)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                return try metadataRequest(executable, arguments: ["app-server", "--listen", "stdio://"], method: method, params: params)
            }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private static func metadataRequest(_ executable: URL, arguments: [String], method: String, params: Data) throws -> Data {
        let process = try CodexBridgeProcess(executable: executable, arguments: arguments)
        defer { process.close() }
        try process.write(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "better_recorder", "title": "BetterRecorder", "version": "1.0"]
        ]])
        _ = try process.response(id: 1)
        try process.write(["method": "initialized", "params": [:]])
        let object = try JSONSerialization.jsonObject(with: params)
        try process.write(["id": 2, "method": method, "params": object])
        return try process.response(id: 2)
    }
}

/// Bounded nonblocking pipes keep a missing/busy CLI from blocking the main actor.
/// No subprocess output, arguments, or private metadata are logged or persisted.
private final class CodexBridgeProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var outputData = Data()
    private var errorData = Data()
    private var lineBuffer = Data()
    private let deadline = Date().addingTimeInterval(12)
    private let byteLimit = 2 * 1024 * 1024
    var exitCode: Int32 { process.terminationStatus }
    var stdout: String { String(decoding: outputData, as: UTF8.self) }
    var stderr: String { String(decoding: errorData, as: UTF8.self) }

    init(executable: URL, arguments: [String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A proxy may exit before the first write; turn a broken pipe into an error.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        do { try process.run() } catch { throw CodexChatBridgeError.unavailable }
        // The child has its own inherited copies. Closing parent writers makes EOF reliable.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        for handle in [output.fileHandleForReading, errors.fileHandleForReading] {
            _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK)
        }
    }

    func write(_ object: [String: Any]) throws {
        try Task.checkCancellation()
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0a)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { throw CodexChatBridgeError.unavailable }
    }

    func response(id: Int) throws -> Data {
        while true {
            while let newline = lineBuffer.firstIndex(of: 0x0a) {
                let line = Data(lineBuffer[..<newline])
                lineBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexChatBridgeError.protocolError
                }
                guard (envelope["id"] as? NSNumber)?.intValue == id else { continue }
                if envelope["error"] != nil { throw CodexChatBridgeError.protocolError }
                guard let result = envelope["result"] else { throw CodexChatBridgeError.protocolError }
                return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
            }
            try pump()
            if !process.isRunning {
                // Drain data written immediately before termination before reporting failure.
                try drain()
                if lineBuffer.contains(0x0a) { continue }
                throw CodexChatBridgeError.unavailable
            }
        }
    }

    func waitForExit() throws {
        try? input.fileHandleForWriting.close()
        while process.isRunning { try pump() }
        try drain()
    }

    private func pump() throws {
        try Task.checkCancellation()
        guard Date() < deadline else { throw CodexChatBridgeError.timedOut }
        var descriptors = [
            pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
            pollfd(fd: errors.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        ]
        _ = poll(&descriptors, nfds_t(descriptors.count), 50)
        try drain()
    }

    private func drain() throws {
        for (handle, isOutput) in [(output.fileHandleForReading, true), (errors.fileHandleForReading, false)] {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                guard count > 0 else { break }
                guard outputData.count + errorData.count + count <= byteLimit else {
                    throw CodexChatBridgeError.outputLimit
                }
                if isOutput {
                    outputData.append(contentsOf: buffer.prefix(count))
                    lineBuffer.append(contentsOf: buffer.prefix(count))
                } else { errorData.append(contentsOf: buffer.prefix(count)) }
                try Task.checkCancellation()
            }
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // Termination must stay bounded even if an incompatible CLI ignores SIGTERM.
            let end = Date().addingTimeInterval(0.25)
            while process.isRunning && Date() < end { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }
}
