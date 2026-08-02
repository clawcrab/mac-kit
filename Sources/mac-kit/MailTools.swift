import Foundation
import SQLite3

// MARK: - Read-only SQLite wrapper
//
// Mail.app owns the Envelope Index and is actively syncing, so we open the
// database strictly read-only (SQLITE_OPEN_READONLY), set a short busy
// timeout, and never hold a transaction across calls: each query is a single
// prepare/step/finalize.

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ReadOnlyDB {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close_v2(db) }
            throw ToolError("Cannot open \(path) read-only: \(message)")
        }
        sqlite3_busy_timeout(db, 3000)
        handle = db
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    enum Value {
        case null
        case int(Int64)
        case text(String)
    }

    /// Run one query with `?` bindings; returns rows of column values.
    /// Values come back as text/int/null (Mail's schema uses no blobs we need).
    func query(_ sql: String, _ bindings: [Value] = []) throws -> [[Value]] {
        guard let handle else { throw ToolError("Database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ToolError("SQL prepare failed: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bindings.enumerated() {
            let slot = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, slot)
            case .int(let number): sqlite3_bind_int64(statement, slot, number)
            case .text(let string): sqlite3_bind_text(statement, slot, string, -1, sqliteTransient)
            }
        }

        var rows: [[Value]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                let count = sqlite3_column_count(statement)
                var row: [Value] = []
                for column in 0..<count {
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_NULL:
                        row.append(.null)
                    case SQLITE_INTEGER:
                        row.append(.int(sqlite3_column_int64(statement, column)))
                    default:
                        if let text = sqlite3_column_text(statement, column) {
                            row.append(.text(String(cString: text)))
                        } else {
                            row.append(.null)
                        }
                    }
                }
                rows.append(row)
            } else if code == SQLITE_DONE {
                break
            } else {
                throw ToolError("SQL step failed (\(code)): \(String(cString: sqlite3_errmsg(handle)))")
            }
        }
        return rows
    }
}

private extension ReadOnlyDB.Value {
    var stringValue: String? {
        switch self {
        case .text(let string): return string
        case .int(let number): return String(number)
        case .null: return nil
        }
    }
    var intValue: Int64? {
        switch self {
        case .int(let number): return number
        case .text(let string): return Int64(string)
        case .null: return nil
        }
    }
}

// MARK: - Mail store (Envelope Index + .emlx files)

struct MailAccount {
    let uuid: String       // directory name under ~/Library/Mail/V10/
    let name: String       // e.g. "Google", "iCloud"
    let email: String      // primary address, if known
}

struct MailStore {
    let mailRoot: String   // ~/Library/Mail/V10
    let db: ReadOnlyDB
    let accounts: [MailAccount]      // uuid -> friendly name/email
    let persistenceUUID: String      // per-store UUID used as mbox subdirectory

    static let excludedMailboxNames: Set<String> = [
        "junk", "spam", "trash", "deleted messages", "deleted items"
    ]

