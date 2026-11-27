import Foundation

// MARK: mail_archive, Gmail path — observe in the Envelope Index, act by id
//
// Archiving a Gmail message means dropping its INBOX label: delete the INBOX
// copy (Mail.app routes it to Trash) and refile the Trash copy into All Mail
// (see the mail_archive notes in MailTools.swift for why a plain move is a
// server-side no-op).
//
// "Where is the message now?" used to be answered inside the JXA script with
// `mailbox.messages.whose({messageId: …})`. On All Mail that is a linear scan
// in Mail.app: 42 seconds for ~42,600 messages (measured 2026-11-26), against
// a 50s per-message budget, so every archive timed out — and a script killed
// between the delete and the refile leaves mail in Trash or quarantined in
// "Recovered Messages". The same question is an indexed lookup in the
// Envelope Index, so:
//
//   • every observation is ONE read-only SQL statement over the message's
//     copies (messages.message_id is the Message-ID hash), split per mailbox
//     and matched by fingerprint (Message-ID + Date header). For Gmail,
//     "in INBOX" is a row in the `labels` table on the All Mail row;
//   • Mail.app is only asked to act, in two short calls: delete the caller's
//     exact row from INBOX, then move the new Trash row to All Mail. Each
//     call finds its message with `whose({id: …})` in INBOX / Trash — small
//     mailboxes, and (unlike byId) a lookup that fails when the message is
//     not in that mailbox — and checks its Message-ID and Date before acting.
//     Nothing ever searches All Mail through Mail.app.
//
// The verdict is unchanged in meaning: OK only when this run's delete and
// refile both returned, the index shows exactly one All Mail copy created by
// the refile (ROWID above the watermark), and nothing in INBOX, Trash or a
// new Recovered copy. "Not (yet) visible anywhere" is never success.
//
// Mail.app applies a move to its local index first and to the server
// afterwards, so a local row proves nothing by itself. Observed 2026-11-27:
// a refile issued as soon as the Trash row appeared looked archived in the
// index for ~15s (new All Mail row, no INBOX label, empty Trash), then
// Mail.app gave up on the server move and dropped the copy into "Recovered
// Messages". A row the server has acknowledged carries its IMAP UID in
// messages.remote_id (every settled All Mail row has one; quarantined rows
// never do). So both steps wait for that acknowledgement:
//   • the Trash copy is only refiled once it has a UID (the server finished
//     the INBOX -> Trash move; moving it earlier is what failed above);
//   • "archived" only counts once the new All Mail copy has a UID, and that
//     state has held unchanged for `stableGap` seconds.

let gmailInboxPath = "INBOX"
let gmailAllMailName = "All Mail"
let gmailTrashName = "Trash"

/// The index ROWIDs and Mail.app identities of one Gmail account's mailboxes.
struct GmailArchiveBoxes: Equatable {
    let inbox: Int64
    let allMail: Int64
    let trash: Int64
    /// "Recovered Messages (<account>)" — a local mailbox Mail.app only
    /// creates once it quarantines something, possibly in the middle of a
    /// run, so it is recognised by name in every observation rather than
    /// resolved to a ROWID up front.
    let recoveredName: String
    let accountUUID: String     // == Mail.app account id
    let inboxPath: String       // full paths, == Mail.app mailbox paths
    let allMailPath: String
    let trashPath: String
}

/// Pick the account's INBOX, All Mail and Trash out of the index's mailbox
/// list. Each must exist exactly once, or the job is refused.
func gmailArchivePickBoxes(mailboxes: [(rowID: Int64, url: String)], accountUUID: String,
                            accountName: String) throws -> GmailArchiveBoxes {
    var inbox: [(Int64, String)] = [], allMail: [(Int64, String)] = [], trash: [(Int64, String)] = []
    for box in mailboxes {
        guard box.url.hasPrefix("imap://"), URL(string: box.url)?.host == accountUUID,
              let path = MailStore.mailboxPath(fromURL: box.url) else { continue }
        let name = MailStore.mailboxName(fromURL: box.url)
        if path == gmailInboxPath { inbox.append((box.rowID, path)) }
        if name == gmailAllMailName { allMail.append((box.rowID, path)) }
        if name == gmailTrashName { trash.append((box.rowID, path)) }
    }
    guard inbox.count == 1, allMail.count == 1, trash.count == 1 else {
        throw ToolError("need exactly one INBOX, All Mail and Trash for account \(accountName) in the mail index "
            + "(found \(inbox.count), \(allMail.count) and \(trash.count)) — nothing was changed")
    }
    return GmailArchiveBoxes(inbox: inbox[0].0, allMail: allMail[0].0, trash: trash[0].0,
                             recoveredName: "Recovered Messages (\(accountName))",
                             accountUUID: accountUUID, inboxPath: inbox[0].1, allMailPath: allMail[0].1,
                             trashPath: trash[0].1)
}

