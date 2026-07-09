import CryptoKit
import Foundation

// MARK: - Apple Notes tools
//
// Notes.app has no public framework API, so everything goes through its
// AppleScript dictionary, driven as JXA via `runJXA` (osascript reads the
// program from stdin — no shell layer). Every dynamic value crossing into the
// JXA source is embedded with `jsLiteral` (a JSON string literal, which is a
// strict subset of a JavaScript string literal), so note names, ids, bodies,
// and user content can never break out of their string context — the same
// injection-safety approach SafariTools/MailTools use.
//
// Safety model (the whole point of these tools). Four rails apply to every
// mutating verb; there is deliberately NO delete verb and NO force flag:
//   1. Revision CAS: notes_append/notes_edit require expected_revision (the
//      SHA-256 of the raw HTML body from a fresh notes_read) and refuse to
//      write if the note changed since (REVISION_MISMATCH).
//   2. Exact-match uniqueness (notes_edit): old_string must occur exactly
//      once in the body HTML — NO_MATCH / AMBIGUOUS otherwise, nothing
//      written.
//   3. Attachment refusal: a body write silently destroys a note's
//      attachments, so any note with attachments is refused outright
//      (HAS_ATTACHMENTS). The check fails CLOSED: if the attachment query
//      itself errors, the write is refused too (ATTACHMENT_CHECK_FAILED).
//   4. Auto-backup: the previous body is written to
//      ~/.mac-kit/notes-backups/ before any mutation; if the backup fails,
//      the write does not happen.
// notes_list / notes_read are read-only; notes_create only ever makes a new
// note.

// MARK: - Pure helpers (unit-tested)

/// Lowercase hex SHA-256 of a string's UTF-8 bytes. This is the "revision"
/// notes_read returns and notes_append demands back.
func sha256Hex(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Heuristic: content that contains something tag-shaped (`<` followed by a
/// letter, `/`, or `!`) is treated as an HTML fragment and passed through
/// verbatim; everything else is treated as plain text and gets escaped.
func notesLooksLikeHTML(_ content: String) -> Bool {
    content.range(of: "<[A-Za-z/!]", options: .regularExpression) != nil
}

/// Escape a plain-text run for use inside an HTML text node.
func escapeHTMLText(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Convert tool `content` into a Notes-ready HTML fragment: HTML passes
/// through untouched; plain text is entity-escaped and wrapped one <div> per
/// line (blank lines become <div><br></div>), which is how Notes itself
/// represents paragraphs.
func notesHTMLFragment(from content: String) -> String {
    if notesLooksLikeHTML(content) { return content }
    return content.replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: "\n")
        .map { line in
            line.isEmpty ? "<div><br></div>" : "<div>\(escapeHTMLText(line))</div>"
        }
        .joined()
}

/// Filesystem-safe stem for a backup file: keep alphanumerics (any script)
/// plus "-", "_", "."; everything else collapses to "_". Leading/trailing
/// "_"/"." are trimmed (no hidden files), capped at 80 characters, never empty.
func notesBackupStem(_ name: String) -> String {
    var out = ""
    for scalar in name.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar)
            || scalar == "-" || scalar == "_" || scalar == "." {
            out.unicodeScalars.append(scalar)
        } else if !out.hasSuffix("_") {
            out.append("_")
        }
    }
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_."))
    if out.count > 80 { out = String(out.prefix(80)) }
    return out.isEmpty ? "note" : out
}

/// "<stem>-<unixMillis>-<nonce>.html", with a "-<attempt>" suffix for
/// collision retries. Millisecond timestamp + random nonce + refuse-to-
/// overwrite (see writeNoteBackup) means two mutations of the same note in
/// the same second can never silently clobber each other's backup.
func notesBackupFileName(noteName: String, unixMillis: Int64, nonce: String, attempt: Int = 0) -> String {
    let base = "\(notesBackupStem(noteName))-\(unixMillis)-\(nonce)"
    return attempt == 0 ? "\(base).html" : "\(base)-\(attempt).html"
}

