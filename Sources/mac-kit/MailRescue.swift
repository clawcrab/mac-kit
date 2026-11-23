import Foundation

// MARK: mail_rescue_recovered — put mail Mail.app quarantined back into All Mail
//
// A Gmail Trash -> All Mail refile (mail_archive) can half-complete: the
// server side is fine, but Mail.app drops its local copy into the
// application-level "Recovered Messages (Google)" mailbox (a local:// mailbox,
// not an IMAP one). mail_archive used to sweep it automatically; that sweep
// moved by Message-ID alone and counted the move as success, so it was
// removed. This tool is the manual, explicit replacement.
//
// Scope, deliberately narrow:
//   • it only ever moves a message OUT of "Recovered Messages (Google)" and
//     only INTO "[Gmail]/All Mail" of the Google account — one message per
//     Mail.app call, and only the caller-visible row (Mail.app id == Envelope
//     Index ROWID) that carries the message's fingerprint;
//   • it never deletes, never touches INBOX or Trash;
//   • the default is a dry run that lists what is there and what would happen;
//     apply moves exactly one message, named by its id.
//
// The verdict is about Mail.app's LOCAL state only: MOVED_LOCALLY means the
// local index shows the message in All Mail, which does not prove the Gmail
// server has it (an offline or delayed upload looks the same locally). No
// server check is attempted.
//
// The local verdict is judged by the END STATE in the Envelope Index (read-only), never
// by the move call returning: after the move, the message's fingerprint
// (Message-ID + Date header, the same rule mail_archive uses) must be gone
// from Recovered and present exactly once in All Mail as a copy created by
// this run (ROWID above the watermark), with no copy in Trash. Observed
// 2026-11-23: right after a manual move the index briefly listed both an All
// Mail and a Trash copy (50747/50748) before settling on All Mail alone, so
// the end state is re-read every 5s and only counts once two consecutive
// looks, at least 5s apart, show the identical state; anything not settled
// within 30s is UNKNOWN. A timed-out or failed move call is UNKNOWN whatever
// the index says. Each observation is ONE SQL statement over all three
// mailboxes, so it is a single snapshot of the index.
//
// No batches: apply takes exactly one explicit id and moves only that row.
// The dry run is how you find the ids (and which ones are eligible).
//
// Source and destination are pinned to the identities the index check uses:
// the Mail.app account by id (== the UUID in the index's mailbox URL), All
// Mail by its full path "[Gmail]/All Mail", the quarantine by exact name —
// each must match exactly once on both sides, or nothing is moved.

let rescueAccountName = "Google"
let rescueRecoveredMailboxName = "Recovered Messages (\(rescueAccountName))"
let rescueAllMailPath = "[Gmail]/All Mail"
let rescueTrashPath = "[Gmail]/Trash"

/// Swift twin of `fingerprintFilter` in gmailArchiveCriterionJS (self-test
/// cross-checks the two on the same vectors so they cannot drift): the ids of
/// the candidates whose Date is within a second of `ds`, or nil — fail
/// closed — when the target's or any candidate's Date is unknown.
func mailFingerprintFilter(_ cands: [(id: Int64, ds: Int64?)], ds: Int64?) -> [Int64]? {
    guard let ds, ds >= 0 else { return nil }
    var out: [Int64] = []
    for cand in cands {
        guard let cds = cand.ds else { return nil }
        if abs(cds - ds) <= 1 { out.append(cand.id) }
    }
    return out
}

enum RescueStatus: String {
    /// The LOCAL index shows it in All Mail. Not proof that Gmail's server
    /// has it: an offline or delayed upload looks exactly the same locally.
    case movedLocally = "MOVED_LOCALLY"
    case stillInRecovered = "STILL_IN_RECOVERED"
    case unknown = "UNKNOWN"
}

/// What the Mail.app move call reported. Only `.moved` can lead to MOVED_LOCALLY.
enum RescueMove: Equatable {
    case moved                     // Mail.move returned normally
    case notAttempted(String)      // refused before calling Mail.move
    case indeterminate(String)     // timed out / threw — the move may or may not have happened
}

