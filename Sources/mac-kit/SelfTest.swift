import ArgumentParser
import Foundation
import JavaScriptCore
import SQLite3

// MARK: - Self-test harness
//
// This machine's toolchain is Command Line Tools-only: neither XCTest nor
// swift-testing ships with it, so `swift test` cannot link a test bundle.
// Instead the unit checks for the pure Notes helpers (revision hashing, HTML
// wrapping/escaping, backup-path sanitization, exact-string edit semantics,
// and JXA string-literal construction) live behind `mac-kit self-test`:
// zero test-infra dependencies, runs anywhere the binary builds, exits
// nonzero on any failure so CI can gate on it. Live Notes.app checks are NOT
// here — they need a logged-in session and a TCC Automation grant.

struct SelfTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-test",
        abstract: "Run built-in unit checks for the pure helpers (no app automation, CI-safe)."
    )

    func run() throws {
        let t = SelfTestRun()

        // MARK: sha256Hex (the notes revision hash)

        t.equal(sha256Hex(""),
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                "sha256Hex empty string")
        t.equal(sha256Hex("hello"),
                "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
                "sha256Hex known vector")
        t.check(sha256Hex("真机自测 ✅") == sha256Hex("真机自测 ✅"), "sha256Hex unicode stable")
        t.check(sha256Hex("真机自测") != sha256Hex("真机自测 "), "sha256Hex trailing space changes hash")
        let hash = sha256Hex("MacKit")
        t.check(hash == hash.lowercased() && hash.count == 64 && hash.allSatisfy { $0.isHexDigit },
                "sha256Hex lowercase 64-char hex")

        // MARK: HTML detection heuristic

        t.check(notesLooksLikeHTML("<div>hi</div>"), "looksLikeHTML div")
        t.check(notesLooksLikeHTML("text with <b>bold</b>"), "looksLikeHTML inline tag")
        t.check(notesLooksLikeHTML("</div>"), "looksLikeHTML closing tag")
        t.check(notesLooksLikeHTML("<!-- comment -->"), "looksLikeHTML comment")
        t.check(!notesLooksLikeHTML("plain text"), "looksLikeHTML plain")
        t.check(!notesLooksLikeHTML("a < b and b > c"), "looksLikeHTML '< ' not tag-shaped")
        t.check(!notesLooksLikeHTML("1 <2"), "looksLikeHTML digit after < not a tag")

        // MARK: Entity escaping

        t.equal(escapeHTMLText("a & b < c > d \"e\""), "a &amp; b &lt; c &gt; d &quot;e&quot;",
                "escapeHTMLText all entities")
        t.equal(escapeHTMLText("&lt;"), "&amp;lt;", "escapeHTMLText no double-escape (& first)")

        // MARK: Fragment building

        t.equal(notesHTMLFragment(from: "hello"), "<div>hello</div>", "fragment wraps plain text")
        t.equal(notesHTMLFragment(from: "a & b > c"), "<div>a &amp; b &gt; c</div>",
                "fragment escapes plain text")
        t.equal(notesHTMLFragment(from: "line1\n\nline2"),
                "<div>line1</div><div><br></div><div>line2</div>",
                "fragment multiline with blank line")
        t.equal(notesHTMLFragment(from: "a\r\nb"), "<div>a</div><div>b</div>",
                "fragment normalizes CRLF")
        let html = "<div>already <b>html</b> &amp; entities</div>"
        t.equal(notesHTMLFragment(from: html), html, "fragment passes HTML through")

        // MARK: Fragment merging (Notes shatters headings/styled runs)

        t.equal(notesMergeAdjacentFragments("<b><h1>A</h1></b><b><h1>B</h1></b>"),
                "<b><h1>AB</h1></b>", "merge: the canonical shattered-h1 case")
        t.equal(notesMergeAdjacentFragments("<b><h2>西北雨林</h2></b><b><h2> + </h2></b><b><h2>黄石秋色</h2></b>"),
                "<b><h2>西北雨林 + 黄石秋色</h2></b>", "merge: h2 fragments with CJK")
        t.equal(notesMergeAdjacentFragments("<b><h1>A</h1></b><b><h1>B</h1></b><b><h1>C</h1></b>"),
                "<b><h1>ABC</h1></b>", "merge: triple fragments reach fixpoint")
        t.equal(notesMergeAdjacentFragments(
                    "<div><b><h1>🗺️</h1></b><b><h1> 15</h1></b><b><h1>天环美硬核路书</h1></b></div>"),
                "<div><b><h1>🗺️ 15天环美硬核路书</h1></b></div>",
                "merge: real damaged-note heading line")
        t.equal(notesMergeAdjacentFragments("<b>America the Beautiful </b><b>国家公园年票（</b><b>$80</b><b>）</b>"),
                "<b>America the Beautiful 国家公园年票（$80）</b>", "merge: plain bold runs")
        t.equal(notesMergeAdjacentFragments(
                    "<span style=\"font-size: 24px\">A</span><span style=\"font-size: 24px\">B</span>"),
                "<span style=\"font-size: 24px\">AB</span>", "merge: identical-style spans")
        let differentSpans = "<span style=\"color: red\">A</span><span style=\"color: blue\">B</span>"
        t.equal(notesMergeAdjacentFragments(differentSpans), differentSpans,
                "merge: NON-identical span styles are not merged")
        let intervening = "<b>A</b>x<b>B</b>"
        t.equal(notesMergeAdjacentFragments(intervening), intervening,
                "merge: intervening text blocks the seam")
        let divs = "<div>a</div><div>b</div>"
        t.equal(notesMergeAdjacentFragments(divs), divs,
                "merge: adjacent divs are real lines, never merged")
        let spaced = "<b>A</b> <b>B</b>"
        t.equal(notesMergeAdjacentFragments(spaced), spaced,
                "merge: whitespace at the seam is significant, not merged")
        t.equal(notesMergeAdjacentFragments("plain text, no tags"), "plain text, no tags",
                "merge: plain text untouched")
        let sample = "<div><b><h1>🗺️</h1></b><b><h1> 15</h1></b></div><div><b>x</b><b>y</b></div>"
        t.equal(notesMergeAdjacentFragments(notesMergeAdjacentFragments(sample)),
                notesMergeAdjacentFragments(sample), "merge: idempotent")
        t.equal(notesMergeAdjacentFragments(
                    "<span title=\"a>b\">X</span><span title=\"a>b\">Y</span>"),
                "<span title=\"a>b\">XY</span>",
                "merge: quoted > inside attr parsed correctly, merges cleanly")
        let quotedDiffer = "<span title=\"a>b\">X</span><span title=\"a>c\">Y</span>"
        t.equal(notesMergeAdjacentFragments(quotedDiffer), quotedDiffer,
                "merge: quoted > attrs that differ are not merged, not corrupted")
        let entityFusion = "<b>&</b><b>nbsp;</b>"
        t.equal(notesMergeAdjacentFragments(entityFusion), entityFusion,
                "merge: refuses seam that would fuse & + nbsp; into an entity")
        let entitySplit = "<b>x&am</b><b>p;y</b>"
        t.equal(notesMergeAdjacentFragments(entitySplit), entitySplit,
                "merge: refuses seam ending in partial entity name")
        t.equal(notesMergeAdjacentFragments("<b>x&amp;</b><b>y</b>"),
                "<b>x&amp;y</b>",
                "merge: COMPLETE entity (&amp; ends with ;) still merges")
        t.check(notesEndsWithIncompleteEntity("&"), "entity guard: bare &")
        t.check(notesEndsWithIncompleteEntity("x&nb"), "entity guard: partial name")
        t.check(notesEndsWithIncompleteEntity("x&#160"), "entity guard: partial numeric")
        t.check(!notesEndsWithIncompleteEntity("x&amp;"), "entity guard: complete entity ok")
        t.check(!notesEndsWithIncompleteEntity("plain"), "entity guard: plain text ok")
        t.check(!notesEndsWithIncompleteEntity(""), "entity guard: empty ok")

        // MARK: Backup filename sanitization

        t.equal(notesBackupStem("Claw Shared note"), "Claw_Shared_note", "backup stem spaces")
        t.equal(notesBackupStem("../etc/passwd; rm -rf /"), "etc_passwd_rm_-rf",
                "backup stem strips path/shell chars")
        t.equal(notesBackupStem("  a///b  "), "a_b", "backup stem collapses runs")
        t.equal(notesBackupStem("...hidden"), "hidden", "backup stem no hidden files")
        t.equal(notesBackupStem("购物清单 2026"), "购物清单_2026", "backup stem keeps unicode alphanumerics")
        t.equal(notesBackupStem("!!!"), "note", "backup stem never empty")
        t.equal(notesBackupStem(""), "note", "backup stem empty input")
        t.check(notesBackupStem(String(repeating: "x", count: 300)).count <= 80,
                "backup stem capped at 80")
        t.equal(notesBackupFileName(noteName: "Claw Shared note", unixMillis: 1_752_000_000_123, nonce: "ab12"),
                "Claw_Shared_note-1752000000123-ab12.html", "backup file name format (ms + nonce)")
        t.equal(notesBackupFileName(noteName: "Claw Shared note", unixMillis: 1_752_000_000_123,
                                    nonce: "ab12", attempt: 2),
                "Claw_Shared_note-1752000000123-ab12-2.html", "backup file name collision suffix")
        t.check(notesBackupFileName(noteName: "n", unixMillis: 1, nonce: "0000")
                != notesBackupFileName(noteName: "n", unixMillis: 1, nonce: "0000", attempt: 1),
                "backup collision retry changes the name")

        // MARK: notes_edit exact-string semantics

        t.equal(try? notesApplyUniqueEdit(body: "<div>alpha</div><div>beta</div>",
                                          oldString: "beta", newString: "gamma"),
                "<div>alpha</div><div>gamma</div>", "edit replaces unique match")
        t.throwsError(matching: { $0.hasPrefix("NO_MATCH") }, "edit NO_MATCH on zero occurrences") {
            _ = try notesApplyUniqueEdit(body: "<div>a</div>", oldString: "zzz", newString: "y")
        }
        t.throwsError(matching: { $0.contains("AMBIGUOUS") && $0.contains("3 times") },
                      "edit AMBIGUOUS with count") {
            _ = try notesApplyUniqueEdit(body: "<div>x</div><div>x</div><div>x</div>",
                                         oldString: "<div>x</div>", newString: "y")
        }
        t.throwsError(matching: { $0.contains("occurs 2 times") },
                      "edit counts OVERLAPPING occurrences (aaa contains aa twice)") {
            _ = try notesApplyUniqueEdit(body: "aaa", oldString: "aa", newString: "b")
        }
        t.throwsError(matching: { $0.contains("occurs 3 times") },
                      "edit overlapping count on aaaa/aa is 3") {
            _ = try notesApplyUniqueEdit(body: "aaaa", oldString: "aa", newString: "b")
        }
        t.equal(try? notesApplyUniqueEdit(body: "<div>keep drop</div>",
                                          oldString: " drop", newString: ""),
                "<div>keep</div>", "edit with empty replacement deletes text")

        // MARK: Attachment rail (fail CLOSED)

        t.check(notesAttachmentRailError(count: 0) == nil, "attachment rail passes on verified zero")
        t.check(notesAttachmentRailError(count: 2)?.hasPrefix("HAS_ATTACHMENTS") == true,
                "attachment rail refuses on attachments present")
        t.check(notesAttachmentRailError(count: -1)?.hasPrefix("ATTACHMENT_CHECK_FAILED") == true,
                "attachment rail fails CLOSED when the check itself errored")
        t.check(notesAttachmentRailError(count: -1) != notesAttachmentRailError(count: 2),
                "attachment rail refusal codes are distinct")

        // MARK: Post-write result shape (never error after a completed mutation)

        let okResult = notesMutationResultText(headline: "Appended to \"n\".",
                                               oldRevision: "aa", newBody: "<div>x</div>",
                                               backupPath: "/tmp/b.html")
        t.check(okResult.contains("New revision: \(sha256Hex("<div>x</div>"))"),
                "mutation result carries new revision when re-read worked")
        t.check(!okResult.contains("WRITE_OK_REVISION_UNKNOWN"),
                "mutation result has no warning when re-read worked")
        let degradedResult = notesMutationResultText(headline: "Appended to \"n\".",
                                                     oldRevision: "aa", newBody: nil,
                                                     backupPath: "/tmp/b.html")
        t.check(degradedResult.hasPrefix("Appended to"),
                "mutation result is still SUCCESS when post-write re-read failed")
        t.check(degradedResult.contains("WRITE_OK_REVISION_UNKNOWN"),
                "mutation result flags unknown revision after failed re-read")

        // MARK: Mutation-execution death (unknowable write state)

        let unknownState = notesTimeoutUnknownStateMessage(action: "write")
        t.check(unknownState.hasPrefix("TIMEOUT_UNKNOWN_STATE"),
                "unknown-state message carries the TIMEOUT_UNKNOWN_STATE code")
        t.check(unknownState.contains("may or may not have applied")
                && unknownState.contains("notes_read"),
                "unknown-state message says to inspect before retrying")
        t.check(notesTimeoutUnknownStateMessage(action: "create").contains("the create"),
                "unknown-state message names the interrupted action")

        // MARK: Failure-origin classification (dead process vs completed refusal)

        t.check(notesMutationFailureMessage(
                    for: NotesProcessDied("osascript timed out after 90s"), action: "write")
                .hasPrefix("TIMEOUT_UNKNOWN_STATE"),
                "dead mutation process maps to TIMEOUT_UNKNOWN_STATE")
        t.check(notesMutationFailureMessage(
                    for: NotesProcessDied("Unexpected response from Notes.app: garbage"), action: "write")
                .hasPrefix("TIMEOUT_UNKNOWN_STATE"),
                "unparseable mutation output maps to TIMEOUT_UNKNOWN_STATE")
        t.equal(notesMutationFailureMessage(
                    for: ToolError("cannot read note body: AppleEvent timed out"), action: "write"),
                "cannot read note body: AppleEvent timed out",
                "completed pre-write refusal containing 'timed out' stays precise")
        t.equal(notesMutationFailureMessage(
                    for: ToolError("cannot list Notes folders: timed out"), action: "create"),
                "cannot list Notes folders: timed out",
                "completed create refusal containing 'timed out' stays precise")
        t.check(!notesMutationFailureMessage(
                    for: ToolError("REVISION_MISMATCH: note changed since read; re-read and retry"),
                    action: "write")
                .contains("TIMEOUT_UNKNOWN_STATE"),
                "structured CAS conflict never remapped to unknown state")

        // MARK: JXA string-literal construction (injection safety)
        //
        // Every dynamic value crossing into JXA source is embedded via
        // jsLiteral (a JSON string literal — a strict subset of a JS string
        // literal), so note names/bodies/content can never terminate their
        // string context.

        t.equal(jsLiteral(#"a"b\c"#), #""a\"b\\c""#, "jsLiteral quotes and backslashes")
        let newlineLiteral = jsLiteral("line1\nline2")
        t.check(newlineLiteral == #""line1\nline2""# && !newlineLiteral.contains("\n"),
                "jsLiteral newlines stay escaped")
        let hostile = jsLiteral(#"'); Notes.notes[0].delete(); ('"#)
        var escaped = false
        var breakout = false
        for character in hostile.dropFirst().dropLast() {
            if character == "\"" && !escaped { breakout = true }
            escaped = (character == "\\") && !escaped
        }
        t.check(hostile.hasPrefix("\"") && hostile.hasSuffix("\"") && !breakout,
                "jsLiteral hostile string cannot escape quotes")
        let nasty = "\"\\\n\t\u{2028}\u{2029}真机 ✅ </script>"
        let decoded = (try? JSONSerialization.jsonObject(
            with: Data(jsLiteral(nasty).utf8), options: [.fragmentsAllowed])) as? String
        t.equal(decoded, nasty, "jsLiteral lossless round-trip (CAS body comparison relies on this)")

        // MARK: mail_send attachment path normalization

        t.equal(mailAttachmentAbsolutePath("/tmp/a.png", home: "/Users/x"), "/tmp/a.png",
                "attachment path absolute passes through")
        t.equal(mailAttachmentAbsolutePath("~/a.png", home: "/Users/x"), "/Users/x/a.png",
                "attachment path tilde expands")
        t.equal(mailAttachmentAbsolutePath("~", home: "/Users/x"), "/Users/x",
                "attachment path bare tilde expands")
        t.check(mailAttachmentAbsolutePath("a.png", home: "/Users/x") == nil,
                "attachment path relative rejected")
        t.check(mailAttachmentAbsolutePath("~user/a.png", home: "/Users/x") == nil,
                "attachment path other-user tilde rejected")
        t.equal(mailAttachmentAbsolutePath("/tmp/trailing space.png ", home: "/Users/x"),
                "/tmp/trailing space.png ",
                "attachment path bytes untouched (no trim of trailing space)")

        // MARK: mail_send sender resolution (silent-fallback trap guard)

        let accounts = [
            MailSendAccount(name: "iCloud", fullName: "Jane Appleseed",
                            emails: ["a@me.com", "a@icloud.com"]),
            MailSendAccount(name: "Google", fullName: "Jane Appleseed",
                            emails: ["a@gmail.com"]),
            MailSendAccount(name: "Empty", fullName: "Jane Appleseed", emails: [])
        ]
        t.equal(resolveMailSender(accounts: accounts, query: "a@icloud.com"),
                .resolved("Jane Appleseed <a@icloud.com>"),
                "sender resolves to EXACT matched address, not the account's first")
        t.equal(resolveMailSender(accounts: accounts, query: "A@GMAIL.COM"),
                .resolved("Jane Appleseed <a@gmail.com>"),
                "sender address match is case-insensitive")
        t.equal(resolveMailSender(accounts: accounts, query: "google"),
                .resolved("Jane Appleseed <a@gmail.com>"),
                "sender name match resolves to primary address")
        switch resolveMailSender(accounts: accounts, query: "bogus-account") {
        case .resolved: t.check(false, "sender bogus query must fail")
        case .failed(let message):
            t.check(message.contains("no Mail account matches") && message.contains("a@gmail.com")
                        && message.contains("nothing sent"),
                    "sender no-match error lists accounts and confirms nothing sent")
        }
        let dupAccounts = accounts + [
            MailSendAccount(name: "Google", fullName: "Other Persona", emails: ["b@gmail.com"])
        ]
        switch resolveMailSender(accounts: dupAccounts, query: "Google") {
        case .resolved: t.check(false, "sender ambiguous name must fail")
        case .failed(let message):
            t.check(message.contains("ambiguous") && message.contains("a@gmail.com")
                        && message.contains("b@gmail.com") && message.contains("address"),
                    "sender ambiguous-name error lists all candidates and asks for an address")
        }
        t.equal(resolveMailSender(accounts: dupAccounts, query: "b@gmail.com"),
                .resolved("Other Persona <b@gmail.com>"),
                "sender exact address disambiguates duplicate account names")
        switch resolveMailSender(accounts: accounts, query: "Empty") {
        case .resolved: t.check(false, "sender addressless account must fail")
        case .failed(let message):
            t.check(message.contains("no email addresses"),
                    "sender addressless-account error explains the problem")
        }
        t.equal(resolveMailSender(accounts: [MailSendAccount(name: "X", fullName: "",
                                                             emails: ["x@y.z"])],
                                  query: "x@y.z"),
                .resolved("x@y.z"),
                "sender without fullName is the bare address")

        // MARK: mail_archive Gmail criterion (target state reached, not symptom gone)
        //
        // gmailArchiveCriterionJS is the exact source the archive script runs
        // in Mail.app; evaluate it here under JavaScriptCore. Verdict arguments
        // are the Mail.app ids of the fingerprint-matching copies per mailbox.

        let js = JSContext()!
        if #available(macOS 13.3, *) { js.isInspectable = false }
        js.evaluateScript(gmailArchiveCriterionJS)
        func evalJS(_ expr: String) -> String {
            js.evaluateScript("JSON.stringify(\(expr))")?.toString() ?? "<nil>"
        }
        func verdict(_ state: String) -> String {
            js.evaluateScript("gmailArchiveVerdict(\(state))")?.toString() ?? "<nil>"
        }
        t.equal(verdict("{inbox: [], allMail: [500], trash: []}"), "archived",
                "gmail verdict: in All Mail only is archived")
        t.equal(verdict("{inbox: [500], allMail: [500], trash: []}"), "inbox",
                "gmail verdict: INBOX label still present is not archived")
        t.equal(verdict("{inbox: [], allMail: [], trash: [501]}"), "trash",
                "gmail verdict: Trash only is left in Trash")
        t.equal(verdict("{inbox: [], allMail: [], trash: []}"), "missing",
                "gmail verdict: nowhere is not archived (the old else-OK bug)")
        t.equal(verdict("{inbox: [], allMail: [502], trash: [501]}"), "ambiguous",
                "gmail verdict: copies in both All Mail and Trash are ambiguous (All Mail newer)")
        t.equal(verdict("{inbox: [], allMail: [500], trash: [501]}"), "ambiguous",
                "gmail verdict: copies in both All Mail and Trash are ambiguous (Trash newer)")
        t.equal(verdict("{inbox: [], allMail: [500, 503], trash: []}"), "ambiguous",
                "gmail verdict: two fingerprint matches in All Mail are ambiguous")
        t.equal(verdict("{inbox: [], allMail: [], trash: [501, 502]}"), "ambiguous",
                "gmail verdict: two fingerprint matches in Trash are ambiguous")
        t.equal(verdict("{inbox: [500, 503], allMail: [500, 503], trash: []}"), "ambiguous",
                "gmail verdict: two fingerprint matches in INBOX are ambiguous")
        t.equal(verdict("{inbox: [], allMail: null, trash: []}"), "unknown",
                "gmail verdict: a failed All Mail lookup is unknown, not missing")
        t.equal(verdict("{inbox: null, allMail: [500], trash: []}"), "unknown",
                "gmail verdict: a failed INBOX lookup is unknown, not archived")
        t.equal(verdict("{inbox: [], allMail: [500], trash: null}"), "unknown",
                "gmail verdict: a failed Trash lookup is unknown, not archived")
        t.equal(verdict("undefined"), "unknown", "gmail verdict: no state is unknown")

        // Fingerprint (Message-ID + Date): fail closed when a Date is unreadable.
        t.equal(evalJS("fingerprintFilter([{id: 1, ds: 1000}, {id: 2, ds: 5000}], 1000)"), "[1]",
                "fingerprint: same Message-ID, different Date is a different message")
        t.equal(evalJS("fingerprintFilter([{id: 1, ds: 1001}], 1000)"), "[1]",
                "fingerprint: one second of Date skew still matches")
        t.equal(evalJS("fingerprintFilter([{id: 1, ds: 1002}], 1000)"), "[]",
                "fingerprint: two seconds apart is a different message")
        t.equal(evalJS("fingerprintFilter([{id: 1, ds: 1000}, {id: 2, ds: null}], 1000)"), "null",
                "fingerprint: a candidate whose Date can't be read fails the lookup")
        t.equal(evalJS("fingerprintFilter([{id: 1, ds: 1000}], -1)"), "null",
                "fingerprint: no Date for the target fails the lookup (no Message-ID-only fallback)")
        t.equal(evalJS("fingerprintFilter([{id: 1, ds: 1000}], null)"), "null",
                "fingerprint: null target Date fails the lookup")
        t.equal(evalJS("fingerprintFilter([], 1000)"), "[]", "fingerprint: no candidates is empty")

        // Pre-check before anything is deleted. `requested` is the INBOX lookup
        // by the caller's exact row id; the fingerprint only verifies it.
        func pre(_ requested: String, _ inbox: String, _ preTrash: String) -> String {
            evalJS("gmailArchivePrecheck({id: 500, requested: \(requested), inbox: \(inbox), preTrash: \(preTrash)})")
        }
        t.equal(pre("[500]", "[500]", "[]"), "\"proceed\"",
                "precheck: the requested row in INBOX with a clean Trash baseline proceeds")
        t.equal(pre("[]", "[503]", "[]"), "\"not-in-inbox\"",
                "precheck: requested row not in INBOX refuses even if another fingerprint match is")
        t.equal(pre("[500]", "[503]", "[]"), "\"mismatch\"",
                "precheck: requested row does not carry the fingerprint refuses")
        t.equal(pre("[500]", "[500, 503]", "[]"), "\"ambiguous\"",
                "precheck: a second INBOX fingerprint match refuses")
        t.equal(pre("[500]", "[500]", "[480]"), "\"ambiguous\"",
                "precheck: a Trash copy already present refuses")
        t.equal(pre("[500]", "[500]", "null"), "\"unknown\"",
                "precheck: failed Trash baseline aborts before deleting")
        t.equal(pre("null", "[500]", "[]"), "\"unknown\"",
                "precheck: failed lookup of the requested row aborts")
        t.equal(pre("[500]", "null", "[]"), "\"unknown\"",
                "precheck: failed INBOX fingerprint lookup aborts")

        // Watermark: only copies created after the run started are ours.
        t.equal(evalJS("newCopies([480, 501, 502], 500)"), "[501,502]",
                "watermark: copies at or below the watermark are pre-existing")
        t.equal(evalJS("newCopies([500], 500)"), "[]", "watermark: equal to the watermark is pre-existing")
        t.equal(evalJS("newCopies(null, 500)"), "null", "watermark: failed lookup stays failed")
        t.equal(evalJS("newCopies([501], undefined)"), "null", "watermark: no watermark fails closed")

        // Outcome: OK only when this run saw the Trash copy arrive, refiled it,
        // and the result is a single All Mail copy created by the refile.
        func outcome(_ arrived: Bool, _ refiled: Bool, _ state: String) -> String {
            evalJS("gmailArchiveOutcome({arrived: \(arrived), refiled: \(refiled), wm: 500, state: \(state)})")
        }
        t.equal(outcome(true, true, "{inbox: [], allMail: [502], trash: []}"), "\"archived\"",
                "outcome: arrival seen, refiled, new All Mail copy only is archived")
        t.equal(outcome(false, false, "{inbox: [], allMail: [500], trash: []}"), "\"unknown\"",
                "outcome: INBOX gone + All Mail present without a seen Trash arrival is unknown, not OK")
        t.equal(outcome(true, false, "{inbox: [], allMail: [502], trash: []}"), "\"unknown\"",
                "outcome: no refile performed is unknown")
        t.equal(outcome(true, true, "{inbox: [], allMail: [500], trash: []}"), "\"unknown\"",
                "outcome: the only All Mail copy predates the run (refile not landed) is unknown")
        t.equal(outcome(true, true, "{inbox: [], allMail: [502], trash: [501]}"), "\"ambiguous\"",
                "outcome: Trash copy still listed after refile is ambiguous")
        t.equal(outcome(true, true, "{inbox: [], allMail: [], trash: [501]}"), "\"trash\"",
                "outcome: refile did not take is left in Trash")
        t.equal(outcome(true, true, "{inbox: [500], allMail: [500], trash: []}"), "\"inbox\"",
                "outcome: still in INBOX is still in INBOX")
        t.check(js.exception == nil, "gmail criterion: JS evaluated without exceptions")

        // Swift side: a Gmail job without a Date in the index is refused up front.
        t.check(mailArchiveRefusal(gmail: true, dateSent: nil, watermark: 60_000) != nil,
                "refusal: Gmail job with no Date is refused")
        t.check(mailArchiveRefusal(gmail: true, dateSent: -5, watermark: 60_000) != nil,
                "refusal: Gmail job with a negative Date is refused")
        t.check(mailArchiveRefusal(gmail: true, dateSent: 1_795_000_000, watermark: 60_000) == nil,
                "refusal: Gmail job with a Date proceeds")
        t.check(mailArchiveRefusal(gmail: false, dateSent: nil, watermark: 60_000) == nil,
                "refusal: standard IMAP job does not need a Date")
        t.check(mailArchiveRefusal(gmail: true, dateSent: 1_795_000_000, watermark: nil) != nil,
                "refusal: Gmail job without an index watermark is refused")
        t.check(mailArchiveRefusal(gmail: false, dateSent: nil, watermark: nil) == nil,
                "refusal: standard IMAP job does not need a watermark")
        t.equal(MailArchiveStatus(token: "OK"), .ok, "status: OK token is success")
        t.equal(MailArchiveStatus(token: "AMBIGUOUS"), .ambiguous, "status: AMBIGUOUS is its own status")
        t.equal(MailArchiveStatus(token: "UNKNOWN"), .unknown, "status: UNKNOWN is its own status")
        t.equal(MailArchiveStatus(token: "ERR"), .error, "status: ERR is an error")
        t.equal(MailArchiveStatus(token: "garbage"), .error, "status: unrecognised token is never success")

        // The whole archive script (with the criterion spliced in) must at least
        // parse; JXA would otherwise fail every archive at run time. Parse only:
        // the script is wrapped in a function that is never called.
        let parser = JSContext()!
        let script = mailArchiveScript(jobsJSON: "[]", scriptBudget: 80, watermark: 60_000)
        parser.evaluateScript("var parsed = typeof (function () {\n" + script + "\n; return run; })")
        t.check(parser.exception == nil,
                "mail_archive script parses (\(parser.exception?.toString() ?? "ok"))")
        t.check(script.contains("function gmailArchiveVerdict(") && script.contains("function fingerprintFilter(")
                    && script.contains("function gmailArchivePrecheck(")
                    && script.contains("function gmailArchiveOutcome(") && script.contains("function newCopies("),
                "mail_archive script embeds the tested criterion")

        // MARK: mail_rescue_recovered (end state in the index, not the move call)
        //
        // State arguments are fingerprint-matching ROWIDs per mailbox. Row 500
        // sits in Recovered; the watermark is 600, so a copy created by the
        // move has a ROWID above 600.

        func st(_ recovered: [Int64]?, _ allMail: [Int64]?, _ trash: [Int64]?) -> RescueState {
            RescueState(recovered: recovered, allMail: allMail, trash: trash)
        }
        func rv(_ move: RescueMove, _ state: RescueState) -> RescueStatus {
            rescueVerdict(rowID: 500, watermark: 600, move: move, state: state).status
        }
        t.equal(rv(.moved, st([], [601], [])), .movedLocally,
                "rescue: gone from Recovered, one new All Mail copy, no Trash is OK")
        t.equal(rv(.moved, st([500], [], [])), .stillInRecovered,
                "rescue: move returned but still in Recovered is STILL_IN_RECOVERED")
        t.equal(rv(.moved, st([], [601], [602])), .unknown,
                "rescue: All Mail + Trash copy (the 50747/50748 state) is not OK")
        t.equal(rv(.moved, st([], [], [])), .unknown,
                "rescue: vanished from Recovered but not in All Mail is not OK")
        t.equal(rv(.moved, st([], [], [601])), .unknown,
                "rescue: landed in Trash only is not OK")
        t.equal(rv(.moved, st([500], [601], [])), .unknown,
                "rescue: copies in both Recovered and All Mail is unknown")
        t.equal(rv(.moved, st([], [601, 602], [])), .unknown,
                "rescue: two new All Mail copies is not OK")
        t.equal(rv(.moved, st([], [480], [])), .unknown,
                "rescue: an All Mail copy that predates the run is not proof of the move")
        t.equal(rv(.moved, st([], [480, 601], [])), .unknown,
                "rescue: old + new All Mail copies is not OK")
        t.equal(rv(.moved, st(nil, [601], [])), .unknown, "rescue: failed Recovered lookup is unknown")
        t.equal(rv(.moved, st([], nil, [])), .unknown, "rescue: failed All Mail lookup is unknown")
        t.equal(rv(.moved, st([], [601], nil)), .unknown, "rescue: failed Trash lookup is unknown")
        t.equal(rv(.indeterminate("osascript timed out"), st([], [601], [])), .unknown,
                "rescue: a timed-out move is UNKNOWN even when the index looks done")
        t.equal(rv(.indeterminate("Mail.move raised"), st([500], [], [])), .unknown,
                "rescue: a move that threw is UNKNOWN even when still in Recovered")
        t.equal(rv(.notAttempted("refused"), st([500], [], [])), .stillInRecovered,
                "rescue: refused before moving and unchanged is STILL_IN_RECOVERED")
        t.equal(rv(.notAttempted("already in All Mail"), st([500], [480], [])), .stillInRecovered,
                "rescue: refused because already in All Mail stays STILL_IN_RECOVERED")
        t.equal(rv(.notAttempted("refused"), st([], [601], [])), .unknown,
                "rescue: not attempted can never be OK")
        t.equal(rv(.notAttempted("refused"), st(nil, nil, nil)), .unknown,
                "rescue: not attempted with unreadable state is unknown")

        // Pre-check: only the sole fingerprint match in Recovered, nothing in
        // All Mail or Trash yet, with a watermark and a Date.
        func rp(_ state: RescueState, ds: Int64? = 1_795_000_000, wm: Int64? = 600,
                header: String? = "m77@example.com", expected: String? = nil) -> Bool {
            rescuePrecheck(rowID: 500, header: header, expectedMessageID: expected,
                           dateSent: ds, watermark: wm, state: state) == nil
        }
        t.check(rp(st([500], [], [])), "rescue precheck: sole Recovered copy proceeds")
        t.check(!rp(st([500], [480], [])), "rescue precheck: already in All Mail is not moved (no duplicate)")
        t.check(!rp(st([500], [], [480])), "rescue precheck: a Trash copy already present refuses")
        t.check(!rp(st([500, 501], [], [])), "rescue precheck: two Recovered fingerprint matches refuse")
        t.check(!rp(st([501], [], [])), "rescue precheck: row without its own fingerprint refuses")
        t.check(!rp(st([500], nil, [])), "rescue precheck: failed lookup refuses")
        t.check(!rp(st([500], [], []), ds: nil), "rescue precheck: no Date refuses")
        t.check(!rp(st([500], [], []), wm: nil), "rescue precheck: no watermark refuses")
        // Same eligibility in the dry run and apply: a row with no Message-ID
        // is never eligible (Mail.app could not find it by Message-ID).
        t.check(!rp(st([500], [], []), header: nil), "rescue precheck: no Message-ID is not eligible")
        t.check(!rp(st([500], [], []), header: "<>"), "rescue precheck: an empty Message-ID is not eligible")
        // apply: the id must still carry the Message-ID the dry run showed.
        t.check(rp(st([500], [], []), expected: "m77@example.com"), "rescue precheck: matching message_id proceeds")
        t.check(rp(st([500], [], []), expected: "<m77@example.com>"), "rescue precheck: message_id may keep its angle brackets")
        t.check(!rp(st([500], [], []), expected: "other@example.com"),
                "rescue precheck: an id that now belongs to another message is not moved")
        t.check(rescuePrecheck(rowID: 500, header: "m77@example.com", expectedMessageID: "other@example.com",
                               dateSent: 1_795_000_000, watermark: 600, state: st([500], [], []))?
                    .contains("no longer refers to that message") == true,
                "rescue precheck: a stale id says to run the dry run again")

        // Script reply parsing: only a clean MOVED is a completed move.
        t.equal(rescueMove(fromScriptOutput: "MOVED"), .moved, "rescue reply: MOVED")
        t.equal(rescueMove(fromScriptOutput: "SKIP\tnone"), .notAttempted("none"), "rescue reply: SKIP is not attempted")
        t.check(rescueMove(fromScriptOutput: "ERRMOVE\t-1728") != .moved, "rescue reply: ERRMOVE is not a move")
        t.check(rescueMove(fromScriptOutput: "") != .moved, "rescue reply: empty is not a move")
        t.check(rescueMove(fromScriptOutput: "MOVED?") != .moved, "rescue reply: garbage is not a move")

        // Swift fingerprint twin agrees with the JS one on the same vectors.
        let fpVectors: [([(id: Int64, ds: Int64?)], Int64?)] = [
            ([(1, 1000), (2, 5000)], 1000), ([(1, 1001)], 1000), ([(1, 1002)], 1000),
            ([(1, 1000), (2, nil)], 1000), ([(1, 1000)], -1), ([(1, 1000)], nil), ([], 1000)
        ]
        for (index, vector) in fpVectors.enumerated() {
            let swiftResult = mailFingerprintFilter(vector.0, ds: vector.1)
            let swiftJSON = swiftResult.map { "[" + $0.map(String.init).joined(separator: ",") + "]" } ?? "null"
            let candsJS = "[" + vector.0.map { "{id: \($0.id), ds: \($0.ds.map(String.init) ?? "null")}" }
                .joined(separator: ",") + "]"
            t.equal(swiftJSON, evalJS("fingerprintFilter(\(candsJS), \(vector.1.map(String.init) ?? "null"))"),
                    "fingerprint: Swift and JS agree on vector \(index)")
        }

        // Stability: after a completed move, OK needs the same OK state on the
        // last two observations, at least rescueStableGap seconds apart.
        let okState = st([], [601], [])
        func sv(_ obs: [(TimeInterval, RescueState)], _ move: RescueMove = .moved) -> RescueStatus {
            rescueStableVerdict(rowID: 500, watermark: 600, move: move,
                                observations: obs.map { (at: $0.0, state: $0.1) }).status
        }
        t.equal(sv([(0, okState), (5, okState)]), .movedLocally, "stable: same OK state twice 5s apart is OK")
        t.equal(sv([(0, okState)]), .unknown, "stable: OK seen once is not confirmed")
        t.equal(sv([(0, okState), (5, st([], [601], [602]))]), .unknown,
                "stable: matched once then changed (Trash copy appeared) is not OK")
        t.equal(sv([(0, okState), (5, st([500], [], []))]), .unknown,
                "stable: matched once then back in Recovered is not OK")
        t.equal(sv([(0, okState), (5, st([], [602], []))]), .unknown,
                "stable: OK twice but a different All Mail copy each time is not OK")
        t.equal(sv([(0, okState), (4.9, okState)]), .unknown, "stable: two OK looks under 5s apart is not OK")
        t.equal(sv([(0, okState), (5, okState), (10, st([], [], []))]), .unknown,
                "stable: confirmed OK that later changes is judged on the latest pair")
        t.equal(sv([(0, st([], [601], [602])), (5, okState), (10, okState)]), .movedLocally,
                "stable: a transient All Mail + Trash state that settles to OK is OK")
        t.equal(sv([(0, st([500], [], [])), (5, st([500], [], []))]), .stillInRecovered,
                "stable: still in Recovered on two looks is STILL_IN_RECOVERED")
        t.equal(sv([(0, st([500], [], [])), (5, okState)]), .unknown,
                "stable: just changed to OK on the last look is not confirmed")
        t.equal(sv([]), .unknown, "stable: no observation is unknown")
        t.equal(sv([(0, okState), (5, okState)], .indeterminate("timed out")), .unknown,
                "stable: a timed-out move stays UNKNOWN however stable the index is")
        t.equal(sv([(0, st([500], [], []))], .notAttempted("refused")), .stillInRecovered,
                "stable: a refused move needs one look only")

        // Requests: apply takes exactly one explicit id and nothing else;
        // nonsense limits are refused, not adjusted.
        func req(apply: Bool, id: Int64? = nil, mid: String? = "m77@example.com", since: String? = nil,
                 subject: String? = nil, limit: Int? = nil) -> RescueRequest? {
            try? rescueRequest(apply: apply, id: id, messageID: mid, since: since, subject: subject, limit: limit)
        }
        t.equal(req(apply: true, id: 500), .apply(id: 500, messageID: "m77@example.com"),
                "request: apply with an id and message_id moves just that id")
        t.equal(req(apply: true, id: 500, mid: nil), nil, "request: apply without message_id is rejected")
        t.equal(req(apply: true, id: 500, mid: " <> "), nil, "request: apply with an empty message_id is rejected")
        t.equal(req(apply: true), nil, "request: apply without an id is rejected")
        t.throwsError(matching: { $0.contains("explicit \"id\"") && $0.contains("nothing was moved") },
                      "request: apply without an id says why") {
            _ = try rescueRequest(apply: true, id: nil, messageID: "m77@example.com", since: nil, subject: nil, limit: nil)
        }
        t.equal(req(apply: true, id: 500, limit: 5), nil, "request: apply refuses a limit (no batches)")
        t.equal(req(apply: true, id: 500, since: "2026-11-01"), nil, "request: apply refuses since")
        t.equal(req(apply: true, id: 500, subject: "x"), nil, "request: apply refuses subject")
        t.equal(req(apply: false), .list(id: nil, since: nil, subject: nil, limit: 50), "request: dry run lists 50 by default")
        t.equal(req(apply: false, since: "2026-11-01", subject: "x", limit: 3),
                .list(id: nil, since: "2026-11-01", subject: "x", limit: 3), "request: dry run keeps its filters")
        t.equal(req(apply: false, limit: 0), nil, "request: limit 0 is refused, not turned into 1")
        t.equal(req(apply: false, limit: -2), nil, "request: negative limit is refused")

        // MCP integer arguments: exact integers only, never truncated.
        func intArg(_ json: String) -> String {
            let parsed = (try? JSONSerialization.jsonObject(with: Data("{\"id\": \(json)}".utf8))) as? [String: Any]
            do { return (try strictInt64Argument(parsed?["id"], name: "id")).map(String.init) ?? "absent" }
            catch { return "error" }
        }
        t.equal(intArg("50442"), "50442", "int arg: an integer passes through")
        t.equal(intArg("500.9"), "error", "int arg: 500.9 is rejected, not truncated to 500")
        t.equal(intArg("-0.5"), "error", "int arg: a fraction is rejected")
        t.equal(intArg("\"500\""), "error", "int arg: a string is rejected")
        t.equal(intArg("true"), "error", "int arg: a boolean is rejected")
        t.equal(intArg("1e30"), "error", "int arg: out of Int64 range is rejected")
        t.equal(intArg("9223372036854775808"), "error", "int arg: Int64.max + 1 is rejected")
        t.equal(intArg("9223372036854775807"), "9223372036854775807", "int arg: Int64.max passes")
        t.equal(intArg("null"), "absent", "int arg: null is absent")
        t.equal((try? strictInt64Argument(nil, name: "id")).map { $0.map(String.init) ?? "absent" }, "absent",
                "int arg: missing is absent")

        // ...and the MCP dispatch really uses it (dry run only: even a
        // regression here could at most list, never move).
        func dispatch(_ args: [String: Any]) -> (isError: Bool, text: String) {
            var reply: [String: Any] = [:]
            let done = DispatchSemaphore(value: 0)
            Task {
                reply = await MCPServer().callTool(params: ["name": "mail_rescue_recovered", "arguments": args])
                done.signal()
            }
            done.wait()
            let text = ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return ((reply["isError"] as? Bool) ?? false, text)
        }
        let fractional = dispatch(["id": NSNumber(value: 500.9), "apply": false])
        t.check(fractional.isError && fractional.text.contains("exact integer"),
                "mcp: id 500.9 is rejected by mail_rescue_recovered, not truncated")
        let stringID = dispatch(["id": "500", "apply": false])
        t.check(stringID.isError && stringID.text.contains("must be an integer"),
                "mcp: a string id is rejected by mail_rescue_recovered")

        // Local-only claim: the status name and message say so.
        t.equal(RescueStatus.movedLocally.rawValue, "MOVED_LOCALLY", "status: success is named MOVED_LOCALLY")
        t.check(rescueVerdict(rowID: 500, watermark: 600, move: .moved, state: okState).message
                    .contains("does not mean the Gmail server has synced"),
                "status: MOVED_LOCALLY says it is not proof of server sync")

        // One observation = one statement over all three mailboxes, on a
        // fixture index (Recovered=23, All Mail=15, Trash=21, INBOX=16).
        let fixture = NSTemporaryDirectory() + "mac-kit-selftest-\(getpid()).sqlite"
        try? FileManager.default.removeItem(atPath: fixture)
        var writer: OpaquePointer?
        if sqlite3_open(fixture, &writer) == SQLITE_OK {
            sqlite3_exec(writer, """
                CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, message_id INTEGER, mailbox INTEGER,
                                       date_sent INTEGER, deleted INTEGER, subject INTEGER,
                                       sender INTEGER, date_received INTEGER);
                CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
                CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
                CREATE TABLE message_global_data (message_id INTEGER, message_id_header TEXT);
                INSERT INTO subjects VALUES (1, 'Cruise deals');
                INSERT INTO addresses VALUES (1, 'a@example.com', 'A');
                INSERT INTO message_global_data VALUES (77, '<m77@example.com>');
                INSERT INTO message_global_data VALUES (99, '<m99@example.com>');
                INSERT INTO messages VALUES (500, 77, 23, 1000, 0, 1, 1, 2000);
                INSERT INTO messages VALUES (510, 99, 23, 3000, 0, 1, 1, 4000);
                INSERT INTO messages VALUES (601, 77, 15, 1001, 0, 1, 1, 2000);
                INSERT INTO messages VALUES (602, 77, 15, 1000, 1, 1, 1, 2000);
                INSERT INTO messages VALUES (603, 77, 21, 5000, 0, 1, 1, 2000);
                INSERT INTO messages VALUES (604, 77, 16, 1000, 0, 1, 1, 2000);
                INSERT INTO messages VALUES (605, 88, 15, 1000, 0, 1, 1, 2000);
                """, nil, nil, nil)
        }
        sqlite3_close(writer)
        let fixtureBoxes = MailStore.RescueBoxes(recovered: 23, allMail: 15, trash: 21,
                                                 accountUUID: "X", allMailPath: rescueAllMailPath)
        if let fixtureDB = try? ReadOnlyDB(path: fixture) {
            let before = fixtureDB.queryCount
            let observed = rescueObserve(db: fixtureDB, boxes: fixtureBoxes, messageHash: 77, dateSent: 1000)
            t.equal(fixtureDB.queryCount - before, 1, "snapshot: one observation runs exactly one statement")
            t.equal(observed, st([500], [601], []),
                    "snapshot: rows split per mailbox (deleted All Mail copy, other Date, INBOX and other Message-IDs ignored)")
            // apply's lookup: only the named row, only from Recovered.
            let named = (try? rescueRecoveredRows(db: fixtureDB, box: 23, id: 500, limit: 1)) ?? []
            t.equal(named.map { $0.id }, [500], "apply lookup: returns only the named Recovered row")
            t.equal(named.first?.header, "m77@example.com", "apply lookup: carries its Message-ID")
            t.equal(((try? rescueRecoveredRows(db: fixtureDB, box: 23, id: 601, limit: 1)) ?? []).count, 0,
                    "apply lookup: an id outside Recovered is not found")
            t.equal(((try? rescueRecoveredRows(db: fixtureDB, box: 23, limit: 50)) ?? []).map { $0.id }, [510, 500],
                    "dry run lookup: lists every Recovered row, newest first")
        } else {
            t.check(false, "snapshot: fixture index could not be opened")
        }
        try? FileManager.default.removeItem(atPath: fixture)
        t.check(rescueObserveSQL.contains("mailbox IN (?, ?, ?)"), "snapshot: the observation SQL covers all three mailboxes")
        t.equal(rescuePartition([(id: 500, mailbox: 23, ds: nil, deleted: false)], boxes: fixtureBoxes, dateSent: 1000),
                st(nil, [], []), "partition: an unreadable Date fails only that mailbox closed")
        t.equal(rescuePartition([(id: 503, mailbox: 21, ds: 1000, deleted: true)], boxes: fixtureBoxes, dateSent: 1000),
                st([], [], [503]), "partition: a deleted Trash copy still counts")

        // Identity: the index-side path that the script is asked to match.
        t.equal(MailStore.mailboxPath(fromURL: "imap://A4273468-266C-4001-B575-AE2F5FFF0D66/%5BGmail%5D/All%20Mail"),
                "[Gmail]/All Mail", "mailbox path: full decoded path from the index URL")
        t.equal(MailStore.mailboxPath(fromURL: "imap://A4273468-266C-4001-B575-AE2F5FFF0D66/INBOX"), "INBOX",
                "mailbox path: top-level mailbox")

        // JXA pick inside Recovered.
        js.evaluateScript(rescuePickJS)
        t.equal(evalJS("rescuePick([{id: 500, ds: 1000}], 1000, 500)"), "\"ok\"", "rescue pick: sole match is the row")
        t.equal(evalJS("rescuePick([{id: 501, ds: 1000}], 1000, 500)"), "\"mismatch\"", "rescue pick: other row refuses")
        t.equal(evalJS("rescuePick([{id: 500, ds: 1000}, {id: 501, ds: 1000}], 1000, 500)"), "\"ambiguous\"",
                "rescue pick: two matches refuse")
        t.equal(evalJS("rescuePick([{id: 500, ds: 9000}], 1000, 500)"), "\"none\"", "rescue pick: wrong Date refuses")
        t.equal(evalJS("rescuePick([{id: 500, ds: null}], 1000, 500)"), "\"unknown\"", "rescue pick: unreadable Date refuses")

        let rescueScript = mailRescueScript(jobJSON: "{}")
        let rescueParser = JSContext()!
        rescueParser.evaluateScript("var parsed = typeof (function () {\n" + rescueScript + "\n; return run; })")
        t.check(rescueParser.exception == nil,
                "mail_rescue_recovered script parses (\(rescueParser.exception?.toString() ?? "ok"))")
        t.check(rescueScript.contains("function rescuePick(") && rescueScript.contains("function fingerprintFilter("),
                "mail_rescue_recovered script embeds the tested pick")
        t.check(!rescueScript.contains("Mail.delete") && !rescueScript.contains(".delete("),
                "mail_rescue_recovered script never deletes")
        t.check(rescueScript.contains("Mail.accounts.whose({id: job.accountId})")
                    && rescueScript.contains("path === job.allMailPath")
                    && !rescueScript.contains("job.account)") && !rescueScript.contains("=== 'All Mail'"),
                "mail_rescue_recovered script pins account by id and All Mail by full path, not by name")

        try t.finish()
    }
}

private final class SelfTestRun {
    private var passed = 0
    private var failures: [String] = []

    func check(_ condition: Bool, _ label: String) {
        if condition { passed += 1 } else { failures.append(label) }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual == expected {
            passed += 1
        } else {
            failures.append("\(label) — got \(actual), expected \(expected)")
        }
    }

    func throwsError(matching predicate: (String) -> Bool, _ label: String,
                     _ body: () throws -> Void) {
        do {
            try body()
            failures.append("\(label) — expected an error, none thrown")
        } catch {
            if predicate("\(error)") {
                passed += 1
            } else {
                failures.append("\(label) — wrong error: \(error)")
            }
        }
    }

    func finish() throws {
        if failures.isEmpty {
            print("self-test: \(passed) checks passed, 0 failed")
            return
        }
        print("self-test: \(passed) checks passed, \(failures.count) FAILED:")
        for failure in failures { print("  ✗ \(failure)") }
        throw ExitCode.failure
    }
}
