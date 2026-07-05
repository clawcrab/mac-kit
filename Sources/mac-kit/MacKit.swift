import ArgumentParser
import Foundation

@main
struct MacKit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac-kit",
        abstract: "Native macOS system capabilities (MapKit) as MCP tools and CLI commands.",
        version: MCPServer.serverVersion,
        subcommands: [Serve.self, Search.self, Geocode.self, Eta.self]
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