/// notes_edit core: replace `oldString` with `newString` in `body`, requiring
/// exactly one (case-sensitive) occurrence. Occurrences are counted
/// overlapping-aware — the scan advances one character past each match START
/// rather than past the whole match — because "aaa" genuinely contains "aa"
/// at two positions; a non-overlapping count would call that unique and
/// silently pick the first. Throws NO_MATCH on zero and AMBIGUOUS on more
/// than one — the same contract as a code editor's exact-string edit.
func notesApplyUniqueEdit(body: String, oldString: String, newString: String) throws -> String {
    var count = 0
    var firstRange: Range<String.Index>?
    var searchStart = body.startIndex
    while let range = body.range(of: oldString, range: searchStart..<body.endIndex) {
        count += 1
        if firstRange == nil { firstRange = range }
        searchStart = body.index(after: range.lowerBound)
    }
    guard count > 0, let firstRange else {
        throw ToolError("NO_MATCH: old_string not found in the note's body HTML (note may have changed; re-read)")
    }
    guard count == 1 else {
        throw ToolError("AMBIGUOUS: old_string occurs \(count) times (overlapping matches counted); provide more surrounding context")
    }
    return body.replacingCharacters(in: firstRange, with: newString)
}

/// The attachment rail as one pure decision so every enforcement point agrees.
/// `count` semantics: >0 attachments present; 0 verified none; <0 the
/// attachment query itself FAILED. A failed check refuses too — fail CLOSED:
/// the rail exists precisely for attachments we could not rule out. The two
/// refusals carry distinct codes so callers can tell them apart.
func notesAttachmentRailError(count: Int) -> String? {
    if count > 0 {
        return "HAS_ATTACHMENTS: body write would destroy attachments; refusing"
    }
    if count < 0 {
        return "ATTACHMENT_CHECK_FAILED: could not verify the note has no attachments; refusing to write"
    }
    return nil
}

/// Result text for a COMPLETED append/edit. `newBody == nil` means the write
/// succeeded but the post-write re-read failed — that must still be reported
/// as success (an error here would invite a retry and a duplicate mutation);
/// the caller just doesn't get a new revision and must notes_read before the
/// next mutation.
func notesMutationResultText(headline: String, oldRevision: String,
                             newBody: String?, backupPath: String) -> String {
    let newRevisionLine: String
    if let newBody {
        newRevisionLine = "New revision: \(sha256Hex(newBody))"
    } else {
        newRevisionLine = "New revision: unknown — WRITE_OK_REVISION_UNKNOWN: the write succeeded"
            + " but the post-write re-read failed; call notes_read before the next mutation"
    }
    return """
    \(headline)
    Old revision: \(oldRevision)
    \(newRevisionLine)
    Backup of previous body: \(backupPath)
    """
}

// MARK: - JXA plumbing

/// Run a Notes JXA program that returns a JSON object string; parse it and
/// surface `{err: "..."}` as a ToolError.
private func runNotesJSON(_ source: String, timeout: TimeInterval) throws -> [String: Any] {
    let raw = try runJXA(source, timeout: timeout)
    guard let data = raw.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw ToolError("Unexpected response from Notes.app: \(String(raw.prefix(300)))")
    }
    if let err = object["err"] as? String { throw ToolError(err) }
    return object
}

// MARK: - Reading a note (shared by notes_read and notes_append)

struct NoteSnapshot {
    let name: String
    let id: String
    let folder: String?        // nil when Notes refuses the container query (shared notes)
    let body: String           // raw HTML
    let plaintext: String
    let attachmentCount: Int   // <0 means the attachment query itself failed
    var revision: String { sha256Hex(body) }
    var hasAttachments: Bool { attachmentCount > 0 }
}