extension MailStore {
    func gmailArchiveBoxes(account: MailAccount) throws -> GmailArchiveBoxes {
        let rows = try db.query("SELECT ROWID, url FROM mailboxes").compactMap { row -> (rowID: Int64, url: String)? in
            guard let rowID = row[0].intValue, let url = row[1].stringValue else { return nil }
            return (rowID: rowID, url: url)
        }
        return try gmailArchivePickBoxes(mailboxes: rows, accountUUID: account.uuid, accountName: account.name)
    }

    /// messages.message_id (the Message-ID hash) of one row.
    func messageHash(id: Int64) throws -> Int64? {
        try db.query("SELECT message_id FROM messages WHERE ROWID = ? LIMIT 1", [.int(id)])
            .first?.first?.intValue
    }
}

/// Fingerprint-matching ROWIDs per place, read from the Envelope Index.
/// nil means that lookup failed (or a Date was unreadable).
struct GmailArchiveState: Equatable {
    var inbox: [Int64]?
    var allMail: [Int64]?
    var trash: [Int64]?
    var recovered: [Int64]?
    /// The All Mail / Trash matches the server has acknowledged (the row has
    /// an IMAP UID in remote_id). A row without one exists only locally so far.
    var synced: [Int64]? = []

    static let unreadable = GmailArchiveState(inbox: nil, allMail: nil, trash: nil, recovered: nil, synced: nil)

    var summary: String {
        func f(_ ids: [Int64]?) -> String {
            guard let ids else { return "?" }
            return ids.isEmpty ? "0" : "\(ids.count) [\(ids.map(String.init).joined(separator: ","))]"
        }
        return "(inbox=\(f(inbox)) allMail=\(f(allMail)) trash=\(f(trash)) recovered=\(f(recovered)) server-confirmed=\(f(synced)))"
    }
}

/// The one statement an observation runs: every copy of the message (same
/// Message-ID hash) in any mailbox, with whether it carries the INBOX label
/// and its mailbox's URL (which is how the quarantine is recognised).
/// One statement reads one snapshot, so the places can never be stitched
/// together from different moments of Mail.app's writes.
let gmailArchiveObserveSQL = """
SELECT m.ROWID, m.mailbox, m.date_sent, m.deleted, m.remote_id,
       EXISTS (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id = ?),
       (SELECT b.url FROM mailboxes b WHERE b.ROWID = m.mailbox)
FROM messages m
WHERE m.message_id = ?
"""

struct GmailArchiveRow: Equatable {
    let id: Int64
    let mailbox: Int64
    let ds: Int64?
    let deleted: Bool
    /// The server has acknowledged this row (remote_id, its IMAP UID, is set).
    let synced: Bool
    let inboxLabel: Bool
    /// The row sits in the account's "Recovered Messages" quarantine.
    let recovered: Bool
}

/// Is this mailbox URL the local quarantine named `name`?
func gmailArchiveIsRecovered(mailboxURL url: String?, name: String) -> Bool {
    guard let url, url.hasPrefix("local://") else { return false }
    return MailStore.mailboxName(fromURL: url) == name
}

/// Split one snapshot's rows into the per-place fingerprint matches. A row
/// counts as "in INBOX" when it carries the INBOX label or sits in the INBOX
/// mailbox itself. Rows flagged deleted still count for INBOX, Trash and
/// Recovered (still there, being conservative) but never as "in All Mail".
/// A place whose rows include an unreadable Date fails closed (nil).
func gmailArchivePartition(_ rows: [GmailArchiveRow], boxes: GmailArchiveBoxes, dateSent: Int64?) -> GmailArchiveState {
    func pick(_ keep: (GmailArchiveRow) -> Bool) -> [Int64]? {
        mailFingerprintFilter(rows.filter(keep).map { (id: $0.id, ds: $0.ds) }, ds: dateSent)
    }
    return GmailArchiveState(
        inbox: pick { $0.inboxLabel || $0.mailbox == boxes.inbox },
        allMail: pick { $0.mailbox == boxes.allMail && !$0.deleted },
        trash: pick { $0.mailbox == boxes.trash },
        recovered: pick { $0.recovered },
        synced: pick { $0.synced && !$0.recovered && (($0.mailbox == boxes.allMail && !$0.deleted) || $0.mailbox == boxes.trash) })
}