/// Fingerprint-matching ROWIDs per mailbox, read from the Envelope Index.
/// nil means that lookup failed (or a Date was unreadable).
struct RescueState: Equatable {
    var recovered: [Int64]?
    var allMail: [Int64]?
    var trash: [Int64]?

    var summary: String {
        func f(_ ids: [Int64]?) -> String {
            guard let ids else { return "?" }
            return ids.isEmpty ? "0" : "\(ids.count) [\(ids.map(String.init).joined(separator: ","))]"
        }
        return "(recovered=\(f(recovered)) allMail=\(f(allMail)) trash=\(f(trash)))"
    }
}

/// "<abc@x>" / " abc@x " -> "abc@x"; nil when nothing is left.
func rescueNormalizeMessageID(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
    return trimmed.isEmpty ? nil : trimmed
}

/// May this Recovered row be moved at all? nil = proceed, otherwise the
/// reason it is left where it is. Fails closed on anything unclear. The dry
/// run and apply run the same check; apply also passes `expectedMessageID`
/// (what the caller saw in the dry run) so a ROWID that now belongs to a
/// different message — e.g. after an index rebuild — is never moved.
func rescuePrecheck(rowID: Int64, header: String?, expectedMessageID: String? = nil,
                    dateSent: Int64?, watermark: Int64?, state: RescueState) -> String? {
    guard let header = rescueNormalizeMessageID(header) else {
        return "no Message-ID in the index — cannot identify it in Mail.app"
    }
    if let expectedMessageID, rescueNormalizeMessageID(expectedMessageID) != header {
        return "id \(rowID) no longer refers to that message (its Message-ID is now <\(header)>), run the dry run again"
    }
    guard watermark != nil else {
        return "could not read the mail index watermark — cannot tell this run's copies from older ones"
    }
    guard let ds = dateSent, ds >= 0 else {
        return "no Date for this message in the index — cannot identify it reliably"
    }
    guard let recovered = state.recovered, let allMail = state.allMail, let trash = state.trash else {
        return "could not read Recovered/All Mail/Trash for this message (or a Date) \(state.summary)"
    }
    if !recovered.contains(rowID) {
        return "this row does not carry its own fingerprint in Recovered \(state.summary)"
    }
    if recovered.count > 1 {
        return "several Recovered copies share this fingerprint — not guessing which one \(state.summary)"
    }
    if !allMail.isEmpty {
        return "already in All Mail (ids \(allMail.map(String.init).joined(separator: ","))) — moving would duplicate it; leaving the Recovered copy alone"
    }
    if !trash.isEmpty {
        return "a copy is in Trash (ids \(trash.map(String.init).joined(separator: ","))) — Gmail state is ambiguous, check in Gmail"
    }
    return nil
}

/// The verdict, from the local end state. MOVED_LOCALLY only when the move call returned, the
/// fingerprint is gone from Recovered, and exactly one copy is in All Mail —
/// created by this run (ROWID > watermark) — with nothing in Trash.
func rescueVerdict(rowID: Int64, watermark: Int64, move: RescueMove,
                   state: RescueState) -> (status: RescueStatus, message: String) {
    guard let recovered = state.recovered, let allMail = state.allMail, let trash = state.trash else {
        return (.unknown, "could not read the index after the move — state unknown \(state.summary)")
    }
    let newAllMail = allMail.filter { $0 > watermark }

    switch move {
    case .indeterminate(let reason):
        return (.unknown, "\(reason) — state unknown even if the index looks fine; re-run the dry run to check \(state.summary)")
    case .notAttempted(let reason):
        if recovered == [rowID] && newAllMail.isEmpty {
            return (.stillInRecovered, "not moved: \(reason)")
        }
        return (.unknown, "not moved (\(reason)), but the index no longer looks as before \(state.summary)")
    case .moved:
        break
    }

    if !recovered.isEmpty {
        if newAllMail.isEmpty {
            return (.stillInRecovered, "Mail.app accepted the move but the message is still in Recovered \(state.summary)")
        }
        return (.unknown, "copies in both Recovered and All Mail — move half-done or index stale \(state.summary)")
    }
    if newAllMail.isEmpty {
        return (.unknown, "gone from Recovered but not (yet) in All Mail \(state.summary)")
    }
    if newAllMail.count != 1 || allMail.count != 1 {
        return (.unknown, "more than one All Mail copy \(state.summary)")
    }
    if !trash.isEmpty {
        return (.unknown, "in All Mail, but a Trash copy is also listed — Mail.app's index had not settled \(state.summary)")
    }
    return (.movedLocally, "the local index shows it in All Mail as [\(newAllMail[0])]; this does not mean the Gmail server has synced it")
}