/// Resolve a note by exact name (AppleScript equality — case-insensitive) or
/// by id, and read its full state in one osascript execution.
private func readNoteSnapshot(name: String?, id: String?) throws -> NoteSnapshot {
    let source = """
    function run() {
      const Notes = Application('Notes');
      const wantName = \(jsLiteral(name ?? ""));
      const wantId = \(jsLiteral(id ?? ""));
      let note = null;
      if (wantId) {
        note = Notes.notes.byId(wantId);
        try { note.name(); } catch (e) {
          return JSON.stringify({err: 'no note with id "' + wantId + '"'});
        }
      } else {
        let matches = [];
        try { matches = Notes.notes.whose({name: wantName})(); } catch (e) {}
        if (matches.length === 0) {
          return JSON.stringify({err: 'no note named "' + wantName
            + '" — exact name required; use notes_list to find it'});
        }
        if (matches.length > 1) {
          const candidates = matches.slice(0, 10).map(function (n) {
            let folder = null;
            try { folder = String(n.container().name()); } catch (e) {}
            let modified = null;
            try { const d = n.modificationDate(); if (d) modified = d.toISOString(); } catch (e) {}
            let nid = null;
            try { nid = String(n.id()); } catch (e) {}
            return {id: nid, folder: folder, modified: modified};
          });
          return JSON.stringify({ambiguous: true, count: matches.length, candidates: candidates});
        }
        note = matches[0];
      }
      let body;
      try { body = String(note.body()); } catch (e) {
        return JSON.stringify({err: 'cannot read note body (password-protected?): ' + e});
      }
      let plaintext = '';
      try { plaintext = String(note.plaintext()); } catch (e) {}
      // Attachment check fails CLOSED: -1 sentinel when the query errors, so
      // mutations refuse rather than assume "no attachments".
      let attachmentCount = -1;
      try { attachmentCount = note.attachments.length; } catch (e) {}
      // `container of` raises -1700 for shared notes; report folder as null.
      let folder = null;
      try { folder = String(note.container().name()); } catch (e) {}
      return JSON.stringify({ok: true, name: String(note.name()), id: String(note.id()),
        folder: folder, body: body, plaintext: plaintext, attachmentCount: attachmentCount});
    }
    """
    let object = try runNotesJSON(source, timeout: 60)
    if object["ambiguous"] as? Bool == true {
        let count = object["count"] as? Int ?? 0
        var lines = ["\(count) notes share the name \"\(name ?? "")\" — call again with \"id\" instead:"]
        for candidate in object["candidates"] as? [[String: Any]] ?? [] {
            let cid = candidate["id"] as? String ?? "?"
            let folder = candidate["folder"] as? String ?? "unknown folder"
            let modified = candidate["modified"] as? String ?? "?"
            lines.append("  id: \(cid)  (folder: \(folder), modified: \(modified))")
        }
        throw ToolError(lines.joined(separator: "\n"))
    }
    guard
        let noteName = object["name"] as? String,
        let noteId = object["id"] as? String,
        let body = object["body"] as? String
    else {
        throw ToolError("Malformed response from Notes.app while reading note")
    }
    return NoteSnapshot(
        name: noteName,
        id: noteId,
        folder: object["folder"] as? String,
        body: body,
        plaintext: object["plaintext"] as? String ?? "",
        // Missing count decodes as the fail-closed sentinel, not as "none".
        attachmentCount: (object["attachmentCount"] as? NSNumber)?.intValue ?? -1
    )
}

// MARK: - Formatting

private let notesDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

private func formatISODate(_ iso: String?) -> String {
    guard let iso else { return "?" }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: iso) {
        return notesDateFormatter.string(from: date)
    }
    parser.formatOptions = [.withInternetDateTime]
    if let date = parser.date(from: iso) {
        return notesDateFormatter.string(from: date)
    }
    return iso
}

private func truncated(_ text: String, cap: Int) -> String {
    guard text.count > cap else { return text }
    let cut = text.index(text.startIndex, offsetBy: cap)
    return String(text[..<cut]) + "\n[truncated: showing \(cap) of \(text.count) chars]"
}

// MARK: - notes_list