/// One observation = one query = one snapshot. Unreadable when it fails.
func gmailArchiveObserve(db: ReadOnlyDB, boxes: GmailArchiveBoxes, messageHash: Int64, dateSent: Int64?) -> GmailArchiveState {
    guard let raw = try? db.query(gmailArchiveObserveSQL, [.int(boxes.inbox), .int(messageHash)]) else {
        return .unreadable
    }
    var rows: [GmailArchiveRow] = []
    for row in raw {
        guard let id = row[0].intValue, let box = row[1].intValue else { return .unreadable }
        rows.append(GmailArchiveRow(id: id, mailbox: box, ds: row[2].intValue,
                                    deleted: (row[3].intValue ?? 0) != 0, synced: row[4].intValue != nil,
                                    inboxLabel: (row[5].intValue ?? 0) != 0,
                                    recovered: gmailArchiveIsRecovered(mailboxURL: row[6].stringValue,
                                                                       name: boxes.recoveredName)))
    }
    return gmailArchivePartition(rows, boxes: boxes, dateSent: dateSent)
}

// MARK: Criterion (target state reached, not symptom gone)

enum GmailArchivePrecheck: Equatable {
    case proceed, notInInbox, ambiguous, unknown
}

/// May we delete at all? Only the caller's exact row, only when it is in
/// INBOX, is the sole INBOX copy with its fingerprint, and Trash holds no copy
/// (a Trash copy next to an INBOX one means the local index is already
/// stale, and the archive could never end cleanly).
func gmailArchivePrecheck(id: Int64, state: GmailArchiveState) -> GmailArchivePrecheck {
    guard let inbox = state.inbox, let trash = state.trash, state.allMail != nil, state.recovered != nil,
          state.synced != nil else {
        return .unknown
    }
    if !inbox.contains(id) { return .notInInbox }
    if inbox.count > 1 || !trash.isEmpty { return .ambiguous }
    return .proceed
}

/// Copies created after the watermark was read. ROWIDs only grow, so
/// anything at or below it predates this run and is never touched.
func gmailArchiveNewCopies(_ ids: [Int64]?, watermark: Int64) -> [Int64]? {
    ids.map { $0.filter { $0 > watermark } }
}

enum GmailArchiveVerdict: String, Equatable {
    case archived, inbox, trash, recovered, missing, ambiguous, unknown
}

/// Has the message reached the target state — in All Mail, not in INBOX, not
/// in Trash? A copy in both All Mail and Trash is "ambiguous": Gmail cannot
/// hold one message in both, so the local index is stale and neither claim
/// holds. Several matches in one place is also "ambiguous". A failed lookup
/// is "unknown". In none of INBOX / All Mail / Trash is "recovered" when the
/// quarantine has it and "missing" otherwise. Only "archived" can be success.
func gmailArchiveVerdict(_ state: GmailArchiveState) -> GmailArchiveVerdict {
    guard let inbox = state.inbox, let allMail = state.allMail, let trash = state.trash,
          let recovered = state.recovered, state.synced != nil else { return .unknown }
    if inbox.count > 1 || allMail.count > 1 || trash.count > 1 { return .ambiguous }
    if !inbox.isEmpty { return .inbox }
    if !allMail.isEmpty && !trash.isEmpty { return .ambiguous }
    if !allMail.isEmpty { return .archived }
    if !trash.isEmpty { return .trash }
    return recovered.isEmpty ? .missing : .recovered
}

/// What a Mail.app call reported. Only `.done` can lead to OK.
enum GmailArchiveStep: Equatable {
    case done                      // the delete / move returned normally
    case notAttempted(String)      // refused before acting — nothing was changed by this call
    case indeterminate(String)     // threw or timed out — it may or may not have acted
}

