import ArgumentParser
import Foundation

@main
struct MacKit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac-kit",
        abstract: "Native macOS system capabilities (MapKit, Safari, Vision OCR) as MCP tools and CLI commands.",
        version: MCPServer.serverVersion,
        subcommands: [
            Serve.self, Search.self, Geocode.self, Eta.self, SafariCommand.self,
            Ocr.self, MailCommand.self, NotesCommand.self, SelfTestCommand.self
        ]
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run as an MCP server over stdio (newline-delimited JSON-RPC 2.0)."
    )

    func run() async throws {
        await MCPServer().run()
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Natural-language POI search via Apple Maps."
    )

    @Argument(help: "Search query, e.g. \"coffee near Fremont Seattle\"")
    var query: String

    @Option(help: "Bias results toward this place/address")
    var near: String?

    @Option(help: "Max results")
    var limit: Int = 5

    func run() async throws {
        print(try await searchText(query: query, near: near, limit: limit))
    }
}

struct Geocode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Forward geocode an address, or reverse geocode --lat/--lon."
    )

    @Argument(help: "Address or place string to geocode")
    var query: String?

    @Option(parsing: .unconditional, help: "Latitude for reverse geocoding")
    var lat: Double?

    @Option(parsing: .unconditional, help: "Longitude for reverse geocoding (negative values OK)")
    var lon: Double?

    func run() async throws {
        print(try await geocodeText(query: query, lat: lat, lon: lon))
    }
}

struct Eta: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Travel time and route between two places."
    )

    @Argument(help: "Origin address or place name")
    var from: String

    @Argument(help: "Destination address or place name")
    var to: String

    @Option(help: "Transport mode: driving, walking, or transit")
    var transport: String = "driving"

    func run() async throws {
        print(try await etaText(from: from, to: to, transport: transport))
    }
}

struct Ocr: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ocr",
        abstract: "Extract text from an image file via the Vision framework (on-device OCR)."
    )

    @Argument(help: "Path to the image (PNG/JPEG/HEIC/TIFF; ~ is expanded)")
    var path: String

    @Option(name: .customLong("lang"), help: "Comma-separated recognition languages")
    var lang: String = defaultOCRLanguages.joined(separator: ",")

    func run() throws {
        let languages = lang.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        print(try ocrText(path: path, languages: languages))
    }
}

// MARK: - Safari

struct SafariCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "safari",
        abstract: "Drive the real Safari browser via AppleScript/JXA (synthetic JS events).",
        subcommands: [
            SafariOpen.self, SafariSnapshot.self, SafariClick.self,
            SafariFill.self, SafariRead.self, SafariJS.self
        ]
    )
}

struct SafariOpen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a URL in Safari's front window and wait for the page to load."
    )

    @Argument(help: "URL to open (https:// is assumed if no scheme given)")
    var url: String

    func run() throws {
        print(try safariOpenText(url: url))
    }
}

struct SafariSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "List interactive elements on the front page with refs (e0, e1, ...)."
    )

    func run() throws {
        print(try safariSnapshotText())
    }
}

struct SafariClick: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Click an element by snapshot ref."
    )

    @Argument(help: "Element ref from the latest snapshot, e.g. e12")
    var ref: String

    func run() throws {
        print(try safariClickText(ref: ref))
    }
}

struct SafariFill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fill",
        abstract: "Fill an input/textarea/contenteditable by snapshot ref."
    )

    @Argument(help: "Element ref from the latest snapshot, e.g. e3")
    var ref: String

    @Argument(help: "Text to fill in")
    var text: String

    func run() throws {
        print(try safariFillText(ref: ref, text: text))
    }
}

struct SafariRead: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read the front page's title, URL, and main text (~8000 chars)."
    )

    func run() throws {
        print(try safariReadText())
    }
}

// MARK: - Mail

struct MailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Read Apple Mail's local index (read-only) and send via Mail.app.",
        subcommands: [MailUnread.self, MailSearch.self, MailRead.self, MailSend.self, MailArchive.self]
    )
}

struct MailArchive: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Move message(s) out of the INBOX to the account's Archive/All Mail (reversible; never deletes)."
    )

    @Argument(help: "One or more message ids from mail search/unread, e.g. 40048 40057")
    var ids: [Int64]

    func run() throws {
        print(try mailArchiveText(ids: ids))
    }
}

struct MailUnread: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unread",
        abstract: "List unread messages across accounts (Junk/Trash/Spam excluded)."
    )

    @Option(help: "Only this account (name like \"Google\" or an address)")
    var account: String?

    @Option(help: "Max results")
    var limit: Int = 20

    func run() throws {
        print(try mailUnreadText(account: account, limit: limit))
    }
}