func notesListText(query: String?, limit: Int) throws -> String {
    let source = """
    function run() {
      const Notes = Application('Notes');
      const query = \(jsLiteral((query ?? "").lowercased()));
      const limit = \(max(1, limit));
      let names, dates;
      try {
        names = Notes.notes.name();
        dates = Notes.notes.modificationDate();
      } catch (e) {
        return JSON.stringify({err: 'cannot list notes: ' + e});
      }
      let idx = [];
      for (let i = 0; i < names.length; i++) {
        if (!query || String(names[i] || '').toLowerCase().indexOf(query) !== -1) idx.push(i);
      }
      const matched = idx.length;
      idx.sort(function (a, b) { return (dates[b] || 0) - (dates[a] || 0); });
      idx = idx.slice(0, limit);
      const out = [];
      for (const i of idx) {
        const note = Notes.notes[i];
        // `container of` raises -1700 for shared notes — folder stays null.
        let folder = null;
        try { folder = String(note.container().name()); } catch (e) {}
        let hasAttachments = false;
        try { hasAttachments = note.attachments.length > 0; } catch (e) {}
        let id = null;
        try { id = String(note.id()); } catch (e) {}
        out.push({name: String(names[i] || ''), id: id, folder: folder,
          modified: dates[i] ? dates[i].toISOString() : null,
          hasAttachments: hasAttachments});
      }
      return JSON.stringify({ok: true, total: names.length, matched: matched, notes: out});
    }
    """
    let object = try runNotesJSON(source, timeout: 90)
    let notes = object["notes"] as? [[String: Any]] ?? []
    let matched = (object["matched"] as? NSNumber)?.intValue ?? notes.count
    if notes.isEmpty {
        if let query, !query.isEmpty { return "No notes match \"\(query)\"." }
        return "No notes found."
    }
    var header = "\(notes.count) of \(matched) note(s)"
    if let query, !query.isEmpty { header += " matching \"\(query)\"" }
    header += " (newest first; metadata only — use notes_read for content):"
    var lines = [header]
    for (index, note) in notes.enumerated() {
        let name = note["name"] as? String ?? "(unnamed)"
        let folder = note["folder"] as? String ?? "unknown (shared note?)"
        let modified = formatISODate(note["modified"] as? String)
        let attachments = (note["hasAttachments"] as? Bool ?? false) ? "yes" : "no"
        let id = note["id"] as? String ?? "?"
        lines.append("""
        \(index + 1). \(name)
           folder: \(folder)  modified: \(modified)  attachments: \(attachments)
           id: \(id)
        """)
    }
    return lines.joined(separator: "\n")
}

// MARK: - notes_read

func notesReadText(name: String?, id: String?) throws -> String {
    let snapshot = try readNoteSnapshot(name: name, id: id)
    var plaintext = snapshot.plaintext
    if plaintext.isEmpty, !snapshot.body.isEmpty {
        plaintext = EmlxParser.stripHTML(snapshot.body)
    }
    let cap = 8000
    let attachmentsLine = snapshot.attachmentCount < 0
        ? "unknown — attachment check failed; append/edit will refuse (ATTACHMENT_CHECK_FAILED)"
        : "\(snapshot.hasAttachments) (\(snapshot.attachmentCount))"
    return """
    Name: \(snapshot.name)
    Id: \(snapshot.id)
    Folder: \(snapshot.folder ?? "unknown (shared note?)")
    HasAttachments: \(attachmentsLine)
    Revision: \(snapshot.revision)

    Plaintext:
    \(truncated(plaintext, cap: cap))

    Body (HTML):
    \(truncated(snapshot.body, cap: cap))
    """
}

// MARK: - Shared mutation rails (notes_append + notes_edit)

/// Rails 1 and 3 for any mutating verb: read the note and enforce the
/// revision CAS and the attachment refusal. Verb-specific validation (e.g.
/// notes_edit's uniqueness rail) runs after this; the backup (rail 4) is
/// written last, only once the mutation is definitely going ahead.
private func snapshotForMutation(name: String?, id: String?,
                                 expectedRevision: String) throws -> NoteSnapshot {
    let revision = expectedRevision.lowercased()
    guard revision.count == 64, revision.allSatisfy({ $0.isHexDigit }) else {
        throw ToolError("expected_revision must be the 64-char hex revision returned by notes_read")
    }

    let snapshot = try readNoteSnapshot(name: name, id: id)
    if snapshot.revision != revision {
        throw ToolError("REVISION_MISMATCH: note changed since read; re-read and retry")
    }
    // Fail-closed attachment rail: refuses on attachments present AND on a
    // failed attachment check (attachmentCount < 0).
    if let railError = notesAttachmentRailError(count: snapshot.attachmentCount) {
        throw ToolError(railError)
    }
    return snapshot
}

