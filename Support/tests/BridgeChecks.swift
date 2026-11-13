import Foundation
actor Recorder {
    var calls: [[String]] = []
    func append(_ arguments: [String]) { calls.append(arguments) }
    func count() -> Int { calls.filter { $0.first == "queue" }.count }
    func last() -> [String]? { calls.last }
}
@main struct Fixtures {
    static func main() async throws {
        let id = "00000000-0000-4000-8000-000000000001"
        let chat = CodexChat(id: id, title: "untrusted title; $(nothing)", cwd: nil, updatedAt: nil)
        let metadata = Data("""
        {"data":[
          {"id":"\(id)","name":"User chat","source":"appServer","updatedAt":123},
          {"id":"00000000-0000-4000-8000-000000000002","name":"Agent","source":{"subAgent":{} }},
          {"id":"00000000-0000-4000-8000-000000000003","name":"Child","parentThreadId":"\(id)"},
          {"id":"00000000-0000-4000-8000-000000000004","name":"Archived","archived":true},
          {"id":"00000000-0000-4000-8000-000000000005","preview":"PRIVATE_MESSAGE"}
        ],"nextCursor":null}
        """.utf8)
        let recorder = Recorder()
        let bridge = CodexChatBridge(executable: URL(fileURLWithPath: "/fixture/codex"), commandRunner: { _, arguments in
            await recorder.append(arguments)
            if arguments.first == "login" {
                return .init(exitCode: 0, stdout: "", stderr: "Logged in using ChatGPT")
            }
            return .init(exitCode: 0, stdout: "Queued message fixture", stderr: "Warning: message was queued, but could not resume thread")
        }, rpcRunner: { _, method, params in
            if method == "thread/read" {
                let object = try JSONSerialization.jsonObject(with: params) as! [String:Any]
                precondition(object["includeTurns"] as? Bool == false)
                return Data("{\"thread\":{\"id\":\"\(id)\",\"name\":\"User chat\",\"source\":\"appServer\"}}".utf8)
            }
            precondition(method == "thread/list")
            let object = try JSONSerialization.jsonObject(with: params) as! [String:Any]
            precondition(object["useStateDbOnly"] as? Bool == true)
            precondition(object["archived"] as? Bool == false)
            return metadata
        })
        let listed = try await bridge.listChats()
        precondition(listed.count == 2)
        precondition(!listed.contains { $0.title.contains("PRIVATE_MESSAGE") })
        let receipt = try await bridge.send(message: "Text with spaces; $(harmless)", to: chat)
        precondition(receipt.resumed == false)
        let arguments = await recorder.last()!
        precondition(arguments == ["queue", "--thread", id, "--message", "Text with spaces; $(harmless)", "--resume"])
        do {
            _ = try await bridge.send(message: "no", to: .init(id: "invalid", title: "x", cwd: nil, updatedAt: nil))
            fatalError("invalid target accepted")
        } catch CodexChatBridgeError.invalidTarget { }
        do {
            _ = try await bridge.send(message: "no", to: .init(id: "00000000-0000-4000-8000-000000000006", title: "x", cwd: nil, updatedAt: nil))
            fatalError("unlisted target accepted")
        } catch CodexChatBridgeError.invalidTarget { }
        let count = await recorder.count()
        precondition(count == 1)
        let uncertain = CodexChatBridge(executable: URL(fileURLWithPath: "/fixture/codex"), commandRunner: { _, arguments in
            .init(exitCode: 0, stdout: arguments.first == "login" ? "Logged in using ChatGPT" : "", stderr: "")
        }, rpcRunner: { _, method, _ in
            if method == "thread/read" {
                return Data("{\"thread\":{\"id\":\"\(id)\",\"name\":\"User chat\",\"source\":\"appServer\"}}".utf8)
            }
            return metadata
        })
        do {
            _ = try await uncertain.send(message: "no", to: chat)
            fatalError("unknown output marked accepted")
        } catch CodexChatBridgeError.deliveryUnconfirmed { }
        print("PASS metadata filtering, private-preview omission, exact UUID arguments, warning receipt, invalid and missing targets, unconfirmed queue failure; no real messages sent")
    }
}