    init() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        mailRoot = home + "/Library/Mail/V10"
        let dbPath = mailRoot + "/MailData/Envelope Index"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ToolError("Mail index not found at \(dbPath) — is Mail.app set up on this Mac?")
        }
        db = try ReadOnlyDB(path: dbPath)

        // The per-store UUID (subdirectory inside every .mbox) is recorded in
        // the index's own properties table; fall back to PersistenceInfo.plist.
        var uuid = ""
        if let rows = try? db.query("SELECT value FROM properties WHERE key = 'UUID' LIMIT 1"),
           let value = rows.first?.first?.stringValue {
            uuid = value
        }
        if uuid.isEmpty,
           let plist = NSDictionary(contentsOfFile: home + "/Library/Mail/PersistenceInfo.plist"),
           let version = plist["LastUsedVersionDirectoryName"] as? String,
           let identifiers = plist["VersionDirectoryIdentifiers"] as? [String: String],
           let value = identifiers[version] {
            uuid = value
        }
        persistenceUUID = uuid

        accounts = Self.loadAccounts(home: home, mailDB: db)
    }

    /// Map Mail account UUIDs to human names by joining the system Accounts
    /// store (each Mail account row's parent carries the description and
    /// username). Best-effort: falls back to the bare UUID when unreadable.
    private static func loadAccounts(home: String, mailDB: ReadOnlyDB) -> [MailAccount] {
        var uuids: Set<String> = []
        if let rows = try? mailDB.query("SELECT url FROM mailboxes") {
            for row in rows {
                if let url = row.first?.stringValue, let host = URL(string: url)?.host {
                    uuids.insert(host)
                }
            }
        }

        var found: [MailAccount] = []
        if let accountsDB = try? ReadOnlyDB(path: home + "/Library/Accounts/Accounts4.sqlite") {
            for uuid in uuids.sorted() {
                let sql = """
                SELECT parent.ZACCOUNTDESCRIPTION, parent.ZUSERNAME
                FROM ZACCOUNT child JOIN ZACCOUNT parent ON parent.Z_PK = child.ZPARENTACCOUNT
                WHERE child.ZIDENTIFIER = ?
                """
                if let rows = try? accountsDB.query(sql, [.text(uuid)]), let row = rows.first {
                    found.append(MailAccount(
                        uuid: uuid,
                        name: row[0].stringValue ?? uuid,
                        email: row.count > 1 ? (row[1].stringValue ?? "") : ""
                    ))
                    continue
                }
                found.append(MailAccount(uuid: uuid, name: uuid, email: ""))
            }
        } else {
            found = uuids.sorted().map { MailAccount(uuid: $0, name: $0, email: "") }
        }
        return found
    }

    func account(matching query: String) throws -> MailAccount {
        let needle = query.lowercased()
        if let exact = accounts.first(where: {
            $0.uuid.lowercased() == needle || $0.name.lowercased() == needle || $0.email.lowercased() == needle
        }) {
            return exact
        }
        if let partial = accounts.first(where: {
            $0.name.lowercased().contains(needle) || $0.email.lowercased().contains(needle)
        }) {
            return partial
        }
        let known = accounts.map { "\($0.name) <\($0.email)>" }.joined(separator: ", ")
        throw ToolError("No Mail account matches \"\(query)\". Known accounts: \(known)")
    }

    func accountDisplay(forMailboxURL url: String) -> String {
        guard let host = URL(string: url)?.host else { return "?" }
        return accounts.first(where: { $0.uuid == host })?.name ?? host
    }

    /// "imap://UUID/%5BGmail%5D/All%20Mail" -> "All Mail"
    static func mailboxName(fromURL url: String) -> String {
        guard let components = URL(string: url)?.pathComponents else { return url }
        let names = components.filter { $0 != "/" }
        return names.last?.removingPercentEncoding ?? url
    }

    static func isExcludedMailbox(_ name: String) -> Bool {
        excludedMailboxNames.contains(name.lowercased())
    }

    // MARK: Message queries

    struct MessageRow {
        let id: Int64
        let dateReceived: Int64
        let subject: String
        let senderAddress: String
        let senderName: String
        let mailboxURL: String
        let labelURLs: [String]
    }

    private static let baseSelect = """
    SELECT m.ROWID, m.date_received, s.subject,
           COALESCE(a.address, ''), COALESCE(a.comment, ''), mb.url,
           (SELECT group_concat(mb2.url, char(10))
              FROM labels l JOIN mailboxes mb2 ON mb2.ROWID = l.mailbox_id
             WHERE l.message_id = m.ROWID)
    FROM messages m
    JOIN subjects s ON s.ROWID = m.subject
    LEFT JOIN addresses a ON a.ROWID = m.sender
    JOIN mailboxes mb ON mb.ROWID = m.mailbox
    """

    private func messageRows(where clause: String, bindings: [ReadOnlyDB.Value], limit: Int) throws -> [MessageRow] {
        let sql = Self.baseSelect + """

        WHERE \(clause)
        ORDER BY m.date_received DESC
        LIMIT \(limit)
        """
        return try db.query(sql, bindings).map { row in
            MessageRow(
                id: row[0].intValue ?? 0,
                dateReceived: row[1].intValue ?? 0,
                subject: row[2].stringValue ?? "",
                senderAddress: row[3].stringValue ?? "",
                senderName: row[4].stringValue ?? "",
                mailboxURL: row[5].stringValue ?? "",
                labelURLs: (row[6].stringValue ?? "").split(separator: "\n").map(String.init)
            )
        }
    }

    func unreadMessages(account: MailAccount?, limit: Int) throws -> [MessageRow] {
        var clause = "m.read = 0 AND m.deleted = 0"
        var bindings: [ReadOnlyDB.Value] = []
        if let account {
            clause += " AND mb.url LIKE ?"
            bindings.append(.text("%://\(account.uuid)/%"))
        }
        // Overfetch: Gmail-style stores keep every message in "All Mail", so a
        // chunk of candidates are archived (no INBOX label) and get filtered out.
        let candidates = try messageRows(where: clause, bindings: bindings, limit: max(limit * 25, 500))

        var results: [MessageRow] = []
        for row in candidates {
            let physical = Self.mailboxName(fromURL: row.mailboxURL)
            if Self.isExcludedMailbox(physical) { continue }
            if physical.lowercased() == "all mail" {
                // Gmail archive: only surface messages still labeled INBOX,
                // and show them as INBOX.
                guard let inboxURL = row.labelURLs.first(where: {
                    Self.mailboxName(fromURL: $0).uppercased() == "INBOX"
                }) else { continue }
                results.append(MessageRow(
                    id: row.id, dateReceived: row.dateReceived, subject: row.subject,
                    senderAddress: row.senderAddress, senderName: row.senderName,
                    mailboxURL: inboxURL, labelURLs: row.labelURLs
                ))
            } else {
                results.append(row)
            }
            if results.count >= limit { break }
        }
        return results
    }

    func searchMessages(query: String, account: MailAccount?, mailbox: String?,
                        since: Int64?, limit: Int) throws -> [MessageRow] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        var clause = """
        m.deleted = 0 AND (s.subject LIKE ? ESCAPE '\\'
            OR a.address LIKE ? ESCAPE '\\' OR a.comment LIKE ? ESCAPE '\\')
        """
        var bindings: [ReadOnlyDB.Value] = [.text(pattern), .text(pattern), .text(pattern)]
        if let account {
            clause += " AND mb.url LIKE ?"
            bindings.append(.text("%://\(account.uuid)/%"))
        }
        if let since {
            clause += " AND m.date_received >= ?"
            bindings.append(.int(since))
        }
        let candidates = try messageRows(where: clause, bindings: bindings,
                                         limit: mailbox == nil ? limit : max(limit * 25, 500))
        guard let mailbox else { return candidates }

        // Mailbox filter matches the physical mailbox or any Gmail label.
        let wanted = mailbox.lowercased()
        var results: [MessageRow] = []
        for row in candidates {
            let names = [Self.mailboxName(fromURL: row.mailboxURL)]
                + row.labelURLs.map { Self.mailboxName(fromURL: $0) }
            if names.contains(where: { $0.lowercased() == wanted }) {
                results.append(row)
                if results.count >= limit { break }
            }
        }
        return results
    }

    struct MessageDetail {
        let row: MessageRow
        let toLine: String
        let ccLine: String
    }

    func messageDetail(id: Int64) throws -> MessageDetail {
        let rows = try messageRows(where: "m.ROWID = ?", bindings: [.int(id)], limit: 1)
        guard let row = rows.first else {
            throw ToolError("No message with id \(id) — use mail_search to find valid ids")
        }
        let recipientSQL = """
        SELECT r.type, COALESCE(a.address, ''), COALESCE(a.comment, '')
        FROM recipients r JOIN addresses a ON a.ROWID = r.address
        WHERE r.message = ? ORDER BY r.type, r.position
        """
        var to: [String] = []
        var cc: [String] = []
        for recipient in try db.query(recipientSQL, [.int(id)]) {
            let display = Self.formatAddress(
                address: recipient[1].stringValue ?? "",
                name: recipient[2].stringValue ?? ""
            )
            switch recipient[0].intValue ?? 0 {
            case 0: to.append(display)
            case 1: cc.append(display)
            default: break // bcc rows exist only for sent mail; omit
            }
        }
        return MessageDetail(row: row, toLine: to.joined(separator: ", "),
                             ccLine: cc.joined(separator: ", "))
    }

    static func formatAddress(address: String, name: String) -> String {
        if name.isEmpty { return address }
        if address.isEmpty { return name }
        return "\(name) <\(address)>"
    }

    // MARK: ROWID -> RFC Message-ID bridge
    //
    // Mail's AppleScript object model has no key we can match to a ROWID, but
    // it does expose each message's RFC 5322 Message-ID via the `message id`
    // property. The Envelope Index stores that header in
    // message_global_data.message_id_header, keyed by the integer message hash
    // (messages.message_id -> message_global_data.message_id). So: ROWID ->
    // messages.message_id -> message_id_header, strip the angle brackets, then
    // in JXA find the message `whose messageId is <that>`.

    func messageIDHeader(id: Int64) throws -> String? {
        let sql = """
        SELECT g.message_id_header
        FROM messages m
        JOIN message_global_data g ON g.message_id = m.message_id
        WHERE m.ROWID = ? LIMIT 1
        """
        let raw = try db.query(sql, [.int(id)]).first?.first?.stringValue
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The mailbox a message should be archived into for its account:
    /// "Archive" for standard IMAP (iCloud, custom domains), "All Mail" for
    /// Gmail-style accounts (moving there drops the INBOX label). Nil when the
    /// account exposes neither — the caller must not guess.
    func archiveTargetName(forAccountUUID uuid: String) -> String? {
        guard let rows = try? db.query(
            "SELECT url FROM mailboxes WHERE url LIKE ?", [.text("%://\(uuid)/%")]
        ) else { return nil }
        let names = rows.compactMap { $0.first?.stringValue }.map { Self.mailboxName(fromURL: $0) }
        if names.contains(where: { $0.lowercased() == "archive" }) { return "Archive" }
        if names.contains(where: { $0.lowercased() == "all mail" }) { return "All Mail" }
        return nil
    }

    /// Gmail-style accounts keep every message in "[Gmail]/All Mail" and model
    /// mailboxes as labels, so a plain move to All Mail does not remove the
    /// INBOX label. We detect them by the presence of an "All Mail" mailbox
    /// (the Gmail signature) so mail_archive can take the label-removing path.
    func isGmailAccount(uuid: String) -> Bool {
        guard let rows = try? db.query(
            "SELECT url FROM mailboxes WHERE url LIKE ?", [.text("%://\(uuid)/%")]
        ) else { return false }
        let names = rows.compactMap { $0.first?.stringValue }.map { Self.mailboxName(fromURL: $0).lowercased() }
        return names.contains("all mail")
    }

    // MARK: .emlx location
    //
    // Layout on disk (verified empirically on macOS 26 / Mail V10):
    //   ~/Library/Mail/V10/<AccountUUID>/<Mailbox>.mbox[/<Sub>.mbox...]/
    //     <PersistenceUUID>/Data/<digit dirs>/Messages/<ROWID>.emlx
    // where <ROWID> is messages.ROWID in the Envelope Index and the digit
    // directories are the decimal digits of ROWID/1000, least significant
    // first (e.g. ROWID 19074 -> Data/9/1/Messages/19074.emlx; ROWID < 1000
    // -> Data/Messages/<ROWID>.emlx). Partially downloaded messages are
    // stored as <ROWID>.partial.emlx.

    func emlxPath(mailboxURL: String, messageID: Int64) -> String? {
        guard let url = URL(string: mailboxURL), let host = url.host else { return nil }
        var path = mailRoot + "/" + host
        for component in url.pathComponents where component != "/" {
            path += "/" + (component.removingPercentEncoding ?? component) + ".mbox"
        }
        path += "/" + persistenceUUID + "/Data"
        let thousands = messageID / 1000
        if thousands > 0 {
            for digit in String(thousands).reversed() {
                path += "/" + String(digit)
            }
        }
        path += "/Messages"
        let full = path + "/\(messageID).emlx"
        if FileManager.default.fileExists(atPath: full) { return full }
        let partial = path + "/\(messageID).partial.emlx"
        if FileManager.default.fileExists(atPath: partial) { return partial }
        return nil
    }
}

