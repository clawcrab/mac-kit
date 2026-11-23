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
//   • the default is a dry run that lists what is there and what would happen.
//
// Success is judged by the END STATE in the Envelope Index (read-only), never
// by the move call returning: after the move, the message's fingerprint
// (Message-ID + Date header, the same rule mail_archive uses) must be gone
// from Recovered and present exactly once in All Mail as a copy created by
// this run (ROWID above the watermark), with no copy in Trash. Observed
// 2026-11-23: right after a manual move the index briefly listed both an All
// Mail and a Trash copy (50747/50748) before settling on All Mail alone, so
// the end state is polled for a while; if it has not settled, the answer is
// UNKNOWN. A timed-out or failed move call is UNKNOWN whatever the index says.

let rescueAccountName = "Google"
let rescueRecoveredMailboxName = "Recovered Messages (\(rescueAccountName))"

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
    case ok = "OK"
    case stillInRecovered = "STILL_IN_RECOVERED"
    case unknown = "UNKNOWN"
}

/// What the Mail.app move call reported. Only `.moved` can lead to OK.
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

/// May this Recovered row be moved at all? nil = proceed, otherwise the
/// reason it is left where it is. Fails closed on anything unclear.
func rescuePrecheck(rowID: Int64, dateSent: Int64?, watermark: Int64?, state: RescueState) -> String? {
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

/// The verdict, from the end state. OK only when the move call returned, the
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
    return (.ok, "now in All Mail as [\(newAllMail[0])]")
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
      try {
        // The quarantine is an application-level mailbox; whose-clause
        // lookups work there where plain message iteration throws -1728.
        const boxes = Mail.mailboxes;
        let rec = null;
        for (let i = 0; i < boxes.length && rec === null; i++) {
          try { if (String(boxes[i].name()) === job.recovered) rec = boxes[i]; } catch (e) {}
        }
        if (rec === null) return 'SKIP\\tno mailbox named "' + job.recovered + '" in Mail.app';
        const accts = Mail.accounts;
        let acct = null;
        for (let i = 0; i < accts.length && acct === null; i++) {
          try { if (String(accts[i].name()) === job.account) acct = accts[i]; } catch (e) {}
        }
        if (acct === null) return 'SKIP\\tno account named "' + job.account + '"';
        const mbs = acct.mailboxes;
        for (let i = 0; i < mbs.length && allmail === null; i++) {
          try { if (String(mbs[i].name()) === 'All Mail') allmail = mbs[i]; } catch (e) {}
        }
        if (allmail === null) return 'SKIP\\tno All Mail mailbox on account "' + job.account + '"';
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
    }

    func rescueBoxes() throws -> RescueBoxes {
        guard let account = accounts.first(where: { $0.name == rescueAccountName }) else {
            throw ToolError("No Mail account named \"\(rescueAccountName)\"")
        }
        var recovered: Int64?, allMail: Int64?, trash: Int64?
        for row in try db.query("SELECT ROWID, url FROM mailboxes") {
            guard let rowID = row[0].intValue, let url = row[1].stringValue else { continue }
            let name = Self.mailboxName(fromURL: url)
            if url.hasPrefix("local://") && name == rescueRecoveredMailboxName {
                recovered = rowID
            } else if URL(string: url)?.host == account.uuid {
                if name == "All Mail" { allMail = rowID }
                if name == "Trash" { trash = rowID }
            }
        }
        guard let recovered else {
            throw ToolError("No \"\(rescueRecoveredMailboxName)\" mailbox in the mail index — nothing to rescue")
        }
        guard let allMail, let trash else {
            throw ToolError("Cannot find All Mail and Trash for account \(rescueAccountName) in the mail index")
        }
        return RescueBoxes(recovered: recovered, allMail: allMail, trash: trash)
    }

    func recoveredRows(box: Int64, since: Int64?, subject: String?, limit: Int) throws -> [RescueRow] {
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
        sql += " ORDER BY m.date_received DESC LIMIT \(max(1, limit))"
        return try db.query(sql, bindings).map { row in
            let header = row[2].stringValue?
                .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
            return RescueRow(
                id: row[0].intValue ?? 0,
                messageHash: row[1].intValue ?? 0,
                header: (header?.isEmpty ?? true) ? nil : header,
                dateSent: row[3].intValue,
                dateReceived: row[4].intValue ?? 0,
                subject: row[5].stringValue ?? "",
                sender: Self.formatAddress(address: row[6].stringValue ?? "", name: row[7].stringValue ?? "")
            )
        }
    }

    /// ROWIDs of the copies in `box` carrying the fingerprint (Message-ID +
    /// Date), or nil when the lookup fails or any Date is unreadable.
    /// Rows flagged deleted count for Recovered/Trash (still there, being
    /// conservative) but not as being "in All Mail".
    func fingerprintCopies(box: Int64, messageHash: Int64, dateSent: Int64?, countDeleted: Bool) -> [Int64]? {
        let sql = "SELECT ROWID, date_sent, deleted FROM messages WHERE message_id = ? AND mailbox = ?"
        guard let rows = try? db.query(sql, [.int(messageHash), .int(box)]) else { return nil }
        let cands = rows.compactMap { row -> (id: Int64, ds: Int64?)? in
            guard let id = row[0].intValue else { return nil }
            if !countDeleted && (row[2].intValue ?? 0) != 0 { return nil }
            return (id: id, ds: row[1].intValue)
        }
        return mailFingerprintFilter(cands, ds: dateSent)
    }

    func rescueState(_ row: RescueRow, boxes: RescueBoxes) -> RescueState {
        RescueState(
            recovered: fingerprintCopies(box: boxes.recovered, messageHash: row.messageHash, dateSent: row.dateSent, countDeleted: true),
            allMail: fingerprintCopies(box: boxes.allMail, messageHash: row.messageHash, dateSent: row.dateSent, countDeleted: false),
            trash: fingerprintCopies(box: boxes.trash, messageHash: row.messageHash, dateSent: row.dateSent, countDeleted: true)
        )
    }
}

