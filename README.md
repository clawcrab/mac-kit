# mac-kit

Native macOS system capabilities exposed as [MCP](https://modelcontextprotocol.io) tools: Apple Maps (MapKit / CoreLocation), Safari browser automation, and on-device OCR (Vision framework). A single small executable that works both as an MCP stdio server and as a plain CLI for debugging.

No API keys, no location permission, no entitlements — all inputs are explicit strings, resolved through Apple's public MapKit/CLGeocoder/Vision APIs and Safari's AppleScript interface.

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

## OCR

Extracts text from local raster images (PNG, JPEG, HEIC, TIFF) using Apple's Vision framework — fully on-device, no network, no permissions. Lines come back in reading order (top-to-bottom, left-to-right) with a per-line confidence score.

```sh
mac-kit ocr ~/Desktop/receipt.heic
mac-kit ocr screenshot.png --lang zh-Hans,en-US    # default languages
```

## Safari automation

Drives the *real* Safari (your session, your cookies) via AppleScript/JXA — no WebDriver, no headless browser. The flow mirrors agent-style browser tools: open a page, snapshot the interactive elements to get refs, then click/fill by ref.

### Prerequisites (two Safari settings)

1. Safari → Settings → Advanced → **Show features for web developers** (enables the Develop menu).
2. Develop menu → Developer Settings → **Allow JavaScript from Apple Events** (Safari will ask you to confirm).

The first run may also trigger a one-time macOS Automation permission prompt for whatever terminal/app launches `mac-kit`.

### CLI usage

```sh
mac-kit safari open https://news.ycombinator.com   # waits for readyState=complete (15s max)
mac-kit safari snapshot                            # lists elements: [e12] link "48 comments" (...)
mac-kit safari click e12                           # synthetic click by ref
mac-kit safari fill e3 "search terms"              # set value + dispatch input/change
mac-kit safari read                                # title + URL + body text (~8000 chars)
mac-kit safari js "document.title"                 # raw JavaScript escape hatch
```

Snapshot refs (`e0`, `e1`, ...) are stored in the page (`window.__mk`) and stay valid until the next snapshot or navigation — re-snapshot after clicking anything that loads a new page.

### Scope and caveats

- All actions target Safari's **front window/tab**; `safari open` reuses it rather than opening new windows.
- Clicks and fills are synthetic DOM events. Most sites are fine with this; heavily framework-bound widgets occasionally need the `safari js` escape hatch.
- Main document only — elements inside cross-origin iframes are not visible to the snapshot.

## MCP server

```sh
mac-kit serve
```

Speaks MCP over stdio (newline-delimited JSON-RPC 2.0). Exposes ten tools:

| Tool | Arguments | Returns |
| --- | --- | --- |
| `map_search` | `query` (required), `near`, `limit` (default 5) | POIs with name, address, coordinates, phone/URL, distance from `near` |
| `map_geocode` | `query` OR `lat` + `lon` | Normalized address + coordinates |
| `map_eta` | `from`, `to` (required), `transport` (default driving) | Best route ETA/distance/first steps + alternative routes |
| `safari_open` | `url` (required) | Final URL + title + readyState after load |
| `safari_snapshot` | — | Interactive elements with refs: `[e12] link "48 comments" (...)` |
| `safari_click` | `ref` (required) | ok + post-click readyState/title/URL |
| `safari_fill` | `ref`, `text` (required) | ok (value set, input/change dispatched) |
| `safari_read` | — | Title + URL + page text (~8000 chars) |
| `safari_js` | `script` (required) | Result of evaluating the script in the page |
| `vision_ocr` | `path` (required), `languages` (default `["zh-Hans","en-US"]`) | Recognized text lines in reading order with confidence |

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
- OCR runs entirely on-device via Vision's `VNRecognizeTextRequest` (accurate recognition level, latest model revision, language correction on). Automatic language detection is enabled, and `zh-Hans` + `en-US` are passed as explicit hints since auto-detection is unreliable on short or mixed-script text.
- Safari tools shell out to `/usr/bin/osascript -l JavaScript` (JXA) with the program passed on stdin; all dynamic strings are embedded as JSON literals, so quotes/newlines/backslashes in URLs, text, or scripts are safe. Per-call timeout is 20s (25s for `safari_open`).
- If "Allow JavaScript from Apple Events" is off, safari tools fail with an error that includes a hint pointing at the setting.
- Tool failures are returned as MCP tool errors (`isError: true`); the server loop never crashes on bad input.