// MARK: - .emlx / MIME parsing (MVP: text/plain preferred, crude HTML strip)

enum EmlxParser {
    /// An .emlx file is "<byte count>\n<RFC 822 message><XML plist>"; the
    /// count covers just the message.
    static func messageData(fromEmlx data: Data) -> Data {
        guard let newline = data.firstIndex(of: 0x0A) else { return data }
        let header = String(decoding: data[..<newline], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        let start = data.index(after: newline)
        guard let count = Int(header), count > 0, start + count <= data.count else {
            return data.subdata(in: start..<data.count)
        }
        return data.subdata(in: start..<(start + count))
    }

    struct Part {
        let headers: [String: String]   // lowercased header name -> unfolded value
        let body: Data
    }

    static func splitHeaders(_ data: Data) -> Part {
        // Find the blank line separating headers from body (\r\n\r\n or \n\n).
        var headerEnd = data.count
        var bodyStart = data.count
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count - 1 {
            if bytes[index] == 0x0A {
                if bytes[index + 1] == 0x0A {
                    headerEnd = index; bodyStart = index + 2; break
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    headerEnd = index; bodyStart = index + 3; break
                }
            }
            index += 1
        }
        let headerText = String(decoding: data[..<headerEnd], as: UTF8.self)
        var headers: [String: String] = [:]
        var currentName: String?
        for rawLine in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.first == " " || line.first == "\t" {
                if let name = currentName {
                    headers[name, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                }
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).lowercased()
                currentName = name
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if let existing = headers[name] {
                    headers[name] = existing + ", " + value
                } else {
                    headers[name] = value
                }
            }
        }
        return Part(headers: headers, body: data.subdata(in: min(bodyStart, data.count)..<data.count))
    }

