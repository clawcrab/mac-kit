import ArgumentParser
import Foundation

@main
struct MacKit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac-kit",
        abstract: "Native macOS system capabilities (MapKit, Safari, Vision OCR) as MCP tools and CLI commands.",
        version: MCPServer.serverVersion,
        subcommands: [Serve.self, Search.self, Geocode.self, Eta.self, SafariCommand.self, Ocr.self]
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