/// Success needs this run's delete AND refile to have returned, and the
/// result to be a single All Mail copy created by that refile which the
/// server has acknowledged (a local-only row is "unknown": Mail.app may yet
/// fail the server move and quarantine it). In Gmail an
/// INBOX message is always in All Mail too, so "INBOX gone + All Mail
/// present" alone can be a delete that has not reached Trash yet: that is
/// "unknown", never "archived". A copy this run left in Recovered Messages
/// is never success either.
func gmailArchiveOutcome(deleted: GmailArchiveStep, refiled: GmailArchiveStep?, watermark: Int64,
                         state: GmailArchiveState) -> GmailArchiveVerdict {
    guard deleted == .done, refiled == .done else { return .unknown }
    let verdict = gmailArchiveVerdict(state)
    guard verdict == .archived else { return verdict }
    guard let fresh = gmailArchiveNewCopies(state.allMail, watermark: watermark), fresh.count == 1,
          let synced = state.synced, synced.contains(fresh[0]) else { return .unknown }
    guard let strays = gmailArchiveNewCopies(state.recovered, watermark: watermark) else { return .unknown }
    return strays.isEmpty ? .archived : .recovered
}

/// The outcome over the observations taken after the refile (`at` = seconds
/// since it returned). "archived" only stands once the latest state has been
/// observed unchanged for at least `stableGap` seconds; seen for less, it is
/// "unknown". Every other outcome is judged on the latest observation.
func gmailArchiveStableOutcome(deleted: GmailArchiveStep, refiled: GmailArchiveStep?, watermark: Int64,
                               observations: [(at: TimeInterval, state: GmailArchiveState)],
                               stableGap: TimeInterval) -> GmailArchiveVerdict {
    guard let last = observations.last else { return .unknown }
    let outcome = gmailArchiveOutcome(deleted: deleted, refiled: refiled, watermark: watermark, state: last.state)
    guard outcome == .archived else { return outcome }
    var since = last.at
    for observation in observations.reversed() {
        guard observation.state == last.state else { break }
        since = observation.at
    }
    return last.at - since >= stableGap ? .archived : .unknown
}

// MARK: Mail.app calls (act only; never observe)

/// One action on one message. `op` is "delete" (the INBOX row) or "refile"
/// (the Trash row, moved to All Mail). Output: "DONE", "SKIP\t<reason>"
/// (nothing was called) or "ERR\t<error>" (the call threw — may have acted).
///
/// The account is pinned by id and each mailbox by its full path — the same
/// identities the index check uses — and each must match exactly once. The
/// message is found by `whose({id: …})` in the source mailbox (INBOX or
/// Trash; Mail.app ids are Envelope Index ROWIDs) and must carry the
/// expected Message-ID and Date, or nothing is done. Before a delete, Trash
/// (`checkPath`) must hold no copy with this Message-ID as far as Mail.app
/// itself can see — a copy the index has not caught up with yet could
/// otherwise be mistaken for this delete's arrival. That is the one
/// Message-ID search left, and it only ever runs on Trash.
func gmailArchiveActionScript(jobJSON json: String) -> String {
    return """
    function run() {
      const Mail = Application('Mail');
      const job = JSON.parse(\(jsLiteral(json)));
      if (job.op !== 'delete' && job.op !== 'refile') return 'SKIP\\tunknown op';
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
      let target = null, dest = null;
      try {
        const accts = Mail.accounts.whose({id: job.accountId});
        if (accts.length !== 1) return 'SKIP\\t' + accts.length + ' accounts with id ' + job.accountId + ' (need exactly 1)';
        const mbs = accts[0].mailboxes;
        const srcs = [], dests = [], checks = [];
        for (let i = 0; i < mbs.length; i++) {
          let path = null;
          try { path = fullPath(mbs[i]); } catch (e) {}
          if (path === null) return 'SKIP\\tcould not read a mailbox path on account ' + job.accountId;
          if (path === job.srcPath) srcs.push(mbs[i]);
          if (job.op === 'refile' && path === job.destPath) dests.push(mbs[i]);
          if (job.op === 'delete' && path === job.checkPath) checks.push(mbs[i]);
        }
        if (srcs.length !== 1) return 'SKIP\\t' + srcs.length + ' mailboxes at "' + job.srcPath + '" (need exactly 1)';
        if (job.op === 'refile') {
          if (dests.length !== 1) return 'SKIP\\t' + dests.length + ' mailboxes at "' + job.destPath + '" (need exactly 1)';
          dest = dests[0];
        }
        const found = srcs[0].messages.whose({id: job.id});
        if (found.length !== 1) return 'SKIP\\tMail.app sees ' + found.length + ' messages with id ' + job.id + ' in ' + job.srcPath;
        target = found[0];
        if (Number(target.id()) !== job.id) return 'SKIP\\tMail.app returned a different message for id ' + job.id;
        if (String(target.messageId()) !== job.mid) return 'SKIP\\tmessage ' + job.id + ' does not carry the expected Message-ID in Mail.app';
        const sec = Math.floor(target.dateSent().getTime() / 1000);
        if (isNaN(sec) || Math.abs(sec - job.ds) > 1) return 'SKIP\\tmessage ' + job.id + ' does not carry the expected Date in Mail.app';
        if (job.op === 'delete') {
          if (checks.length !== 1) return 'SKIP\\t' + checks.length + ' mailboxes at "' + job.checkPath + '" (need exactly 1)';
          const stale = checks[0].messages.whose({messageId: job.mid}).length;
          if (stale !== 0) return 'SKIP\\tMail.app already shows ' + stale + ' message(s) with this Message-ID in ' + job.checkPath;
        }
      } catch (e) {
        return 'SKIP\\tlookup failed: ' + e;
      }
      try {
        if (job.op === 'delete') Mail.delete(target);
        else Mail.move(target, {to: dest});
      } catch (e) {
        return 'ERR\\t' + e;
      }
      return 'DONE';
    }
    """
}