    static func contentType(of part: Part) -> (type: String, parameters: [String: String]) {
        guard let raw = part.headers["content-type"] else { return ("text/plain", [:]) }
        let pieces = raw.split(separator: ";")
        let type = pieces.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            parameters[key] = value
        }
        return (type, parameters)
    }

    static func decodeTransferEncoding(_ body: Data, encoding: String?) -> Data {
        switch (encoding ?? "").lowercased() {
        case "base64":
            let text = String(decoding: body, as: UTF8.self)
                .filter { !$0.isWhitespace }
            return Data(base64Encoded: text) ?? body
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return body
        }
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var output = Data(capacity: data.count)
        let bytes = [UInt8](data)
        var index = 0
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x41 + 10
            case 0x61...0x66: return byte - 0x61 + 10
            default: return nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D { // '='
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 2; continue // soft break "=\n"
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    index += 3; continue // soft break "=\r\n"
                }
                if index + 2 < bytes.count,
                   let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3; continue
                }
            }
            output.append(byte)
            index += 1
        }
        return output
    }

    static func string(from data: Data, charset: String?) -> String {
        let name = (charset ?? "utf-8").lowercased()
        let encoding: String.Encoding
        switch name {
        case "utf-8", "us-ascii", "ascii": encoding = .utf8
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        case "utf-16": encoding = .utf16
        default: encoding = .utf8
        }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    /// Walk the MIME tree and pick the best text body: text/plain wins,
    /// then text/html (crudely tag-stripped).
    static func bestBodyText(from part: Part, depth: Int = 0) -> String? {
        let (type, parameters) = contentType(of: part)
        if type.hasPrefix("multipart/"), depth < 4, let boundary = parameters["boundary"] {
            var plain: String?
            var html: String?
            for sub in splitMultipart(part.body, boundary: boundary) {
                let subPart = splitHeaders(sub)
                let (subType, _) = contentType(of: subPart)
                if let text = bestBodyText(from: subPart, depth: depth + 1) {
                    if subType.hasPrefix("multipart/") || subType == "text/plain" {
                        if plain == nil { plain = text }
                    } else if subType == "text/html" {
                        if html == nil { html = text }
                    } else if plain == nil, subType.hasPrefix("text/") {
                        plain = text
                    }
                }
                if plain != nil { break }
            }
            return plain ?? html
        }
        guard type.hasPrefix("text/") else { return nil }
        let decoded = decodeTransferEncoding(part.body, encoding: part.headers["content-transfer-encoding"])
        var text = string(from: decoded, charset: parameters["charset"])
        if type == "text/html" {
            text = stripHTML(text)
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let text = String(decoding: body, as: UTF8.self)
        let marker = "--" + boundary
        var parts: [String] = []
        var current: [Substring] = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.hasSuffix("\r") ? line.dropLast() : line[...]
            if trimmed == Substring(marker) || trimmed == Substring(marker + "--") {
                if inside, !current.isEmpty {
                    parts.append(current.joined(separator: "\n"))
                }
                current = []
                inside = trimmed == Substring(marker)
                if !inside { break }
            } else if inside {
                current.append(line)
            }
        }
        return parts.map { Data($0.utf8) }
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        for block in ["script", "style", "head"] {
            text = text.replacingOccurrences(
                of: "<\(block)[^>]*>[\\s\\S]*?</\(block)>",
                with: "", options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(
            of: "<(br|/p|/div|/tr|/h[1-6]|/li)[^>]*>",
            with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&rsquo;", "'"), ("&mdash;", "—"),
            ("&copy;", "©"), ("&reg;", "®"), ("&zwnj;", ""), ("&zwj;", "")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        // Collapse the whitespace storms typical of marketing HTML.
        text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " ?\n ?", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Formatting

private let mailDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

private func formatEpoch(_ epoch: Int64) -> String {
    guard epoch > 0 else { return "?" }
    return mailDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}

private func formatRow(_ row: MailStore.MessageRow, store: MailStore, index: Int) -> String {
    let sender = MailStore.formatAddress(address: row.senderAddress, name: row.senderName)
    let account = store.accountDisplay(forMailboxURL: row.mailboxURL)
    let mailbox = MailStore.mailboxName(fromURL: row.mailboxURL)
    let subject = row.subject.isEmpty ? "(no subject)" : row.subject
    return """
    \(index). [\(row.id)] \(formatEpoch(row.dateReceived))  \(subject)
       From: \(sender)  (\(account) / \(mailbox))
    """
}

private func parseSinceDate(_ since: String) throws -> Int64 {
    let iso = ISO8601DateFormatter()
    if let date = iso.date(from: since) {
        return Int64(date.timeIntervalSince1970)
    }
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"
    dayFormatter.timeZone = TimeZone.current
    if let date = dayFormatter.date(from: since) {
        return Int64(date.timeIntervalSince1970)
    }
    throw ToolError("Cannot parse since date \"\(since)\" — use ISO format like 2026-07-01")
}

// MARK: - Tool implementations

func mailUnreadText(account: String?, limit: Int) throws -> String {
    let store = try MailStore()
    let filter = try account.map { try store.account(matching: $0) }
    let rows = try store.unreadMessages(account: filter, limit: max(1, limit))
    if rows.isEmpty { return "No unread messages." }
    var lines = ["\(rows.count) unread (newest first; id in brackets for mail_read):"]
    for (index, row) in rows.enumerated() {
        lines.append(formatRow(row, store: store, index: index + 1))
    }
    return lines.joined(separator: "\n")
}

func mailSearchText(query: String, account: String?, mailbox: String?,
                    since: String?, limit: Int) throws -> String {
    let store = try MailStore()
    let filter = try account.map { try store.account(matching: $0) }
    let sinceEpoch = try since.map { try parseSinceDate($0) }
    let rows = try store.searchMessages(query: query, account: filter, mailbox: mailbox,
                                        since: sinceEpoch, limit: max(1, limit))
    if rows.isEmpty { return "No messages match \"\(query)\"." }
    var lines = ["\(rows.count) match(es) for \"\(query)\" (newest first; id in brackets for mail_read):"]
    for (index, row) in rows.enumerated() {
        lines.append(formatRow(row, store: store, index: index + 1))
    }
    return lines.joined(separator: "\n")
}

func mailReadText(id: Int64) throws -> String {
    let store = try MailStore()
    let detail = try store.messageDetail(id: id)
    let row = detail.row

    var lines: [String] = []
    lines.append("Subject: \(row.subject.isEmpty ? "(no subject)" : row.subject)")
    lines.append("From: \(MailStore.formatAddress(address: row.senderAddress, name: row.senderName))")
    if !detail.toLine.isEmpty { lines.append("To: \(detail.toLine)") }
    if !detail.ccLine.isEmpty { lines.append("Cc: \(detail.ccLine)") }
    lines.append("Date: \(formatEpoch(row.dateReceived))")
    var location = "\(store.accountDisplay(forMailboxURL: row.mailboxURL)) / \(MailStore.mailboxName(fromURL: row.mailboxURL))"
    let labels = row.labelURLs.map { MailStore.mailboxName(fromURL: $0) }
    if !labels.isEmpty {
        location += "  (labels: \(labels.joined(separator: ", ")))"
    }
    lines.append("Mailbox: \(location)")
    lines.append("")

    if let path = store.emlxPath(mailboxURL: row.mailboxURL, messageID: row.id),
       let raw = FileManager.default.contents(atPath: path) {
        let message = EmlxParser.messageData(fromEmlx: raw)
        let part = EmlxParser.splitHeaders(message)
        if var body = EmlxParser.bestBodyText(from: part), !body.isEmpty {
            let cap = 6000
            if body.count > cap {
                let cut = body.index(body.startIndex, offsetBy: cap)
                body = String(body[..<cut]) + "\n\n[truncated: showing \(cap) of \(body.count) chars]"
            }
            if path.hasSuffix(".partial.emlx") {
                lines.append("[note: message only partially downloaded — attachments missing]")
            }
            lines.append(body)
        } else {
            lines.append("[no text body found in \(path.hasSuffix(".partial.emlx") ? "partial " : "")message file]")
        }
    } else {
        lines.append("[body not downloaded yet — Mail.app has only synced this message's metadata]")
    }
    return lines.joined(separator: "\n")
}

/// Expand a leading `~` and require an absolute path. Returns nil when the
/// path is not absolute after expansion. Path bytes are otherwise untouched —
/// filenames may legitimately end in spaces, so nothing is trimmed here.
/// (Pure helper; exercised in self-test.)
func mailAttachmentAbsolutePath(_ raw: String, home: String) -> String? {
    var path = raw
    if path == "~" {
        path = home
    } else if path.hasPrefix("~/") {
        path = home + String(path.dropFirst(1))
    }
    return path.hasPrefix("/") ? path : nil
}

// MARK: mail_send sender resolution
//
// Mail.app's `sender` property silently falls back to the DEFAULT account
// when the value doesn't correspond to a mounted account — mail can go out
// from the wrong address with no error (two real incidents, 2026-07-29).
// So mail_send enumerates the mounted accounts first (read-only JXA), then
// resolves from_account in Swift with this pure, self-tested function, and
// refuses to send when nothing matches or the match is ambiguous.

struct MailSendAccount {
    let name: String       // Mail.app account name, e.g. "Google"
    let fullName: String   // sender display name, e.g. "Jane Appleseed"
    let emails: [String]   // addresses mounted on the account, primary first
}

enum MailSenderResolution: Equatable {
    case resolved(String)   // exact "Full Name <address>" (or bare address)
    case failed(String)     // human-readable refusal; nothing may be sent
}

/// Resolve a from_account query to an exact RFC 5322 sender string.
/// Match rules (case-insensitive, exact — no substrings):
///   1. An address match wins and resolves to that EXACT address.
///   2. Otherwise an account-name match resolves to the account's primary
///      address — but several accounts sharing the name is an error (Mail
///      does not enforce unique names); the caller must pass an address.
///   3. No match: error listing every mounted account and address.
func resolveMailSender(accounts: [MailSendAccount], query: String) -> MailSenderResolution {
    let needle = query.lowercased()
    func sender(_ account: MailSendAccount, _ address: String) -> String {
        account.fullName.isEmpty ? address : "\(account.fullName) <\(address)>"
    }
    let listing = accounts.map { "\($0.name) <\($0.emails.joined(separator: ", "))>" }
        .joined(separator: "; ")

    for account in accounts {
        if let address = account.emails.first(where: { $0.lowercased() == needle }) {
            return .resolved(sender(account, address))
        }
    }
    let nameMatches = accounts.filter { $0.name.lowercased() == needle }
    if nameMatches.count > 1 {
        let candidates = nameMatches.map { "\($0.name) <\($0.emails.joined(separator: ", "))>" }
            .joined(separator: "; ")
        return .failed("account name \"\(query)\" is ambiguous — \(nameMatches.count) accounts share it: "
            + candidates + ". Pass one of the addresses instead. Nothing sent.")
    }
    if let match = nameMatches.first {
        guard let primary = match.emails.first else {
            return .failed("account \"\(match.name)\" has no email addresses mounted — nothing sent. Accounts: " + listing)
        }
        return .resolved(sender(match, primary))
    }
    return .failed("no Mail account matches \"\(query)\" — nothing sent. Accounts: " + listing)
}

/// Enumerate Mail.app's mounted accounts (read-only; no mutation).
private func mailSendEnumerateAccounts() throws -> [MailSendAccount] {
    let source = """
    function run() {
      const Mail = Application('Mail');
      const out = [];
      for (const account of Mail.accounts()) {
        let emails = [];
        try { emails = account.emailAddresses().map(String); } catch (e) {}
        let fullName = '';
        try { fullName = String(account.fullName()); } catch (e) {}
        out.push({name: String(account.name()), fullName: fullName, emails: emails});
      }
      return JSON.stringify(out);
    }
    """
    let raw = try runJXA(source, timeout: 20)
    guard let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else {
        throw ToolError("Could not enumerate Mail.app accounts (unexpected reply) — nothing sent")
    }
    return parsed.map {
        MailSendAccount(
            name: $0["name"] as? String ?? "",
            fullName: $0["fullName"] as? String ?? "",
            emails: ($0["emails"] as? [Any] ?? []).compactMap { $0 as? String }
        )
    }
}

func mailSendText(to: String, subject: String, body: String,
                  fromAccount: String?, cc: String?, bcc: String?,
                  attachments: [String] = []) throws -> String {
    func addressList(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    let toList = addressList(to)
    guard !toList.isEmpty else { throw ToolError("mail_send requires at least one \"to\" address") }

    // Attachment validation happens HERE, before any Mail.app mutation: every
    // entry must be non-blank, absolute (after ~ expansion), and point at a
    // readable regular file. Mail.app itself silently sends without the
    // attachment when a path is bad, so a filesystem check is the only
    // reliable guard. Blank entries are an error, not a skip — a request that
    // asked for attachments must never silently collapse into a send without
    // them. Paths are used byte-for-byte (filenames may end in spaces).
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var attachPaths: [String] = []
    var totalAttachmentBytes: Int64 = 0
    var badPaths: [String] = []
    for (index, raw) in attachments.enumerated() {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            badPaths.append("attachments[\(index)] is empty")
            continue
        }
        guard let absolute = mailAttachmentAbsolutePath(raw, home: home) else {
            badPaths.append("\(raw) (not an absolute path)")
            continue
        }
        // Resolve symlinks so Mail attaches the real file; require a readable
        // REGULAR file (rejects directories, FIFOs, sockets, devices). The
        // file can still change or vanish between this check and Mail reading
        // it — TOCTOU is an accepted residual risk; no staging copies.
        let resolved = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            badPaths.append("\(absolute) (no such file)")
            continue
        }
        if isDirectory.boolValue {
            badPaths.append("\(absolute) (is a directory — attach files only)")
            continue
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved)
        guard (attributes?[.type] as? FileAttributeType) == .typeRegular else {
            badPaths.append("\(absolute) (not a regular file)")
            continue
        }
        guard FileManager.default.isReadableFile(atPath: resolved) else {
            badPaths.append("\(absolute) (not readable)")
            continue
        }
        totalAttachmentBytes += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        attachPaths.append(resolved)
    }
    if !badPaths.isEmpty {
        throw ToolError("mail_send: invalid attachment path(s), nothing sent: "
            + badPaths.joined(separator: "; "))
    }

    // Strict sender resolution BEFORE composing anything (see resolveMailSender).
    var sender = ""
    if let fromAccount, !fromAccount.isEmpty {
        switch resolveMailSender(accounts: try mailSendEnumerateAccounts(), query: fromAccount) {
        case .resolved(let resolved): sender = resolved
        case .failed(let message): throw ToolError(message)
        }
    }

    // Attachment readiness poll budget: base 10s plus 1s per MB, capped so a
    // huge file can't push the osascript run past a sane bound.
    let pollSeconds = min(40, 10 + Int(totalAttachmentBytes / 1_048_576))

    let source = """
    function run() {
      const Mail = Application('Mail');
      const to = \(jsLiteral(toList.joined(separator: "\n"))).split('\\n');
      const cc = \(jsLiteral(addressList(cc).joined(separator: "\n")));
      const bcc = \(jsLiteral(addressList(bcc).joined(separator: "\n")));
      const sender = \(jsLiteral(sender));
      const attachJSON = \(jsLiteral((try? String(
          decoding: JSONSerialization.data(withJSONObject: attachPaths), as: UTF8.self)) ?? "[]"));
      const attachPaths = JSON.parse(attachJSON);
      const pollSeconds = \(pollSeconds);

      const msg = Mail.OutgoingMessage({
        subject: \(jsLiteral(subject)),
        content: \(jsLiteral(body)),
        visible: false
      });
      Mail.outgoingMessages.push(msg);
      // From here the outgoing message EXISTS in Mail.app: any failure before
      // Mail.send must delete it (no orphaned invisible drafts), and nothing
      // after Mail.send may be reported as a hard failure — the message may
      // already be on the wire.
      try {
        if (sender) { msg.sender = sender; }
        for (const address of to) {
          msg.toRecipients.push(Mail.ToRecipient({address: address}));
        }
        if (cc) {
          for (const address of cc.split('\\n')) {
            msg.ccRecipients.push(Mail.CcRecipient({address: address}));
          }
        }
        if (bcc) {
          for (const address of bcc.split('\\n')) {
            msg.bccRecipients.push(Mail.BccRecipient({address: address}));
          }
        }
        for (const path of attachPaths) {
          msg.attachments.push(Mail.Attachment({fileName: Path(path)}));
        }
        if (attachPaths.length > 0) {
          // Mail.app registers attachments asynchronously; sending too early
          // can drop them. Poll readiness instead of a blind sleep: ready when
          // the attachment count matches AND either every attachment reports a
          // positive fileSize (content registered) or the legacy 2s floor has
          // elapsed (fileSize is unreadable on some macOS builds — fall back
          // to the known-good fixed delay rather than spinning to a false
          // timeout). The fixed sleep below is only the inter-poll interval.
          const started = Date.now();
          const deadline = started + pollSeconds * 1000;
          let ready = false;
          while (Date.now() < deadline) {
            let count = -1;
            try { count = msg.attachments.length; } catch (e) {}
            if (count >= attachPaths.length) {
              let sizesOK = false;
              try {
                const atts = msg.attachments();
                sizesOK = atts.length >= attachPaths.length;
                for (let i = 0; i < atts.length && sizesOK; i++) {
                  if (!(Number(atts[i].fileSize()) > 0)) { sizesOK = false; }
                }
              } catch (e) { sizesOK = false; }
              if (sizesOK || Date.now() - started >= 2000) { ready = true; break; }
            }
            delay(0.5);
          }
          if (!ready) {
            throw new Error('attachments did not register within ' + pollSeconds + 's ('
              + attachPaths.length + ' requested)');
          }
        }
      } catch (e) {
        try { msg.delete(); } catch (cleanupError) {}
        return 'ERR: ' + e + ' — outgoing message discarded, nothing sent';
      }
      try {
        Mail.send(msg);
      } catch (e) {
        return 'UNKNOWN: Mail.send raised (' + e + ') — the message may or may not'
          + ' have gone out; check the Sent mailbox and Mail.app compose windows'
          + ' before retrying';
      }
      return 'Sent "' + \(jsLiteral(subject)) + '" to ' + to.join(', ')
        + (sender ? ' from ' + sender : ' from the default account')
        + (attachPaths.length > 0 ? ' with ' + attachPaths.length + ' attachment(s)' : '');
    }
    """
    let result: String
    do {
        result = try runJXA(source, timeout: attachPaths.isEmpty ? 30 : Double(pollSeconds + 30))
    } catch let error as ToolError where error.message.contains("timed out") {
        // The osascript process was killed mid-flight — we cannot know whether
        // Mail.send had already fired. Never claim a clean failure here.
        throw ToolError("mail_send timed out — state UNKNOWN: the message may or may not have been sent; "
            + "check the Sent mailbox and Mail.app compose windows before retrying")
    }
    if result.hasPrefix("ERR:") { throw ToolError(String(result.dropFirst(4)).trimmingCharacters(in: .whitespaces)) }
    // "UNKNOWN:" results pass through as text, not as a thrown error: the send
    // mutation may have happened, so reporting must be a warning, not a failure.
    return result
}

// MARK: mail_archive — move messages OUT of the INBOX (reversible, never delete)
//
// "Archive" means the same thing Mail.app's Archive button does: take the
// message out of the INBOX while keeping it filed and recoverable. How that is
// done depends on the account type, and the two paths are NOT interchangeable:
//
//   • Standard IMAP (iCloud, custom domains): move the message from INBOX to
//     the account's "Archive" mailbox. A real IMAP move; works directly.
//
//   • Gmail-style (Google/Gmail): archiving means removing the "INBOX" *label*
//     while the message stays in "[Gmail]/All Mail". The obvious `move` from
//     INBOX to All Mail is a NO-OP on Google's servers — every Gmail message is
//     already in All Mail, so Mail.app updates only its local model and the
//     INBOX label is never removed; after the next sync the message reappears
//     in the inbox (verified empirically: move-to-All-Mail bounces back).
//     What DOES remove the INBOX label is forcing Mail.app to issue real IMAP
//     moves between mailboxes that don't already hold the message: delete the
//     INBOX copy (Mail routes it to Trash — this drops the INBOX label on the
//     server) and immediately move it from Trash into All Mail (this drops the
//     Trash label, leaving the message archived in All Mail with no INBOX and
//     no Trash label). Both hops are real server operations, so the archive
//     sticks. Nothing is ever deleted — the message ends up in All Mail and is
//     fully recoverable. (Gmail categories / Important / Starred labels may be
//     dropped by the round-trip; that is acceptable for an inbox-archive tool.)
//
// After acting, the tool re-reads the message's mailbox membership and reports
// the resulting state, so a move that failed to leave the INBOX is surfaced as
// an ERROR rather than a bare "OK".
//
// Messages are addressed by ROWID (what mail_search / mail_unread return),
// resolved to their RFC Message-ID and matched in Mail.app via `whose
// messageId`. All lookups iterate account.mailboxes by name rather than using
// `by name` specifiers, which return broken references for Gmail mailboxes.

func mailArchiveText(ids: [Int64]) throws -> String {
    guard !ids.isEmpty else { throw ToolError("mail_archive requires at least one id") }
    let store = try MailStore()

    struct Job { let id: Int64; let mid: String; let account: String; let target: String; let gmail: Bool }
    struct Outcome { let id: Int64; let ok: Bool; let message: String }

    var jobs: [Job] = []
    var results: [Int64: Outcome] = [:]

    for id in ids {
        do {
            let detail = try store.messageDetail(id: id)
            guard let host = URL(string: detail.row.mailboxURL)?.host,
                  let account = store.accounts.first(where: { $0.uuid == host }) else {
                results[id] = Outcome(id: id, ok: false, message: "cannot determine the account for this message")
                continue
            }
            guard let mid = try store.messageIDHeader(id: id) else {
                results[id] = Outcome(id: id, ok: false,
                    message: "no Message-ID in the index yet (message not fully synced)")
                continue
            }
            guard let target = store.archiveTargetName(forAccountUUID: host) else {
                results[id] = Outcome(id: id, ok: false,
                    message: "no Archive or All Mail mailbox for account \(account.name) — refusing to guess")
                continue
            }
            // Gmail-style accounts expose no "Archive" mailbox — archiveTargetName
            // falls back to "All Mail" for them. That is our branch signal: a
            // plain move to All Mail is a server-side no-op, so those go through
            // the delete-then-refile path below.
            let gmail = store.isGmailAccount(uuid: host)
            jobs.append(Job(id: id, mid: mid, account: account.name, target: target, gmail: gmail))
        } catch {
            results[id] = Outcome(id: id, ok: false, message: "\(error)")
        }
    }

    if !jobs.isEmpty {
        let payload = jobs.map {
            ["id": String($0.id), "mid": $0.mid, "account": $0.account,
             "target": $0.target, "gmail": $0.gmail ? "1" : "0"]
        }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(), as: UTF8.self)
        // Gmail jobs can poll up to ~30s each (2 × 10s settle loops + a 10s
        // extended stuck-state window) plus a Recovered Messages sweep; a flat
        // 90s cap would kill multi-message batches mid-flight and lose the
        // per-id results of already-completed jobs. Scale with job count.
        let gmailJobs = jobs.filter { $0.gmail }.count
        let budget = max(90.0, Double(gmailJobs) * 40.0 + 15.0)
        // The script gets told the cap so it can stop waiting and report,
        // rather than being killed with nothing to say. Give it a margin.
        let scriptBudget = Int(budget - 10)
        let source = """
        function run() {
          const Mail = Application('Mail');
          const jobs = JSON.parse(\(jsLiteral(json)));
          // The caller kills this script at a hard cap. Everything below that
          // is optional waiting must yield before then, or the run dies with
          // no per-id results at all — and, worse, dies *before* the cleanup
          // that puts stranded mail back (2026-08-02: a single job burned the
          // whole 90s and left a message sitting in "Recovered Messages").
          const T0 = Date.now();
          const BUDGET_MS = \(scriptBudget) * 1000;
          function msLeft() { return BUDGET_MS - (Date.now() - T0); }
          function mbxByName(account, wanted) {
            const boxes = account.mailboxes;
            for (let i = 0; i < boxes.length; i++) {
              try { if (String(boxes[i].name()) === wanted) return boxes[i]; } catch (e) {}
            }
            return null;
          }
          function acctByName(name) {
            const accts = Mail.accounts;
            for (let i = 0; i < accts.length; i++) {
              try { if (String(accts[i].name()) === name) return accts[i]; } catch (e) {}
            }
            return null;
          }
          function hits(mbx, mid) {
            if (!mbx) return -1;
            try { return mbx.messages.whose({messageId: mid}).length; } catch (e) { return -1; }
          }
          // A Trash->All Mail refile can half-complete: the server-side move
          // happens but Mail.app quarantines its local copy into an
          // application-level "Recovered Messages (<acct>)" mailbox (seen
          // 2026-07-19, issue #4). Whose-clause lookup works there where plain
          // iteration throws -1728; a move out of it refiles cleanly.
          function rescueRecovered(mid, allmail) {
            try {
              const boxes = Mail.mailboxes;
              for (let i = 0; i < boxes.length; i++) {
                let nm = '';
                try { nm = String(boxes[i].name()); } catch (e) {}
                if (nm.indexOf('Recovered') !== 0) continue;
                const found = boxes[i].messages.whose({messageId: mid});
                if (found.length > 0) { Mail.move(found[0], {to: allmail}); return true; }
              }
            } catch (e) {}
            return false;
          }
          const out = [];
          for (const job of jobs) {
            try {
              const acct = acctByName(job.account);
              if (!acct) { out.push(job.id + '\\tERR\\tno account named "' + job.account + '"'); continue; }
              const inbox = mbxByName(acct, 'INBOX');
              if (!inbox) { out.push(job.id + '\\tERR\\tno INBOX mailbox on account'); continue; }

              if (job.gmail === '1') {
                // Gmail: remove the INBOX label via delete (-> Trash) then refile
                // Trash -> All Mail. Both are real IMAP moves that stick.
                const allmail = mbxByName(acct, 'All Mail');
                const trash = mbxByName(acct, 'Trash');
                if (!allmail) { out.push(job.id + '\\tERR\\tno All Mail mailbox on Gmail account'); continue; }
                if (!trash) { out.push(job.id + '\\tERR\\tno Trash mailbox on Gmail account'); continue; }
                const inInbox = inbox.messages.whose({messageId: job.mid});
                if (inInbox.length === 0) {
                  if (hits(allmail, job.mid) > 0) { out.push(job.id + '\\tOK\\talready archived (not in INBOX; in All Mail)'); }
                  else { out.push(job.id + '\\tERR\\tnot found in INBOX (already moved?)'); }
                  continue;
                }
                Mail.delete(inInbox[0]);                 // drops INBOX label, lands in Trash
                // Mail.delete() settles asynchronously: the message can take
                // seconds to become visible in Trash (large messages / busy
                // sync are slower). The old single-shot lookup here raced the
                // move and stranded mail in Trash (2 real incidents, both
                // image-heavy Starbucks sends). Poll instead of sampling once.
                let trashMsg = null, reconciled = false;
                for (let attempt = 0; attempt < 20; attempt++) {
                  const t = trash.messages.whose({messageId: job.mid});
                  if (t.length > 0) { trashMsg = t[0]; break; }
                  delay(0.5);
                }
                // Only after the Trash poll budget expires may we conclude the
                // label change reconciled straight to All Mail. Checking this
                // INSIDE the poll loop would false-positive: Gmail mail always
                // has an All Mail copy, so mid-flight (INBOX gone, Trash not
                // yet visible) looks identical to reconciled-success.
                if (trashMsg === null) {
                  if (hits(allmail, job.mid) > 0 && hits(inbox, job.mid) === 0 && hits(trash, job.mid) === 0) {
                    reconciled = true;
                  } else {
                    out.push(job.id + '\\tERR\\tdeleted from INBOX but not visible in Trash or All Mail after 10s — state unknown, check Gmail before retrying');
                    continue;
                  }
                }
                if (!reconciled) {
                  Mail.move(trashMsg, {to: allmail});    // drops Trash label -> archived in All Mail
                  // the refile settles asynchronously too — wait for it to stick
                  for (let attempt = 0; attempt < 20; attempt++) {
                    if (hits(trash, job.mid) === 0 && hits(allmail, job.mid) > 0) break;
                    delay(0.5);
                  }
                }
                let inb = hits(inbox, job.mid), am = hits(allmail, job.mid), tr = hits(trash, job.mid);
                // Sweep Recovered Messages BEFORE the optional extended wait.
                // A half-completed refile quarantines the local copy here, and
                // this sweep is what undoes it — so it must not be the step
                // that gets cut when time runs short. Running it twice is
                // harmless: with nothing stranded it is one failed lookup.
                let rescued = rescueRecovered(job.mid, allmail);
                if (rescued) { am = hits(allmail, job.mid); tr = hits(trash, job.mid); }
                if (tr > 0) {
                  // Refile didn't stick inside the settle budget. Before
                  // declaring a stuck state, give slow IMAP sync one extended
                  // window — the 7/19 incident reconciled itself ~a minute
                  // after the tool had already errored. Only spend that window
                  // if there is time left for the remaining jobs to report.
                  for (let attempt = 0; attempt < 20 && msLeft() > 15000; attempt++) {
                    delay(0.5);
                    tr = hits(trash, job.mid);
                    if (tr === 0) break;
                  }
                  am = hits(allmail, job.mid);
                  inb = hits(inbox, job.mid);
                }
                rescued = rescueRecovered(job.mid, allmail) || rescued;
                if (rescued) { am = hits(allmail, job.mid); tr = hits(trash, job.mid); }
                if (inb === 0 && am > 0 && tr === 0) {
                  out.push(job.id + '\\tOK\\tarchived (INBOX label removed; in All Mail' + (rescued ? '; rescued a stray local copy from Recovered Messages' : '') + ')');
                } else if (inb > 0) {
                  out.push(job.id + '\\tERR\\tstill in INBOX after archive (inbox=' + inb + ' allMail=' + am + ' trash=' + tr + ')');
                } else if (tr > 0) {
                  out.push(job.id + '\\tERR\\tleft in Trash, not refiled to All Mail — recover from Gmail Trash (inbox=' + inb + ' allMail=' + am + ' trash=' + tr + ')');
                } else {
                  // Nowhere: gone from INBOX, but not in All Mail or Trash
                  // either. This used to report OK, on the reasoning that
                  // leaving the INBOX was the job. It isn't — archiving means
                  // the message is IN All Mail, and "absent from the three
                  // places I looked" is not that. Mail.app quarantines
                  // half-refiled copies into "Recovered Messages (<acct>)",
                  // which none of these counts cover, so a message could
                  // vanish into it and still be reported archived. 34 of them
                  // did, over two weeks, before anyone noticed (2026-08-02).
                  out.push(job.id + '\\tERR\\tnot in INBOX, All Mail, or Trash — state unknown, check "Recovered Messages" in Mail.app (inbox=' + inb + ' allMail=' + am + ' trash=' + tr + ')');
                }
              } else {
                // Standard IMAP: a real move INBOX -> Archive.
                const dest = mbxByName(acct, job.target);
                if (!dest) { out.push(job.id + '\\tERR\\tcannot resolve "' + job.target + '" mailbox'); continue; }
                const found = inbox.messages.whose({messageId: job.mid});
                if (found.length === 0) {
                  if (hits(dest, job.mid) > 0) { out.push(job.id + '\\tOK\\talready archived (in ' + job.target + ')'); }
                  else { out.push(job.id + '\\tERR\\tnot found in INBOX (already moved?)'); }
                  continue;
                }
                Mail.move(found[0], {to: dest});
                const inb = hits(inbox, job.mid);
                if (inb === 0) { out.push(job.id + '\\tOK\\tmoved to ' + job.target); }
                else { out.push(job.id + '\\tERR\\tstill in INBOX after move to ' + job.target + ' (inbox=' + inb + ')'); }
              }
            } catch (e) {
              out.push(job.id + '\\tERR\\t' + e);
            }
          }
          return out.join('\\n');
        }
        """
        let raw = try runJXA(source, timeout: budget)
        for line in raw.split(separator: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, let rid = Int64(parts[0]) else { continue }
            results[rid] = Outcome(id: rid, ok: parts[1] == "OK",
                                   message: parts[2...].joined(separator: "\t"))
        }
        // Any job with no line back is a failure we shouldn't silently drop.
        for job in jobs where results[job.id] == nil {
            results[job.id] = Outcome(id: job.id, ok: false, message: "no result returned from Mail.app")
        }
    }

    let ordered = ids.map { results[$0] ?? Outcome(id: $0, ok: false, message: "no result") }
    let okCount = ordered.filter { $0.ok }.count
    var lines = ["Archived \(okCount) of \(ids.count) message(s):"]
    for outcome in ordered {
        lines.append("  [\(outcome.id)] \(outcome.ok ? "OK" : "ERROR") — \(outcome.message)")
    }
    return lines.joined(separator: "\n")
}
