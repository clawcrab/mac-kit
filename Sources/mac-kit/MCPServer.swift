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
        ],
        [
            "name": "safari_open",
            "description": "Open a URL in the real Safari browser (front window, reused if open) and wait for the page to finish loading (up to 15s). Returns final URL, title, and readyState. Requires Safari's \"Allow JavaScript from Apple Events\" developer setting.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "URL to open; https:// is assumed if no scheme is given"
                    ]
                ],
                "required": ["url"]
            ]
        ],
        [
            "name": "safari_snapshot",
            "description": "Snapshot the interactive elements of Safari's front page: links, buttons, inputs, headings, etc. Each line is `[ref] role \"name\" (extra)`. Refs (e0, e1, ...) are used by safari_click/safari_fill and stay valid until the next snapshot. Capped at 150 elements.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any]()
            ]
        ],
        [
            "name": "safari_click",
            "description": "Click an element in Safari's front page by snapshot ref (synthetic click). Returns ok plus the page's readyState/title/URL afterwards — re-run safari_snapshot if the page navigated.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": [
                        "type": "string",
                        "description": "Element ref from the latest safari_snapshot, e.g. \"e12\""
                    ]
                ],
                "required": ["ref"]
            ]
        ],
        [
            "name": "safari_fill",
            "description": "Fill a text input, textarea, or contenteditable in Safari's front page by snapshot ref. Sets the value and dispatches input/change events (does not submit).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "ref": [
                        "type": "string",
                        "description": "Element ref from the latest safari_snapshot, e.g. \"e3\""
                    ],
                    "text": [
                        "type": "string",
                        "description": "Text to fill in"
                    ]
                ],
                "required": ["ref", "text"]
            ]
        ],
        [
            "name": "safari_read",
            "description": "Read Safari's front page as text: title, URL, and body innerText (truncated to ~8000 chars).",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any]()
            ]
        ],
        [
            "name": "safari_js",
            "description": "Run raw JavaScript in Safari's front page and return the result as a string. Escape hatch for anything the other safari_* tools don't cover.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "script": [
                        "type": "string",
                        "description": "JavaScript source to evaluate in the page"
                    ]
                ],
                "required": ["script"]
            ]
        ],
        [
            "name": "vision_ocr",
            "description": "Extract text from a local raster image (PNG/JPEG/HEIC/TIFF) using Apple's on-device Vision framework (VNRecognizeTextRequest, accurate mode). Returns text lines in reading order with per-line confidence. No network, no permissions needed.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Path to the image file (~ is expanded)"
                    ],
                    "languages": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Recognition language hints, e.g. [\"zh-Hans\", \"en-US\"] (the default)"
                    ]
                ],
                "required": ["path"]
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
            case "safari_open":
                guard let url = args["url"] as? String, !url.isEmpty else {
                    throw ToolError("safari_open requires \"url\"")
                }
                text = try safariOpenText(url: url)
            case "safari_snapshot":
                text = try safariSnapshotText()
            case "safari_click":
                guard let ref = args["ref"] as? String, !ref.isEmpty else {
                    throw ToolError("safari_click requires \"ref\"")
                }
                text = try safariClickText(ref: ref)
            case "safari_fill":
                guard let ref = args["ref"] as? String, !ref.isEmpty else {
                    throw ToolError("safari_fill requires \"ref\"")
                }
                guard let fillText = args["text"] as? String else {
                    throw ToolError("safari_fill requires \"text\"")
                }
                text = try safariFillText(ref: ref, text: fillText)
            case "safari_read":
                text = try safariReadText()
            case "safari_js":
                guard let script = args["script"] as? String, !script.isEmpty else {
                    throw ToolError("safari_js requires \"script\"")
                }
                text = try safariJSText(script: script)
            case "vision_ocr":
                guard let path = args["path"] as? String, !path.isEmpty else {
                    throw ToolError("vision_ocr requires \"path\"")
                }
                let languages = args["languages"] as? [String] ?? defaultOCRLanguages
                text = try ocrText(path: path, languages: languages)
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