struct MailSearch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search messages by subject or sender (case-insensitive)."
    )

    @Argument(help: "Text to match against subject and sender name/address")
    var query: String

    @Option(help: "Only this account (name or address)")
    var account: String?

    @Option(help: "Only this mailbox by name, e.g. INBOX or Archive")
    var mailbox: String?

    @Option(help: "Only messages received on/after this ISO date, e.g. 2026-06-01")
    var since: String?

    @Option(help: "Max results")
    var limit: Int = 20

    func run() throws {
        print(try mailSearchText(query: query, account: account, mailbox: mailbox,
                                 since: since, limit: limit))
    }
}

struct MailRead: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read one message (headers + text body) by id from mail search/unread."
    )

    @Argument(help: "Message id, e.g. 31797")
    var id: Int64

    func run() throws {
        print(try mailReadText(id: id))
    }
}

struct MailSend: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send an email via Mail.app (AppleScript). Sends immediately."
    )

    @Argument(help: "Recipient address(es), comma-separated")
    var to: String

    @Option(help: "Subject line")
    var subject: String

    @Option(help: "Plain-text body")
    var body: String

    @Option(name: .customLong("from"), help: "Sending account (name or address); Mail's default if omitted")
    var fromAccount: String?

    @Option(help: "Cc address(es), comma-separated")
    var cc: String?

    @Option(help: "Bcc address(es), comma-separated")
    var bcc: String?

    func run() throws {
        print(try mailSendText(to: to, subject: subject, body: body,
                               fromAccount: fromAccount, cc: cc, bcc: bcc))
    }
}

// MARK: - Notes

struct NotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Apple Notes via AppleScript: list/read (read-only), append/edit (CAS-guarded, backed up), create.",
        subcommands: [NotesList.self, NotesRead.self, NotesAppend.self, NotesEdit.self, NotesCreate.self]
    )
}

struct NotesList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List notes (metadata only): name, folder, modified, attachments, id."
    )

    @Argument(help: "Optional case-insensitive substring to match against note names")
    var query: String?

    @Option(help: "Max results")
    var limit: Int = 20

    func run() throws {
        print(try notesListText(query: query, limit: limit))
    }
}

struct NotesRead: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read one note (HTML body, plaintext, revision hash) by exact name or --id."
    )

    @Argument(help: "Exact note name")
    var name: String?

    @Option(help: "Note id from notes list (disambiguates duplicate names)")
    var id: String?

    func run() throws {
        guard name?.isEmpty == false || id?.isEmpty == false else {
            throw ToolError("notes read requires a name or --id")
        }
        print(try notesReadText(name: name, id: id))
    }
}

struct NotesAppend: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "append",
        abstract: "Append to the end of a note (CAS: requires the revision from a fresh read; refuses notes with attachments; backs up the old body)."
    )

    @Argument(help: "Exact note name")
    var name: String?

    @Option(help: "Note id from notes list (disambiguates duplicate names)")
    var id: String?

    @Option(help: "HTML fragment or plain text to append")
    var content: String

    @Option(name: .customLong("revision"), help: "expected_revision: the hash from a fresh notes read")
    var expectedRevision: String

    func run() throws {
        guard name?.isEmpty == false || id?.isEmpty == false else {
            throw ToolError("notes append requires a name or --id")
        }
        print(try notesAppendText(name: name, id: id, content: content,
                                  expectedRevision: expectedRevision))
    }
}

struct NotesEdit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Exact-string edit of a note's body HTML (old string must occur exactly once; CAS revision; attachments refused; old body backed up)."
    )

    @Argument(help: "Exact note name")
    var name: String?

    @Option(help: "Note id from notes list (disambiguates duplicate names)")
    var id: String?

    @Option(name: .customLong("old"), help: "Exact substring of the current body HTML (must occur exactly once)")
    var oldString: String

    @Option(name: .customLong("new"), help: "Replacement text/HTML")
    var newString: String

    @Option(name: .customLong("revision"), help: "expected_revision: the hash from a fresh notes read")
    var expectedRevision: String

    func run() throws {
        guard name?.isEmpty == false || id?.isEmpty == false else {
            throw ToolError("notes edit requires a name or --id")
        }
        print(try notesEditText(name: name, id: id, oldString: oldString,
                                newString: newString, expectedRevision: expectedRevision))
    }
}

struct NotesCreate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new note (always safe — never touches existing notes)."
    )

    @Argument(help: "Note title")
    var title: String

    @Option(help: "Note content: HTML fragment or plain text")
    var content: String = ""

    @Option(help: "Target folder name")
    var folder: String = "Notes"

    func run() throws {
        print(try notesCreateText(title: title, content: content, folder: folder))
    }
}

struct SafariJS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "js",
        abstract: "Run raw JavaScript in the front page and print the result."
    )

    @Argument(help: "JavaScript source to evaluate")
    var script: String

    func run() throws {
        print(try safariJSText(script: script))
    }
}