/// Minimum gap between the two observations that confirm an end state.
let rescueStableGap: TimeInterval = 5

/// The verdict over a sequence of index observations taken after the move
/// (`at` = seconds since the move). The index passes through transient
/// states (All Mail + Trash on 2026-11-23), so after a completed move a
/// verdict only stands when the LAST TWO observations show the identical
/// state at least `rescueStableGap` apart; a state seen once, or one that
/// changed, is UNKNOWN. Moves that did not complete are judged on the last
/// observation alone (they are never MOVED_LOCALLY anyway).
func rescueStableVerdict(rowID: Int64, watermark: Int64, move: RescueMove,
                         observations: [(at: TimeInterval, state: RescueState)]) -> (status: RescueStatus, message: String) {
    guard let last = observations.last else {
        return (.unknown, "the index was never read after the move — state unknown")
    }
    let verdict = rescueVerdict(rowID: rowID, watermark: watermark, move: move, state: last.state)
    guard move == .moved, verdict.status != .unknown else { return verdict }
    guard observations.count >= 2 else {
        return (.unknown, "\(verdict.status.rawValue) state seen only once, not confirmed — state unknown \(last.state.summary)")
    }
    let prev = observations[observations.count - 2]
    guard prev.state == last.state, last.at - prev.at >= rescueStableGap else {
        return (.unknown, "index had not settled: \(prev.state.summary) then \(last.state.summary) — state unknown")
    }
    return verdict
}

/// JXA-side pick: of the Recovered copies with the right Message-ID, the one
/// to move must be the requested row and the only fingerprint match.
let rescuePickJS = """
function rescuePick(cands, ds, rowid) {
  const ids = fingerprintFilter(cands, ds);
  if (ids === null) return 'unknown';
  if (ids.length === 0) return 'none';
  if (ids.length > 1) return 'ambiguous';
  return ids[0] === rowid ? 'ok' : 'mismatch';
}
"""

/// One move, one message. Output: "MOVED", "SKIP\t<reason>" (Mail.move was
/// not called), or "ERRMOVE\t<error>" (Mail.move threw — may have acted).
func mailRescueScript(jobJSON json: String) -> String {
    return """
    function run() {
      const Mail = Application('Mail');
      const job = JSON.parse(\(jsLiteral(json)));
      \(gmailArchiveCriterionJS)
      \(rescuePickJS)
      let target = null, allmail = null;
      // "[Gmail]/All Mail": the mailbox name prefixed by its parent folders
      // (Gmail's "[Gmail]" folder has class 'container'), the same path the
      // Envelope Index URL carries.
      function fullPath(m) {
        const parts = [String(m.name())];
        let c = m;
        for (let d = 0; d < 8; d++) {
          let p, cls = '';
          try { p = c.container(); cls = String(p.properties().pcls); } catch (e) { break; }
          if (cls !== 'mailbox' && cls !== 'container') break;
          parts.unshift(String(p.name()));
          c = p;
        }
        return parts.join('/');
      }
      try {
        // Source and destination are pinned to the identities the index
        // check uses: the account by its id (== the UUID in the index's
        // mailbox URL), All Mail by full path, the quarantine by exact
        // name. Each must match exactly once, or nothing is moved.
        // The quarantine is an application-level mailbox; whose-clause
        // lookups work there where plain message iteration throws -1728.
        const boxes = Mail.mailboxes;
        const recs = [];
        for (let i = 0; i < boxes.length; i++) {
          let nm = null;
          try { nm = String(boxes[i].name()); } catch (e) {}
          if (nm === null) return 'SKIP\\tcould not read an application mailbox name';
          if (nm === job.recovered) recs.push(boxes[i]);
        }
        if (recs.length !== 1) return 'SKIP\\t' + recs.length + ' application mailboxes named "' + job.recovered + '" (need exactly 1)';
        const rec = recs[0];
        const accts = Mail.accounts.whose({id: job.accountId});
        if (accts.length !== 1) return 'SKIP\\t' + accts.length + ' accounts with id ' + job.accountId + ' (need exactly 1)';
        const acct = accts[0];
        const mbs = acct.mailboxes;
        const dests = [];
        for (let i = 0; i < mbs.length; i++) {
          let path = null;
          try { path = fullPath(mbs[i]); } catch (e) {}
          if (path === null) return 'SKIP\\tcould not read a mailbox path on account ' + job.accountId;
          if (path === job.allMailPath) dests.push(mbs[i]);
        }
        if (dests.length !== 1) return 'SKIP\\t' + dests.length + ' mailboxes at "' + job.allMailPath + '" on account ' + job.accountId + ' (need exactly 1)';
        allmail = dests[0];
        const found = rec.messages.whose({messageId: job.mid});
        const msgs = [], cands = [];
        for (let i = 0; i < found.length; i++) {
          let sec = null;
          try { sec = Math.floor(found[i].dateSent().getTime() / 1000); } catch (e) {}
          msgs.push(found[i]);
          cands.push({ id: Number(found[i].id()), ds: (sec === null || isNaN(sec)) ? null : sec });
        }
        const pick = rescuePick(cands, job.ds, job.id);
        if (pick !== 'ok') return 'SKIP\\tMail.app lookup in Recovered: ' + pick + ' (' + cands.length + ' copies with this Message-ID)';
        target = msgs[cands.findIndex(c => c.id === job.id)];
      } catch (e) {
        return 'SKIP\\tlookup failed: ' + e;
      }
      try {
        Mail.move(target, {to: allmail});
      } catch (e) {
        return 'ERRMOVE\\t' + e;
      }
      return 'MOVED';
    }
    """
}