/// Map the action script's output line to a step.
func gmailArchiveStep(fromScriptOutput raw: String) -> GmailArchiveStep {
    let parts = raw.components(separatedBy: "\t")
    let detail = parts.dropFirst().joined(separator: "\t")
    switch parts.first {
    case "DONE" where parts.count == 1: return .done
    case "SKIP": return .notAttempted(detail.isEmpty ? "Mail.app refused" : detail)
    case "ERR": return .indeterminate("Mail.app raised (\(detail))")
    default: return .indeterminate("unexpected reply from Mail.app: \(raw.prefix(200))")
    }
}

// MARK: The run

/// Waiting budgets, in seconds. A normal archive takes a few seconds; the
/// windows only matter when Mail.app or its index is slow.
struct GmailArchiveTiming {
    var poll: TimeInterval = 0.5
    /// How long to wait for the deleted message to show up in Trash with the
    /// server's acknowledgement.
    var arrivalWindow: TimeInterval = 45
    /// How long to wait, after the refile, for the index to show a
    /// server-acknowledged "archived".
    var settleWindow: TimeInterval = 45
    /// How long the archived state must hold unchanged before it counts.
    var stableGap: TimeInterval = 2
    /// How long to keep retrying a refile Mail.app refused without acting
    /// (its scripting model can lag the index).
    var refileWindow: TimeInterval = 20
}

/// Everything the run touches, injectable so self-test can drive it.
struct GmailArchiveEnv {
    var watermark: () -> Int64?
    var observe: () -> GmailArchiveState
    var delete: () -> GmailArchiveStep
    var refile: (_ trashID: Int64) -> GmailArchiveStep
    var now: () -> TimeInterval
    var sleep: (TimeInterval) -> Void
}

struct GmailArchiveResult: Equatable {
    let status: MailArchiveStatus
    let message: String
    /// The message was (or may have been) deleted from INBOX and the run did
    /// not end in a confirmed archive: the caller must not delete anything
    /// else. Whatever went wrong — Mail.app stuck, the server not answering —
    /// would most likely strand the next message in Trash too.
    var stopBatch = false
}

/// The message for an end state that is not "archived".
func gmailArchiveFailure(_ verdict: GmailArchiveVerdict, state: GmailArchiveState, prefix: String) -> (MailArchiveStatus, String) {
    let s = state.summary
    switch verdict {
    case .archived, .unknown:
        return (.unknown, prefix + "the local mail index does not (yet) show a server-confirmed archive — state unknown, check in Gmail before retrying \(s)")
    case .ambiguous:
        return (.ambiguous, prefix + "the local mail index lists more than one copy (All Mail and Trash, or several in one mailbox) \(s); it may be stale; check in Gmail")
    case .inbox:
        return (.error, prefix + "still in INBOX \(s)")
    case .trash:
        return (.error, prefix + "left in Trash, not refiled to All Mail — recover from Gmail Trash \(s)")
    case .recovered:
        return (.error, prefix + "Mail.app put a copy in \"Recovered Messages\" — not archived; see mail_rescue_recovered \(s)")
    case .missing:
        return (.error, prefix + "not in INBOX, All Mail, Trash or Recovered Messages — state unknown, check in Gmail \(s)")
    }
}