/// Rail 4: back up the note's current body BEFORE any write. If the backup
/// cannot be written, the mutation does not happen. Filenames carry a
/// millisecond timestamp plus a random nonce, and the write refuses to
/// overwrite (O_EXCL semantics via .withoutOverwriting) — on the vanishingly
/// unlikely collision it retries with a numeric suffix rather than ever
/// clobbering an existing backup.
private func writeNoteBackup(of snapshot: NoteSnapshot, verb: String) throws -> String {
    let backupDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mac-kit/notes-backups")
    try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
    let millis = Int64(Date().timeIntervalSince1970 * 1000)
    let nonce = String(format: "%04x", UInt16.random(in: .min ... .max))
    for attempt in 0..<8 {
        let backupURL = backupDir.appendingPathComponent(
            notesBackupFileName(noteName: snapshot.name, unixMillis: millis,
                                nonce: nonce, attempt: attempt)
        )
        do {
            try Data(snapshot.body.utf8).write(to: backupURL, options: .withoutOverwriting)
            return backupURL.path
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
            continue // collision: try the next numeric suffix, never overwrite
        } catch {
            throw ToolError("Refusing to \(verb): could not write backup to \(backupURL.path): \(error)")
        }
    }
    throw ToolError("Refusing to \(verb): could not find a free backup filename in \(backupDir.path)")
}

/// Compare-and-swap body write. The read + string-compare + write all happen
/// inside ONE osascript execution, so the window between the Swift-side hash
/// check and the actual write is closed by re-comparing the full body
/// in-process (the new body was computed from exactly that expected body).
/// Residual race: Notes' scripting interface has no atomic primitive, so a
/// sync landing in the few ms between `note.body()` and `note.body = ...`
/// below could still be lost. That window is as tight as the platform allows.
///
/// Post-write contract: once `note.body = newBody` has executed, this
/// function reports SUCCESS no matter what — a post-write re-read failure
/// returns `(name, nil)` rather than throwing, because an error after a
/// completed mutation would invite a retry and a duplicate write.
private func casWriteBody(noteId: String, expectedBody: String,
                          newBody: String) throws -> (name: String?, body: String?) {
    let source = """
    function run() {
      const Notes = Application('Notes');
      const noteId = \(jsLiteral(noteId));
      const expectedBody = \(jsLiteral(expectedBody));
      const newBody = \(jsLiteral(newBody));
      const note = Notes.notes.byId(noteId);
      try { note.name(); } catch (e) {
        return JSON.stringify({err: 'note disappeared (id no longer resolves)'});
      }
      let current;
      try { current = String(note.body()); } catch (e) {
        return JSON.stringify({err: 'cannot read note body: ' + e});
      }
      if (current !== expectedBody) return JSON.stringify({conflict: true});
      // Re-check attachments inside the CAS window, fail CLOSED: an errored
      // query reports -1 and refuses, exactly like a positive count.
      let attachmentCount = -1;
      try { attachmentCount = note.attachments.length; } catch (e) {}
      if (attachmentCount !== 0) return JSON.stringify({attachmentCount: attachmentCount});
      note.body = newBody;
      // THE MUTATION IS DONE. From here on, never return err — best-effort
      // re-reads only, so the caller always learns the write happened.
      let readBack = null;
      let readName = null;
      try { readBack = String(note.body()); } catch (e) {}
      try { readName = String(note.name()); } catch (e) {}
      return JSON.stringify({ok: true, name: readName, body: readBack});
    }
    """
    let object = try runNotesJSON(source, timeout: 90)
    if object["conflict"] as? Bool == true {
        throw ToolError("REVISION_MISMATCH: note changed since read; re-read and retry")
    }
    if let count = (object["attachmentCount"] as? NSNumber)?.intValue,
       let railError = notesAttachmentRailError(count: count) {
        throw ToolError(railError)
    }
    guard object["ok"] as? Bool == true else {
        throw ToolError("Malformed response from Notes.app after write")
    }
    return (object["name"] as? String, object["body"] as? String)
}

// MARK: - notes_append