/// Map the script's output line to a RescueMove.
func rescueMove(fromScriptOutput raw: String) -> RescueMove {
    let parts = raw.components(separatedBy: "\t")
    let detail = parts.dropFirst().joined(separator: "\t")
    switch parts.first {
    case "MOVED": return .moved
    case "SKIP": return .notAttempted(detail.isEmpty ? "Mail.app refused" : detail)
    case "ERRMOVE": return .indeterminate("Mail.move raised (\(detail))")
    default: return .indeterminate("unexpected reply from Mail.app: \(raw.prefix(200))")
    }
}

// MARK: Envelope Index lookups (read-only)

extension MailStore {
    struct RescueRow {
        let id: Int64
        let messageHash: Int64
        let header: String?
        let dateSent: Int64?
        let dateReceived: Int64
        let subject: String
        let sender: String
    }

    struct RescueBoxes {
        let recovered: Int64
        let allMail: Int64
        let trash: Int64
        let accountUUID: String     // == Mail.app account id
        let allMailPath: String     // "[Gmail]/All Mail" == Mail.app full mailbox path
    }

    /// "imap://UUID/%5BGmail%5D/All%20Mail" -> "[Gmail]/All Mail"
    static func mailboxPath(fromURL url: String) -> String? {
        guard let components = URL(string: url)?.pathComponents else { return nil }
        let parts = components.filter { $0 != "/" }.map { $0.removingPercentEncoding ?? $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    func rescueBoxes() throws -> RescueBoxes {
        let named = accounts.filter { $0.name == rescueAccountName }
        guard named.count == 1, let account = named.first else {
            throw ToolError("\(named.count) Mail accounts named \"\(rescueAccountName)\" (need exactly 1)")
        }
        var recovered: [Int64] = [], allMail: [Int64] = [], trash: [Int64] = []
        for row in try db.query("SELECT ROWID, url FROM mailboxes") {
            guard let rowID = row[0].intValue, let url = row[1].stringValue else { continue }
            if url.hasPrefix("local://") && Self.mailboxName(fromURL: url) == rescueRecoveredMailboxName {
                recovered.append(rowID)
            } else if url.hasPrefix("imap://"), URL(string: url)?.host == account.uuid {
                let path = Self.mailboxPath(fromURL: url)
                if path == rescueAllMailPath { allMail.append(rowID) }
                if path == rescueTrashPath { trash.append(rowID) }
            }
        }
        guard recovered.count == 1 else {
            throw ToolError("\(recovered.count) \"\(rescueRecoveredMailboxName)\" mailboxes in the mail index (need exactly 1) — nothing to rescue")
        }
        guard allMail.count == 1, trash.count == 1 else {
            throw ToolError("Need exactly one \(rescueAllMailPath) and one \(rescueTrashPath) for account \(rescueAccountName) in the mail index (found \(allMail.count) and \(trash.count))")
        }
        return RescueBoxes(recovered: recovered[0], allMail: allMail[0], trash: trash[0],
                           accountUUID: account.uuid, allMailPath: rescueAllMailPath)
    }
}

/// Rows in the Recovered mailbox `box`, newest first. `id` restricts to that
/// one row (apply never looks at any other); `since`/`subject` are dry-run
/// filters.
func rescueRecoveredRows(db: ReadOnlyDB, box: Int64, id: Int64? = nil, since: Int64? = nil,
                         subject: String? = nil, limit: Int) throws -> [MailStore.RescueRow] {
    var sql = """
    SELECT m.ROWID, m.message_id, g.message_id_header, m.date_sent, m.date_received,
           s.subject, COALESCE(a.address, ''), COALESCE(a.comment, '')
    FROM messages m
    JOIN subjects s ON s.ROWID = m.subject
    LEFT JOIN addresses a ON a.ROWID = m.sender
    LEFT JOIN message_global_data g ON g.message_id = m.message_id
    WHERE m.mailbox = ? AND m.deleted = 0
    """
    var bindings: [ReadOnlyDB.Value] = [.int(box)]
    if let id {
        sql += " AND m.ROWID = ?"
        bindings.append(.int(id))
    }
    if let since {
        sql += " AND m.date_received >= ?"
        bindings.append(.int(since))
    }
    if let subject, !subject.isEmpty {
        let escaped = subject
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        sql += " AND s.subject LIKE ? ESCAPE '\\'"
        bindings.append(.text("%\(escaped)%"))
    }
    sql += " ORDER BY m.date_received DESC LIMIT \(limit)"
    return try db.query(sql, bindings).map { row in
        let header = row[2].stringValue?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        return MailStore.RescueRow(
            id: row[0].intValue ?? 0,
            messageHash: row[1].intValue ?? 0,
            header: (header?.isEmpty ?? true) ? nil : header,
            dateSent: row[3].intValue,
            dateReceived: row[4].intValue ?? 0,
            subject: row[5].stringValue ?? "",
            sender: MailStore.formatAddress(address: row[6].stringValue ?? "", name: row[7].stringValue ?? "")
        )
    }
}

/// The one statement an observation runs: every copy with this message's
/// Message-ID hash in Recovered, All Mail and Trash at once. A single SQLite
/// statement reads one snapshot, so the three mailboxes can never be
/// stitched together from different moments of Mail.app's writes.
let rescueObserveSQL = """
SELECT ROWID, mailbox, date_sent, deleted FROM messages
WHERE message_id = ? AND mailbox IN (?, ?, ?)
"""

/// Split one snapshot's rows into the per-mailbox fingerprint matches.
/// Rows flagged deleted count for Recovered/Trash (still there, being
/// conservative) but not as being "in All Mail". A mailbox whose rows
/// include an unreadable Date fails closed (nil).
func rescuePartition(_ rows: [(id: Int64, mailbox: Int64, ds: Int64?, deleted: Bool)],
                     boxes: MailStore.RescueBoxes, dateSent: Int64?) -> RescueState {
    func pick(_ box: Int64, countDeleted: Bool) -> [Int64]? {
        let cands = rows.filter { $0.mailbox == box && (countDeleted || !$0.deleted) }
            .map { (id: $0.id, ds: $0.ds) }
        return mailFingerprintFilter(cands, ds: dateSent)
    }
    return RescueState(recovered: pick(boxes.recovered, countDeleted: true),
                       allMail: pick(boxes.allMail, countDeleted: false),
                       trash: pick(boxes.trash, countDeleted: true))
}

/// One observation = one query = one snapshot. All-nil when it fails.
func rescueObserve(db: ReadOnlyDB, boxes: MailStore.RescueBoxes,
                   messageHash: Int64, dateSent: Int64?) -> RescueState {
    guard let raw = try? db.query(rescueObserveSQL, [.int(messageHash), .int(boxes.recovered),
                                                     .int(boxes.allMail), .int(boxes.trash)]) else {
        return RescueState(recovered: nil, allMail: nil, trash: nil)
    }
    var rows: [(id: Int64, mailbox: Int64, ds: Int64?, deleted: Bool)] = []
    for row in raw {
        guard let id = row[0].intValue, let box = row[1].intValue else {
            return RescueState(recovered: nil, allMail: nil, trash: nil)
        }
        rows.append((id: id, mailbox: box, ds: row[2].intValue, deleted: (row[3].intValue ?? 0) != 0))
    }
    return rescuePartition(rows, boxes: boxes, dateSent: dateSent)
}

extension MailStore {
    func rescueState(_ row: RescueRow, boxes: RescueBoxes) -> RescueState {
        rescueObserve(db: db, boxes: boxes, messageHash: row.messageHash, dateSent: row.dateSent)
    }
}

// MARK: Tool

/// An integer tool argument, exactly as sent, or nil when absent. Anything
/// that is not an exact integer in Int64 range — 500.9, "500", true,
/// 1e30 — is an error, never truncated or coerced.
func strictInt64Argument(_ value: Any?, name: String) throws -> Int64? {
    guard let value, !(value is NSNull) else { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw ToolError("\"\(name)\" must be an integer, got \(value) — nothing was moved")
    }
    let exact = number.int64Value
    let roundTrips = NSDecimalNumber(decimal: number.decimalValue) == NSDecimalNumber(value: exact)
    guard roundTrips else {
        throw ToolError("\"\(name)\" must be an exact integer in range, got \(number) — nothing was moved")
    }
    return exact
}

/// What one call asks for. apply takes exactly one explicit id and none of
/// the dry-run filters; nonsense limits are refused rather than adjusted.
enum RescueRequest: Equatable {
    case list(id: Int64?, since: String?, subject: String?, limit: Int)
    case apply(id: Int64, messageID: String)
}

func rescueRequest(apply: Bool, id: Int64?, messageID: String? = nil, since: String?, subject: String?,
                   limit: Int?) throws -> RescueRequest {
    if apply {
        guard let id else {
            throw ToolError("mail_rescue_recovered apply: true needs an explicit \"id\" — it moves exactly one message. "
                + "Run it without apply first to list the ids and see which are eligible; nothing was moved")
        }
        guard let messageID = rescueNormalizeMessageID(messageID) else {
            throw ToolError("mail_rescue_recovered apply: true also needs \"message_id\" — the Message-ID the dry run printed for id \(id), "
                + "so a stale id can never move a different message; nothing was moved")
        }
        guard since == nil, subject == nil, limit == nil else {
            throw ToolError("mail_rescue_recovered apply: true takes only \"id\" and \"message_id\" — since/subject/limit are dry-run filters; nothing was moved")
        }
        return .apply(id: id, messageID: messageID)
    }
    let wanted = limit ?? 50
    guard wanted >= 1 else { throw ToolError("mail_rescue_recovered \"limit\" must be at least 1") }
    return .list(id: id, since: since, subject: subject, limit: wanted)
}

func mailRescueRecoveredText(apply: Bool, id: Int64?, messageID: String?, since: String?, subject: String?,
                             limit: Int?, settleSeconds: Double = 30) throws -> String {
    let request = try rescueRequest(apply: apply, id: id, messageID: messageID, since: since,
                                    subject: subject, limit: limit)
    let store = try MailStore()
    let boxes = try store.rescueBoxes()
    func label(_ row: MailStore.RescueRow) -> String {
        "\(formatEpoch(row.dateReceived))  \(row.subject.isEmpty ? "(no subject)" : row.subject)  — \(row.sender)"
    }

    switch request {
    case .list(let id, let since, let subject, let limit):
        let sinceEpoch = try since.map { try parseSinceDate($0) }
        let rows = try rescueRecoveredRows(db: store.db, box: boxes.recovered, id: id, since: sinceEpoch,
                                           subject: subject, limit: limit)
        var filters: [String] = []
        if let id { filters.append("id \(id)") }
        if let since { filters.append("since \(since)") }
        if let subject, !subject.isEmpty { filters.append("subject contains \"\(subject)\"") }
        let filterText = filters.isEmpty ? "" : " (" + filters.joined(separator: ", ") + ")"
        if rows.isEmpty { return "No messages in \(rescueRecoveredMailboxName)\(filterText)." }
        let watermark = try? store.maxMessageRowID()
        var lines = ["DRY RUN — nothing moved. \(rows.count) message(s) in \(rescueRecoveredMailboxName)\(filterText). "
                     + "To move one back to [Gmail]/All Mail, call again with apply: true, its id and its message_id:"]
        for row in rows {
            let state = store.rescueState(row, boxes: boxes)
            let plan = rescuePrecheck(rowID: row.id, header: row.header, dateSent: row.dateSent,
                                      watermark: watermark, state: state)
                .map { "not eligible: \($0)" } ?? "eligible"
            lines.append("  [\(row.id)] \(label(row))")
            lines.append("      message_id: \(row.header ?? "(none in the index)")")
            lines.append("      \(plan)")
        }
        return lines.joined(separator: "\n")

    case .apply(let id, let messageID):
        guard let row = try rescueRecoveredRows(db: store.db, box: boxes.recovered, id: id, limit: 1).first else {
            throw ToolError("No message [\(id)] in \(rescueRecoveredMailboxName) — nothing was moved; run the dry run again to list the ids")
        }
        let result = rescueApplyOne(row, expectedMessageID: messageID, store: store, boxes: boxes,
                                    settleSeconds: settleSeconds)
        return [
            "[\(row.id)] \(result.status.rawValue) — \(result.message)",
            "    \(label(row))",
            "MOVED_LOCALLY means the local index shows it in All Mail; this does not mean the Gmail server has synced it."
        ].joined(separator: "\n")
    }
}

/// Move one Recovered row to All Mail and judge the local end state.
private func rescueApplyOne(_ row: MailStore.RescueRow, expectedMessageID: String, store: MailStore,
                            boxes: MailStore.RescueBoxes, settleSeconds: Double) -> (status: RescueStatus, message: String) {
    let watermark = try? store.maxMessageRowID()
    let before = store.rescueState(row, boxes: boxes)
    if let refusal = rescuePrecheck(rowID: row.id, header: row.header, expectedMessageID: expectedMessageID,
                                    dateSent: row.dateSent, watermark: watermark, state: before) {
        return rescueVerdict(rowID: row.id, watermark: watermark ?? Int64.max,
                             move: .notAttempted(refusal), state: before)
    }
    guard let wm = watermark, let mid = row.header, let ds = row.dateSent else {
        return (.stillInRecovered, "not moved: no Message-ID in the index")
    }
    let job: [String: Any] = ["id": row.id, "mid": mid, "ds": ds,
                              "accountId": boxes.accountUUID, "allMailPath": boxes.allMailPath,
                              "recovered": rescueRecoveredMailboxName]
    let json = String(decoding: (try? JSONSerialization.data(withJSONObject: job)) ?? Data(), as: UTF8.self)

    let move: RescueMove
    do {
        move = rescueMove(fromScriptOutput: try runJXA(mailRescueScript(jobJSON: json), timeout: 60))
    } catch {
        move = .indeterminate("the Mail.app move call failed or timed out (\(error))")
    }

    // The index settles asynchronously (and passed through an All Mail +
    // Trash state on 2026-11-23). Observe every rescueStableGap seconds;
    // stop early only once MOVED_LOCALLY is confirmed by two identical
    // observations, otherwise judge whatever the 30s window leaves.
    let started = Date()
    var observations = [(at: TimeInterval(0), state: store.rescueState(row, boxes: boxes))]
    if move == .moved {
        while Date().timeIntervalSince(started) + rescueStableGap <= settleSeconds {
            if rescueStableVerdict(rowID: row.id, watermark: wm, move: move,
                                   observations: observations).status == .movedLocally { break }
            Thread.sleep(forTimeInterval: rescueStableGap)
            observations.append((at: Date().timeIntervalSince(started),
                                 state: store.rescueState(row, boxes: boxes)))
        }
    }
    return rescueStableVerdict(rowID: row.id, watermark: wm, move: move, observations: observations)
}
