import Foundation

/// Minimal MCP server over stdio: newline-delimited JSON-RPC 2.0.
/// Implements initialize, ping, tools/list, tools/call.
struct MCPServer {
    static let serverName = "mac-kit"
    static let serverVersion = "0.1.0"
    static let protocolVersion = "2024-11-05"

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "map_search",
            "description": "Natural-language point-of-interest search via Apple Maps (MKLocalSearch). Returns names, addresses, coordinates, phone/URL when available.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Natural-language search, e.g. \"coffee\" or \"sushi restaurants\""
                    ],
                    "near": [
                        "type": "string",
                        "description": "Optional place/address to bias results toward, e.g. \"Union Square San Francisco\""
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Max results (default 5)"
                    ]
                ],
                "required": ["query"]
            ]
        ],
        [
            "name": "map_geocode",
            "description": "Forward geocoding (address string -> coordinates) or reverse geocoding (lat/lon -> address) via CLGeocoder. Provide either query, or lat and lon.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Address or place string to forward-geocode"
                    ],
                    "lat": ["type": "number", "description": "Latitude for reverse geocoding"],
                    "lon": ["type": "number", "description": "Longitude for reverse geocoding"]
                ]
            ]
        ],
        [
            "name": "map_eta",
            "description": "Travel time and route between two places via Apple Maps (MKDirections). Driving ETA includes current traffic. Returns best route plus alternatives.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "from": ["type": "string", "description": "Origin address or place name"],
                    "to": ["type": "string", "description": "Destination address or place name"],
                    "transport": [
                        "type": "string",
                        "enum": ["driving", "walking", "transit"],
                        "description": "Transport mode (default driving). Transit returns ETA only, no steps."
                    ]
                ],
                "required": ["from", "to"]
            ]
        ]
    ]

    func run() async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                await handleLine(trimmed)
            }
        } catch {
            FileHandle.standardError.write(Data("mac-kit: stdin read error: \(error)\n".utf8))
        }
    }

    private func handleLine(_ line: String) async {
        guard
            let data = line.data(using: .utf8),
            let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            send(errorResponse(id: NSNull(), code: -32700, message: "Parse error"))
            return
        }

        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications (no id) get no response.
        guard let id else { return }

        switch method {
        case "initialize":
            let clientProtocol = params["protocolVersion"] as? String ?? Self.protocolVersion
            send(resultResponse(id: id, result: [
                "protocolVersion": clientProtocol,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "version": Self.serverVersion]
            ]))
        case "ping":
            send(resultResponse(id: id, result: [String: Any]()))
        case "tools/list":
            send(resultResponse(id: id, result: ["tools": Self.toolDefinitions]))
        case "tools/call":
            let result = await callTool(params: params)
            send(resultResponse(id: id, result: result))
        default:
            send(errorResponse(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func callTool(params: [String: Any]) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let text: String
            switch name {
            case "map_search":
                guard let query = args["query"] as? String, !query.isEmpty else {
                    throw ToolError("map_search requires \"query\"")
                }
                let near = args["near"] as? String
                let limit = (args["limit"] as? NSNumber)?.intValue ?? 5
                text = try await searchText(query: query, near: near, limit: limit)
            case "map_geocode":
                let query = args["query"] as? String
                let lat = (args["lat"] as? NSNumber)?.doubleValue
                let lon = (args["lon"] as? NSNumber)?.doubleValue
                text = try await geocodeText(query: query, lat: lat, lon: lon)
            case "map_eta":
                guard let from = args["from"] as? String, !from.isEmpty,
                      let to = args["to"] as? String, !to.isEmpty else {
                    throw ToolError("map_eta requires \"from\" and \"to\"")
                }
                let transport = args["transport"] as? String ?? "driving"
                text = try await etaText(from: from, to: to, transport: transport)
            default:
                throw ToolError("Unknown tool: \(name)")
            }
            return [
                "content": [["type": "text", "text": text]],
                "isError": false
            ]
        } catch {
            return [
                "content": [["type": "text", "text": "Error: \(error)"]],
                "isError": true
            ]
        }
    }

    // MARK: - JSON-RPC plumbing

    private func resultResponse(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            FileHandle.standardError.write(Data("mac-kit: failed to serialize response\n".utf8))
            return
        }
        var output = data
        output.append(0x0A) // newline-delimited framing
        FileHandle.standardOutput.write(output)
    }
}
