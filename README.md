# mac-kit

Native macOS system capabilities exposed as [MCP](https://modelcontextprotocol.io) tools: Apple Maps (MapKit / CoreLocation), Safari browser automation, on-device OCR (Vision framework), Apple Mail (local index reads + sending via Mail.app), and Apple Notes (guarded read/append/edit/create via Notes.app). A single small executable that works both as an MCP stdio server and as a plain CLI for debugging.

No API keys, no location permission, no entitlements — all inputs are explicit strings, resolved through Apple's public MapKit/CLGeocoder/Vision APIs and Safari's AppleScript interface.

## Requirements

- macOS 13+
- Swift 5.9+ toolchain (Xcode or Command Line Tools)

## Build

```sh
swift build -c release
```

The binary lands at `.build/release/mac-kit`.

```sh
.build/release/mac-kit self-test
```

Runs the built-in unit checks for the pure helpers (hashing, HTML escaping, backup-path sanitization, edit semantics, JXA string construction). No app automation involved, CI-safe, exits nonzero on failure. (This lives in the binary because Command Line Tools-only toolchains ship neither XCTest nor swift-testing, so `swift test` can't link a test bundle.)

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

## Mail

Requires Mail.app with at least one account configured. Reads go straight to Mail's local **Envelope Index** (SQLite, opened strictly read-only with a busy timeout — mac-kit never writes to Mail's data, and Mail.app can keep syncing while you query). Message bodies are parsed from Mail's on-disk `.emlx` files; if Mail hasn't downloaded a body yet (fresh account sync), you still get the metadata plus a "body not downloaded yet" note. Sending goes through Mail.app itself via AppleScript, so sent mail lands in your normal Sent mailbox — the first send triggers a one-time macOS Automation permission prompt for Mail.

```sh
mac-kit mail unread                                 # unread across all accounts, newest first
mac-kit mail unread --account Google --limit 10
mac-kit mail search "Alaska" --since 2026-06-01     # matches subject or sender
mac-kit mail search invoice --account iCloud --mailbox INBOX
mac-kit mail read 31797                             # id from search/unread output
mac-kit mail send you@example.com --subject "Hi" --body "..." --from Google
```

Notes:

- `unread` excludes Junk/Trash/Spam, and for Gmail-style accounts only shows messages still in INBOX (archived unread are skipped).
- `search` matches subject and sender name/address, case-insensitively; `--mailbox` also matches Gmail labels.
- `read` prefers the `text/plain` MIME part and falls back to crudely tag-stripped HTML, truncated to ~6000 chars.
- `send` sends immediately (no draft step). Pick the account with `--from` by account name or address; otherwise Mail's default account is used.

## Apple Notes

Notes.app has no public framework API, so everything goes through its AppleScript dictionary (JXA via `osascript`, program on stdin, all dynamic strings embedded as JSON literals — injection-safe by construction). The first use triggers a one-time macOS Automation permission prompt for Notes.

Mutations are deliberately constrained by four rails (no delete verb, no force flags):

1. **Revision CAS** — `notes_read` returns a `revision` (lowercase hex SHA-256 of the raw HTML body). `notes_append`/`notes_edit` require it back as `expected_revision` and refuse with `REVISION_MISMATCH` if the note changed since the read (the final compare happens inside a single osascript execution, right before the write).
2. **Exact-match uniqueness** (`notes_edit`) — `old_string` must occur exactly once in the body HTML; `NO_MATCH`/`AMBIGUOUS` otherwise, nothing written.
3. **Attachment refusal** — a body write silently destroys a note's attachments, so notes with attachments are refused (`HAS_ATTACHMENTS`). The check fails closed: if the attachment query itself errors, the write is refused too (`ATTACHMENT_CHECK_FAILED`).
4. **Auto-backup** — the previous body is saved to `~/.mac-kit/notes-backups/<name>-<unix-ms>-<nonce>.html` before every mutation (refuse-to-overwrite; collisions get a numeric suffix); if the backup can't be written, the mutation doesn't happen.

One asymmetry is deliberate: once a write has executed, the tool always reports success. Mutations run as two separate osascript executions — execution 1 does CAS + write and returns immediately (no post-write reads, which could hang and trip the timeout after the write landed); execution 2 fetches the new revision and is best-effort at the Swift layer. If execution 2 fails or hangs you get success with `WRITE_OK_REVISION_UNKNOWN` (revision unknown; `notes_read` before the next mutation), because an error after a completed mutation would invite a retry and a duplicate write. If execution 1 itself dies without reporting back (timeout kill), whether the write landed is unknowable — that surfaces as `TIMEOUT_UNKNOWN_STATE`: inspect the note before retrying.

```sh
mac-kit notes list Claw --limit 5                  # metadata only: name/folder/modified/attachments/id
mac-kit notes read "Claw Shared note"              # HTML body + plaintext + revision
mac-kit notes append "Claw Shared note" --content "new line" --revision <hash>
mac-kit notes edit "Claw Shared note" --old "<div>foo</div>" --new "<div>bar</div>" --revision <hash>
mac-kit notes create "Title" --content "body text" --folder Notes
```

Content (`append`/`create`) may be an HTML fragment or plain text — plain text is entity-escaped and wrapped one `<div>` per line. `notes_edit` matches against the raw HTML body (tags included): `notes_read` first and copy exact HTML context. Folder is reported as null for shared notes (Notes raises -1700 on their `container` query).

## MCP server

```sh
mac-kit serve
```

Speaks MCP over stdio (newline-delimited JSON-RPC 2.0). Exposes twenty tools:

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
| `mail_unread` | `account`, `limit` (default 20) | Unread messages, newest first: `[id] date subject / from (account / mailbox)` |
| `mail_search` | `query` (required), `account`, `mailbox`, `since`, `limit` (default 20) | Matching messages in the same shape, with ids for `mail_read` |
| `mail_read` | `id` (required) | Headers (from/to/cc/date/subject/mailbox) + text body (~6000 chars) |
| `mail_send` | `to`, `subject`, `body` (required), `from_account`, `cc`, `bcc` | Send confirmation (sends immediately via Mail.app) |
| `mail_archive` | `id` or `ids[]` (from `mail_search`/`mail_unread`) | Takes messages out of the inbox. Standard IMAP (iCloud/custom domains): moves INBOX → Archive. Gmail: removes the INBOX label (a plain move to All Mail is a server-side no-op, so it deletes the INBOX copy then refiles it into All Mail — both real IMAP moves; the message ends up archived in All Mail). Re-checks mailbox membership after and reports the resulting state per id. Reversible — never deletes |
| `notes_list` | `query`, `limit` (default 20) | Note metadata only (never bodies): name, folder (null for shared notes), modified, hasAttachments, id. Newest first |
| `notes_read` | `name` or `id` | HTML body + plaintext + hasAttachments + `revision` (SHA-256 of body). Errors listing candidate ids if several notes share the name |
| `notes_append` | `name`/`id`, `content`, `expected_revision` (required) | Appends to the end of the note under the CAS/attachment/backup rails; returns the new revision |
| `notes_edit` | `name`/`id`, `old_string`, `new_string`, `expected_revision` (required) | Exact-string edit of the body HTML; `old_string` must occur exactly once (`NO_MATCH`/`AMBIGUOUS` otherwise). Same rails as append; returns the new revision |
| `notes_create` | `title`, `content` (required), `folder` (default "Notes") | Creates a new note (never touches existing ones); returns name, id, revision |

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