// MARK: Tool

func mailRescueRecoveredText(since: String?, subject: String?, limit: Int, apply: Bool,
                             settleSeconds: Double = 30) throws -> String {
    let store = try MailStore()
    let boxes = try store.rescueBoxes()
    let sinceEpoch = try since.map { try parseSinceDate($0) }
    let rows = try store.recoveredRows(box: boxes.recovered, since: sinceEpoch, subject: subject, limit: limit)

    var filters: [String] = []
    if let since { filters.append("since \(since)") }
    if let subject, !subject.isEmpty { filters.append("subject contains \"\(subject)\"") }
    let filterText = filters.isEmpty ? "" : " (" + filters.joined(separator: ", ") + ")"

    if rows.isEmpty {
        return "No messages in \(rescueRecoveredMailboxName)\(filterText)."
    }
    func label(_ row: MailStore.RescueRow) -> String {
        "\(formatEpoch(row.dateReceived))  \(row.subject.isEmpty ? "(no subject)" : row.subject)  — \(row.sender)"
    }

    if !apply {
        let watermark = try? store.maxMessageRowID()
        var lines = ["DRY RUN — nothing moved. \(rows.count) message(s) in \(rescueRecoveredMailboxName)\(filterText); "
                     + "pass apply: true to move them back to [Gmail]/All Mail one at a time:"]
        for row in rows {
            let state = store.rescueState(row, boxes: boxes)
            let plan = rescuePrecheck(rowID: row.id, dateSent: row.dateSent, watermark: watermark, state: state)
                .map { "would SKIP: \($0)" } ?? "would move to All Mail"
            lines.append("  [\(row.id)] \(label(row))")
            lines.append("      \(plan)")
        }
        return lines.joined(separator: "\n")
    }

    var outcomes: [(row: MailStore.RescueRow, status: RescueStatus, message: String)] = []
    for row in rows {
        // Re-read everything right before acting on this row: earlier moves
        // in the same run bump the watermark and may have changed the index.
        let watermark = try? store.maxMessageRowID()
        let before = store.rescueState(row, boxes: boxes)
        if let refusal = rescuePrecheck(rowID: row.id, dateSent: row.dateSent, watermark: watermark, state: before) {
            let v = rescueVerdict(rowID: row.id, watermark: watermark ?? Int64.max,
                                  move: .notAttempted(refusal), state: before)
            outcomes.append((row, v.status, v.message))
            continue
        }
        guard let wm = watermark, let mid = row.header, let ds = row.dateSent else {
            outcomes.append((row, .stillInRecovered, "not moved: no Message-ID in the index"))
            continue
        }
        let job: [String: Any] = ["id": row.id, "mid": mid, "ds": ds,
                                  "account": rescueAccountName, "recovered": rescueRecoveredMailboxName]
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: job)) ?? Data(), as: UTF8.self)

        let move: RescueMove
        do {
            move = rescueMove(fromScriptOutput: try runJXA(mailRescueScript(jobJSON: json), timeout: 60))
        } catch {
            move = .indeterminate("the Mail.app move call failed or timed out (\(error))")
        }

        var verdict = rescueVerdict(rowID: row.id, watermark: wm, move: move, state: store.rescueState(row, boxes: boxes))
        if move == .moved {
            // The index settles asynchronously (and passed through an
            // All Mail + Trash state on 2026-11-23): poll for the end state.
            let deadline = Date().addingTimeInterval(settleSeconds)
            while verdict.status != .ok && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                verdict = rescueVerdict(rowID: row.id, watermark: wm, move: move,
                                        state: store.rescueState(row, boxes: boxes))
            }
        }
        outcomes.append((row, verdict.status, verdict.message))
    }

    let ok = outcomes.filter { $0.status == .ok }.count
    let still = outcomes.filter { $0.status == .stillInRecovered }.count
    let unknown = outcomes.filter { $0.status == .unknown }.count
    var lines = ["Rescued \(ok) of \(outcomes.count) message(s) from \(rescueRecoveredMailboxName) to All Mail"
                 + "\(filterText): \(still) still in Recovered, \(unknown) unknown. Only OK is success:"]
    for outcome in outcomes {
        lines.append("  [\(outcome.row.id)] \(outcome.status.rawValue) — \(outcome.message)")
        lines.append("      \(label(outcome.row))")
    }
    return lines.joined(separator: "\n")
}