/// Archive one Gmail message: precheck in the index, delete the INBOX row,
/// wait for this run's Trash copy, refile it, then judge the settled index.
func gmailArchiveRun(id: Int64, env: GmailArchiveEnv, timing: GmailArchiveTiming = GmailArchiveTiming()) -> GmailArchiveResult {
    // Read before anything runs: every copy Mail.app creates from here on has
    // a larger ROWID, which is how this run's Trash arrival and All Mail
    // refile are told from copies that were already there.
    guard let watermark = env.watermark() else {
        return GmailArchiveResult(status: .unknown, message: "could not read the mail index watermark — cannot tell this run's copies from older ones, not touching it")
    }
    let before = env.observe()
    switch gmailArchivePrecheck(id: id, state: before) {
    case .proceed:
        break
    case .unknown:
        return GmailArchiveResult(status: .unknown, message: "could not read the mail index for this message (or a Date) — nothing was changed \(before.summary)")
    case .notInInbox:
        return GmailArchiveResult(status: .error, message: "the requested message is not in INBOX — nothing was changed \(before.summary)")
    case .ambiguous:
        return GmailArchiveResult(status: .ambiguous, message: "before archiving: another INBOX copy with the same fingerprint, or a Trash copy already present \(before.summary); the local mail index may be stale; nothing was changed, check in Gmail")
    }

    let deleted = env.delete()                 // drops the INBOX label, lands in Trash
    if case .notAttempted(let reason) = deleted {
        let after = env.observe()
        if after == before {
            return GmailArchiveResult(status: .error, message: "not archived: \(reason) — nothing was changed")
        }
        return GmailArchiveResult(status: .unknown, message: "not archived (\(reason)), but the mail index no longer looks as before \(after.summary) — check in Gmail", stopBatch: true)
    }

    // The delete settles asynchronously: the Trash copy takes a moment to
    // appear in the index, and longer to be acknowledged by the server. Only
    // a copy created after the watermark counts as this delete's arrival, and
    // it is only refiled once the server has acknowledged it — moving a
    // local-only Trash row is how mail ends up in Recovered Messages. Even
    // when the delete call itself failed or timed out the arrival is still watched for, because a message left in
    // Trash is the worse outcome — but such a run can no longer end in OK.
    var trashID: Int64?
    var state = before
    let deleteReturned = env.now()
    while true {
        state = env.observe()
        if let fresh = gmailArchiveNewCopies(state.trash, watermark: watermark) {
            if fresh.count == 1, state.synced?.contains(fresh[0]) == true { trashID = fresh[0]; break }
            if fresh.count > 1 {
                return GmailArchiveResult(status: .ambiguous, message: "after deleting from INBOX: several new Trash copies carry this fingerprint — nothing was refiled, check in Gmail \(state.summary)", stopBatch: true)
            }
        }
        if env.now() - deleteReturned >= timing.arrivalWindow { break }
        env.sleep(timing.poll)
    }
    guard let trashID else {
        if case .indeterminate(let reason) = deleted {
            return GmailArchiveResult(status: .unknown, message: "the delete from INBOX failed or timed out (\(reason)) and no new Trash copy appeared within \(Int(timing.arrivalWindow))s — state unknown, check in Gmail before retrying \(state.summary)", stopBatch: true)
        }
        if gmailArchiveNewCopies(state.trash, watermark: watermark)?.count == 1 {
            return GmailArchiveResult(status: .unknown, message: "deleted from INBOX, but the server did not confirm the new Trash copy within \(Int(timing.arrivalWindow))s (offline or slow?), so it was not refiled — not archived; locally it is in Trash, on Gmail it may still be in INBOX or already in Trash, check in Gmail \(state.summary)", stopBatch: true)
        }
        return GmailArchiveResult(status: .unknown, message: "deleted from INBOX, but no new Trash copy was seen within \(Int(timing.arrivalWindow))s, so nothing was refiled — state unknown, check in Gmail before retrying \(state.summary)", stopBatch: true)
    }

    // Refile: drops the Trash label -> archived in All Mail. A refusal
    // changed nothing (typically Mail.app's scripting model does not show
    // the Trash row yet), so it is retried for refileWindow.
    let refileStarted = env.now()
    var refiled = env.refile(trashID)
    while case .notAttempted = refiled, env.now() - refileStarted < timing.refileWindow {
        env.sleep(1)
        refiled = env.refile(trashID)
    }

    // The refile settles asynchronously too, and the index passes through
    // transient states (All Mail and Trash both listed). Poll until
    // "archived" has held for stableGap, or the window runs out; a state
    // first seen archived at the very end of the window gets stableGap more
    // to confirm.
    let refileReturned = env.now()
    var observations: [(at: TimeInterval, state: GmailArchiveState)] = []
    func outcome() -> GmailArchiveVerdict {
        gmailArchiveStableOutcome(deleted: deleted, refiled: refiled, watermark: watermark,
                                  observations: observations, stableGap: timing.stableGap)
    }
    while true {
        let at = env.now() - refileReturned
        observations.append((at: at, state: env.observe()))
        if outcome() == .archived { break }
        let seenArchived = gmailArchiveOutcome(deleted: deleted, refiled: refiled, watermark: watermark,
                                               state: observations[observations.count - 1].state) == .archived
        // A refused refile changed nothing: one look is enough.
        var limit = seenArchived ? timing.settleWindow + timing.stableGap + timing.poll : timing.settleWindow
        if case .notAttempted = refiled { limit = 0 }
        if at >= limit { break }
        env.sleep(timing.poll)
    }
    let final = observations[observations.count - 1].state
    let verdict = outcome()
    if verdict == .archived {
        return GmailArchiveResult(status: .ok, message: "archived (INBOX label removed; refiled into All Mail)")
    }

    var prefix = "after archive: "
    if case .indeterminate(let reason) = deleted {
        prefix = "the delete from INBOX failed or timed out (\(reason)); "
    } else if case .indeterminate(let reason) = refiled {
        prefix = "the refile from Trash to All Mail failed or timed out (\(reason)); "
    } else if case .notAttempted(let reason) = refiled {
        prefix = "deleted from INBOX but the refile from Trash was refused (\(reason)); "
    }
    if deleted != .done || refiled != .done {
        // An incomplete run is never judged better than what the index shows,
        // and never as success.
        let shown = gmailArchiveVerdict(final)
        if shown == .archived || shown == .unknown {
            return GmailArchiveResult(status: .unknown, message: prefix + "state unknown even if the mail index looks fine, check in Gmail before retrying \(final.summary)", stopBatch: true)
        }
        let (status, message) = gmailArchiveFailure(shown, state: final, prefix: prefix)
        return GmailArchiveResult(status: status, message: message, stopBatch: true)
    }
    let (status, message) = gmailArchiveFailure(verdict, state: final, prefix: prefix)
    return GmailArchiveResult(status: status, message: message, stopBatch: true)
}

