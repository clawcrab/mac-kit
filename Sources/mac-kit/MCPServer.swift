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
        ],
        [
            "name": "mail_unread",
            "description": "List unread messages from Apple Mail's local index (read-only), newest first, across all accounts or one. Junk/Trash/Spam are excluded; Gmail-style accounts show only messages still in INBOX (archived unread are skipped). Each line starts with [id] for mail_read.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "account": [
                        "type": "string",
                        "description": "Optional account filter: account name (e.g. \"Google\", \"iCloud\") or an email address on the account"
                    ],
                    "limit": ["type": "integer", "description": "Max results (default 20)"]
                ]
            ]
        ],
        [
            "name": "mail_search",
            "description": "Search Apple Mail's local index (read-only) by subject or sender name/address (case-insensitive substring). Returns date, from, subject, account/mailbox, newest first, with [id] for mail_read.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Text matched against subject and sender name/address"
                    ],
                    "account": [
                        "type": "string",
                        "description": "Optional account filter (name or address)"
                    ],
                    "mailbox": [
                        "type": "string",
                        "description": "Optional mailbox name filter, e.g. \"INBOX\" or \"Archive\" (matches Gmail labels too)"
                    ],
                    "since": [
                        "type": "string",
                        "description": "Optional ISO date; only messages received on/after it, e.g. \"2026-06-01\""
                    ],
                    "limit": ["type": "integer", "description": "Max results (default 20)"]
                ],
                "required": ["query"]
            ]
        ],
        [
            "name": "mail_read",
            "description": "Read one message by id (from mail_search/mail_unread): headers (from/to/cc/date/subject/mailbox) plus the text body (text/plain preferred, HTML tag-stripped otherwise), truncated to ~6000 chars. If Mail.app hasn't downloaded the body yet, returns metadata with a note.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "integer", "description": "Message id from mail_search or mail_unread"]
                ],
                "required": ["id"]
            ]
        ],
        [
            "name": "mail_send",
            "description": "Send an email through Mail.app (AppleScript) — sends immediately, no draft step. Optionally pick the sending account by name or address; otherwise Mail's default account is used. Requires macOS Automation permission for Mail.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "to": ["type": "string", "description": "Recipient address(es), comma-separated"],
                    "subject": ["type": "string", "description": "Subject line"],
                    "body": ["type": "string", "description": "Plain-text body"],
                    "from_account": [
                        "type": "string",
                        "description": "Optional sending account: account name (e.g. \"Google\") or an address on it"
                    ],
                    "cc": ["type": "string", "description": "Cc address(es), comma-separated"],
                    "bcc": ["type": "string", "description": "Bcc address(es), comma-separated"]
                ],
                "required": ["to", "subject", "body"]
            ]
        ],
        [
            "name": "notes_list",
            "description": "List Apple Notes — metadata only, never bodies: name, folder, modification date, hasAttachments flag, and id (for notes_read). Folder is null for shared notes (Notes refuses the container query on them). Optional case-insensitive substring filter on the note name; newest first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Optional case-insensitive substring matched against note names"
                    ],
                    "limit": ["type": "integer", "description": "Max results (default 20)"]
                ]
            ]
        ],
        [
            "name": "notes_read",
            "description": "Read one Apple Note by exact name or by id (from notes_list). If several notes share the name, errors listing candidate ids — pass \"id\" instead. Returns the HTML body, a plaintext rendering, hasAttachments, and a revision (SHA-256 of the raw HTML body) that notes_append requires as expected_revision. Read-only.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Exact note name"],
                    "id": ["type": "string", "description": "Note id from notes_list (disambiguates duplicate names)"]
                ]
            ]
        ],
        [
            "name": "notes_append",
            "description": "Append content to the END of an existing Apple Note. Compare-and-swap: expected_revision (from a fresh notes_read) must still match or nothing is written (REVISION_MISMATCH — re-read and retry). Refuses notes with attachments (HAS_ATTACHMENTS: a body write would destroy them; there is no force flag). The previous body is backed up to ~/.mac-kit/notes-backups/ before writing. Content may be an HTML fragment or plain text (plain text is entity-escaped and wrapped in <div>s). Returns the new revision. No delete verb exists; to modify existing text use notes_edit.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Exact note name (or pass \"id\")"],
                    "id": ["type": "string", "description": "Note id from notes_list/notes_read"],
                    "content": [
                        "type": "string",
                        "description": "HTML fragment or plain text to append"
                    ],
                    "expected_revision": [
                        "type": "string",
                        "description": "Revision hash from a fresh notes_read of this note (64-char hex)"
                    ]
                ],
                "required": ["content", "expected_revision"]
            ]
        ],
        [
            "name": "notes_edit",
            "description": "Edit an existing Apple Note by exact-string replacement, like a code editor's edit tool: old_string must occur EXACTLY ONCE in the note's raw HTML body (tags included — notes_read first and copy exact HTML context). Zero matches → NO_MATCH; several → AMBIGUOUS (provide more context); nothing is written in either case. Same rails as notes_append: compare-and-swap on expected_revision from a fresh notes_read (REVISION_MISMATCH if the note changed), refuses notes with attachments (HAS_ATTACHMENTS — a body write would destroy them; no force flag), and the previous body is backed up to ~/.mac-kit/notes-backups/ before writing. Returns the new revision.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Exact note name (or pass \"id\")"],
                    "id": ["type": "string", "description": "Note id from notes_list/notes_read"],
                    "old_string": [
                        "type": "string",
                        "description": "Exact substring of the current body HTML to replace — must occur exactly once"
                    ],
                    "new_string": [
                        "type": "string",
                        "description": "Replacement HTML/text (raw — inserted verbatim into the body HTML)"
                    ],
                    "expected_revision": [
                        "type": "string",
                        "description": "Revision hash from a fresh notes_read of this note (64-char hex)"
                    ]
                ],
                "required": ["old_string", "new_string", "expected_revision"]
            ]
        ],
        [
            "name": "notes_create",
            "description": "Create a new Apple Note with a title and content (HTML fragment or plain text — plain text is entity-escaped and wrapped in <div>s) in a folder (default \"Notes\"). Always safe: never touches existing notes. Returns the new note's name, id, and revision.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Note title (becomes the first line / display name)"],
                    "content": ["type": "string", "description": "Note content: HTML fragment or plain text"],
                    "folder": ["type": "string", "description": "Target folder name (default \"Notes\")"]
                ],
                "required": ["title", "content"]
            ]
        ],
        [
            "name": "mail_archive",
            "description": "Move one or more messages OUT of the INBOX to the account's archive (Archive mailbox for standard IMAP; \"All Mail\" for Gmail, which just drops the INBOX label). Reversible — never deletes. Ids are the [id] values from mail_search/mail_unread. Returns per-id success/failure.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": [
                        "type": "integer",
                        "description": "A single message id from mail_search/mail_unread"
                    ],
                    "ids": [
                        "type": "array",
                        "items": ["type": "integer"],
                        "description": "Multiple message ids to archive in one call (batch)"
                    ]
                ]
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
            case "mail_unread":
                let account = args["account"] as? String
                let limit = (args["limit"] as? NSNumber)?.intValue ?? 20
                text = try mailUnreadText(account: account, limit: limit)
            case "mail_search":
                guard let query = args["query"] as? String, !query.isEmpty else {
                    throw ToolError("mail_search requires \"query\"")
                }
                text = try mailSearchText(
                    query: query,
                    account: args["account"] as? String,
                    mailbox: args["mailbox"] as? String,
                    since: args["since"] as? String,
                    limit: (args["limit"] as? NSNumber)?.intValue ?? 20
                )
            case "mail_read":
                guard let id = (args["id"] as? NSNumber)?.int64Value else {
                    throw ToolError("mail_read requires numeric \"id\" from mail_search/mail_unread")
                }
                text = try mailReadText(id: id)
            case "mail_send":
                guard let to = args["to"] as? String, !to.isEmpty else {
                    throw ToolError("mail_send requires \"to\"")
                }
                guard let subject = args["subject"] as? String else {
                    throw ToolError("mail_send requires \"subject\"")
                }
                guard let body = args["body"] as? String else {
                    throw ToolError("mail_send requires \"body\"")
                }
                text = try mailSendText(
                    to: to, subject: subject, body: body,
                    fromAccount: args["from_account"] as? String,
                    cc: args["cc"] as? String,
                    bcc: args["bcc"] as? String
                )
            case "notes_list":
                let query = args["query"] as? String
                let limit = (args["limit"] as? NSNumber)?.intValue ?? 20
                text = try notesListText(query: query, limit: limit)
            case "notes_read":
                let noteName = args["name"] as? String
                let noteId = args["id"] as? String
                guard noteName?.isEmpty == false || noteId?.isEmpty == false else {
                    throw ToolError("notes_read requires \"name\" or \"id\"")
                }
                text = try notesReadText(name: noteName, id: noteId)
            case "notes_append":
                let noteName = args["name"] as? String
                let noteId = args["id"] as? String
                guard noteName?.isEmpty == false || noteId?.isEmpty == false else {
                    throw ToolError("notes_append requires \"name\" or \"id\"")
                }
                guard let content = args["content"] as? String, !content.isEmpty else {
                    throw ToolError("notes_append requires \"content\"")
                }
                guard let expected = args["expected_revision"] as? String, !expected.isEmpty else {
                    throw ToolError("notes_append requires \"expected_revision\" from a fresh notes_read (CAS guard)")
                }
                text = try notesAppendText(name: noteName, id: noteId,
                                           content: content, expectedRevision: expected)
            case "notes_edit":
                let noteName = args["name"] as? String
                let noteId = args["id"] as? String
                guard noteName?.isEmpty == false || noteId?.isEmpty == false else {
                    throw ToolError("notes_edit requires \"name\" or \"id\"")
                }
                guard let oldString = args["old_string"] as? String, !oldString.isEmpty else {
                    throw ToolError("notes_edit requires \"old_string\"")
                }
                guard let newString = args["new_string"] as? String else {
                    throw ToolError("notes_edit requires \"new_string\" (may be an empty string)")
                }
                guard let expected = args["expected_revision"] as? String, !expected.isEmpty else {
                    throw ToolError("notes_edit requires \"expected_revision\" from a fresh notes_read (CAS guard)")
                }
                text = try notesEditText(name: noteName, id: noteId, oldString: oldString,
                                         newString: newString, expectedRevision: expected)
            case "notes_create":
                guard let title = args["title"] as? String, !title.isEmpty else {
                    throw ToolError("notes_create requires \"title\"")
                }
                guard let content = args["content"] as? String else {
                    throw ToolError("notes_create requires \"content\" (may be an empty string)")
                }
                text = try notesCreateText(title: title, content: content,
                                           folder: args["folder"] as? String)
            case "mail_archive":
                var ids: [Int64] = []
                if let single = (args["id"] as? NSNumber)?.int64Value { ids.append(single) }
                if let array = args["ids"] as? [Any] {
                    for value in array {
                        if let number = (value as? NSNumber)?.int64Value { ids.append(number) }
                    }
                }
                guard !ids.isEmpty else {
                    throw ToolError("mail_archive requires \"id\" or \"ids\" (message ids from mail_search/mail_unread)")
                }
                text = try mailArchiveText(ids: ids)
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
