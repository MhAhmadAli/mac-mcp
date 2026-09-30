import Foundation

struct ToolError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

struct ToolResult {
    var content: [JSON]
    var isError = false

    static func text(_ text: String) -> ToolResult {
        ToolResult(content: [["type": "text", "text": .string(text)]])
    }

    static func error(_ text: String) -> ToolResult {
        ToolResult(content: [["type": "text", "text": .string(text)]], isError: true)
    }
}

struct Tool {
    let name: String
    let description: String
    let inputSchema: JSON
    let handle: (JSON) throws -> ToolResult

    var definition: JSON {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema]
    }
}

/// An MCP server over stdio: newline-delimited JSON-RPC messages on stdin and stdout.
final class MCPServer {
    private let name: String
    private let version: String
    private let tools: [Tool]

    init(name: String, version: String, tools: [Tool]) {
        self.name = name
        self.version = version
        self.tools = tools
    }

    /// Handles requests one at a time until stdin closes.
    func run() {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                let message = try? JSONDecoder().decode(JSON.self, from: data)
            else {
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: JSON) {
        // Messages without an ID are notifications, and without a method, responses
        guard let method = message["method"]?.string, let id = message["id"] else {
            return
        }
        let params = message["params"] ?? [:]
        switch method {
        case "initialize":
            respond(id, result: [
                "protocolVersion": params["protocolVersion"] ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(name), "version": .string(version)],
            ])
        case "ping":
            respond(id, result: [:])
        case "tools/list":
            respond(id, result: ["tools": .array(tools.map(\.definition))])
        case "tools/call":
            respond(id, result: callTool(params))
        default:
            send([
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": .string("Method not found: \(method)")],
            ])
        }
    }

    private func callTool(_ params: JSON) -> JSON {
        let name = params["name"]?.string ?? ""
        let result: ToolResult
        if let tool = tools.first(where: { $0.name == name }) {
            do {
                result = try tool.handle(params["arguments"] ?? [:])
            } catch {
                result = .error(error.localizedDescription)
            }
        } else {
            result = .error("Unknown tool: \(name)")
        }
        return ["content": .array(result.content), "isError": .bool(result.isError)]
    }

    private func respond(_ id: JSON, result: JSON) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ message: JSON) {
        guard var data = try? JSONEncoder().encode(message) else {
            return
        }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

/// Logs to stderr, as stdout carries the protocol.
func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