/// The real environment for one message: index reads through `store`,
/// actions through osascript.
func gmailArchiveLiveEnv(id: Int64, messageID: String, messageHash: Int64, dateSent: Int64,
                         store: MailStore, boxes: GmailArchiveBoxes, callTimeout: TimeInterval = 30) -> GmailArchiveEnv {
    func act(_ op: String, id target: Int64, src: String, dest: String? = nil, check: String? = nil) -> GmailArchiveStep {
        var job: [String: Any] = ["op": op, "id": target, "mid": messageID, "ds": dateSent,
                                  "accountId": boxes.accountUUID, "srcPath": src]
        if let dest { job["destPath"] = dest }
        if let check { job["checkPath"] = check }
        guard let data = try? JSONSerialization.data(withJSONObject: job) else {
            return .notAttempted("could not encode the request")
        }
        do {
            return gmailArchiveStep(fromScriptOutput: try runJXA(
                gmailArchiveActionScript(jobJSON: String(decoding: data, as: UTF8.self)), timeout: callTimeout))
        } catch {
            return .indeterminate("the Mail.app call failed or timed out (\(error))")
        }
    }
    return GmailArchiveEnv(
        watermark: { (try? store.maxMessageRowID()) ?? nil },
        observe: { gmailArchiveObserve(db: store.db, boxes: boxes, messageHash: messageHash, dateSent: dateSent) },
        delete: { act("delete", id: id, src: boxes.inboxPath, check: boxes.trashPath) },
        refile: { trashID in act("refile", id: trashID, src: boxes.trashPath, dest: boxes.allMailPath) },
        now: { Date().timeIntervalSinceReferenceDate },
        sleep: { Thread.sleep(forTimeInterval: $0) })
}
