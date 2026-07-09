import ArgumentParser
import Foundation

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
