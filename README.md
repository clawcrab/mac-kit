# mac-kit

Native macOS system capabilities exposed as [MCP](https://modelcontextprotocol.io) tools, starting with Apple Maps (MapKit / CoreLocation). A single small executable that works both as an MCP stdio server and as a plain CLI for debugging.

No API keys, no location permission, no entitlements — all inputs are explicit strings, resolved through Apple's public MapKit/CLGeocoder APIs.

## Requirements

- macOS 13+
- Swift 5.9+ toolchain (Xcode or Command Line Tools)

## Build

```sh
swift build -c release
```

The binary lands at `.build/release/mac-kit`.

## CLI usage

```sh
mac-kit search "coffee near Fremont Seattle"
mac-kit search "boba" --near "Bellevue WA" --limit 3
mac-kit geocode "400 Broad St Seattle"
mac-kit geocode --lat 47.6205 --lon -122.3493        # reverse
mac-kit eta "1 Apple Park Way Cupertino" "SEA airport"     # driving by default
mac-kit eta "Pike Place Market" "Space Needle" --transport walking
```

Transport modes: `driving` (ETA includes current traffic), `walking`, `transit` (ETA only — MapKit does not provide transit route steps).

## MCP server

```sh
mac-kit serve
```

Speaks MCP over stdio (newline-delimited JSON-RPC 2.0). Exposes three tools:

| Tool | Arguments | Returns |
| --- | --- | --- |
| `map_search` | `query` (required), `near`, `limit` (default 5) | POIs with name, address, coordinates, phone/URL, distance from `near` |
| `map_geocode` | `query` OR `lat` + `lon` | Normalized address + coordinates |
| `map_eta` | `from`, `to` (required), `transport` (default driving) | Best route ETA/distance/first steps + alternative routes |

### Wiring into an MCP client

Add to your client's `mcpServers` config (adjust the path to where you cloned this):

```json
{
  "mcpServers": {
    "mac-kit": {
      "command": "/Users/you/Developer/mac-kit/.build/release/mac-kit",
      "args": ["serve"]
    }
  }
}
```

## Notes

- Apple's geocoder (CLGeocoder) is rate-limited (~1 request/second). mac-kit issues geocodes sequentially and retries once with a 2s backoff on transient errors (including MapKit throttling like `MKError.loadingThrottled`).
- Place resolution for `map_eta` uses MKLocalSearch (handles both street addresses and POI names like "SEA airport"), falling back to CLGeocoder.
- Tool failures are returned as MCP tool errors (`isError: true`); the server loop never crashes on bad input.