func notesAppendText(name: String?, id: String?, content: String, expectedRevision: String) throws -> String {
    let snapshot = try snapshotForMutation(name: name, id: id, expectedRevision: expectedRevision)
    let newBody = snapshot.body + "<div><br></div>" + notesHTMLFragment(from: content)
    let backupPath = try writeNoteBackup(of: snapshot, verb: "append")
    let written = try casWriteBody(noteId: snapshot.id, expectedBody: snapshot.body, newBody: newBody)
    return notesMutationResultText(
        headline: "Appended to \"\(written.name ?? snapshot.name)\".",
        oldRevision: snapshot.revision, newBody: written.body, backupPath: backupPath
    )
}

// MARK: - notes_edit

func notesEditText(name: String?, id: String?, oldString: String, newString: String,
                   expectedRevision: String) throws -> String {
    guard !oldString.isEmpty else {
        throw ToolError("notes_edit requires a non-empty \"old_string\"")
    }
    guard oldString != newString else {
        throw ToolError("old_string and new_string are identical — nothing to edit")
    }
    let snapshot = try snapshotForMutation(name: name, id: id, expectedRevision: expectedRevision)
    // Rail 2: old_string must occur exactly once in the raw HTML body
    // (NO_MATCH / AMBIGUOUS otherwise — checked before anything is written,
    // including the backup).
    let newBody = try notesApplyUniqueEdit(body: snapshot.body,
                                           oldString: oldString, newString: newString)
    let backupPath = try writeNoteBackup(of: snapshot, verb: "edit")
    let written = try casWriteBody(noteId: snapshot.id, expectedBody: snapshot.body, newBody: newBody)
    return notesMutationResultText(
        headline: "Edited \"\(written.name ?? snapshot.name)\" (1 replacement).",
        oldRevision: snapshot.revision, newBody: written.body, backupPath: backupPath
    )
}

// MARK: - notes_create

func notesCreateText(title: String, content: String, folder: String?) throws -> String {
    let folderName = (folder?.isEmpty == false) ? folder! : "Notes"
    // Notes derives a note's name from the first line of its body, so the
    // title goes in as a leading <h1>.
    var html = "<div><h1>\(escapeHTMLText(title))</h1></div>"
    if !content.isEmpty {
        html += notesHTMLFragment(from: content)
    }
    let source = """
    function run() {
      const Notes = Application('Notes');
      const wantFolder = \(jsLiteral(folderName.lowercased()));
      const html = \(jsLiteral(html));
      let names;
      try { names = Notes.folders.name(); } catch (e) {
        return JSON.stringify({err: 'cannot list Notes folders: ' + e});
      }
      let folder = null;
      for (let i = 0; i < names.length; i++) {
        if (String(names[i]).toLowerCase() === wantFolder) { folder = Notes.folders[i]; break; }
      }
      if (!folder) {
        return JSON.stringify({err: 'no folder named ' + JSON.stringify(wantFolder)
          + '. Folders: ' + names.join(', ')});
      }
      const note = Notes.Note({body: html});
      folder.notes.push(note);
      // THE NOTE EXISTS from here on — never return err after the push, or a
      // retry would create a duplicate. Post-create reads are best-effort.
      let body = null;
      let name = null;
      let id = null;
      try { body = String(note.body()); } catch (e) {}
      try { name = String(note.name()); } catch (e) {}
      try { id = String(note.id()); } catch (e) {}
      return JSON.stringify({ok: true, name: name, id: id, body: body});
    }
    """
    let object = try runNotesJSON(source, timeout: 60)
    guard object["ok"] as? Bool == true else {
        throw ToolError("Malformed response from Notes.app after create")
    }
    let revisionLine: String
    if let body = object["body"] as? String {
        revisionLine = "Revision: \(sha256Hex(body))"
    } else {
        revisionLine = "Revision: unknown — WRITE_OK_REVISION_UNKNOWN: the note was created"
            + " but the post-create re-read failed; call notes_read before mutating it"
    }
    return """
    Created note "\(object["name"] as? String ?? title)" in folder "\(folderName)".
    Id: \(object["id"] as? String ?? "unknown — post-create re-read failed")
    \(revisionLine)
    """
}
