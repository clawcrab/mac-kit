import Foundation

// MARK: - JavaScript string embedding
//
// Escaping strategy: every dynamic string crossing a language boundary is
// encoded as a JSON string literal (JSON is a strict subset of a JavaScript
// string literal). This is used twice per call:
//   1. page-JS payload -> embedded into the JXA driver source
//   2. user text (url/ref/text/script) -> embedded into the page-JS payload
// The JXA driver source itself is passed to /usr/bin/osascript via stdin, so
// there is no shell escaping layer at all.

func jsLiteral(_ string: String) -> String {
    guard let data = try? JSONSerialization.data(
        withJSONObject: string, options: [.fragmentsAllowed]
    ) else {
        return "\"\""
    }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - JXA runner

/// Run a JXA (JavaScript for Automation) program via `osascript -l JavaScript -`,
/// passing the source on stdin. Returns trimmed stdout, throws on nonzero exit
/// or timeout.
func runJXA(_ source: String, timeout: TimeInterval = 20) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "JavaScript", "-"]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    stdinPipe.fileHandleForWriting.write(Data(source.utf8))
    stdinPipe.fileHandleForWriting.closeFile()

    // Drain stdout/stderr on background threads so a large result can never
    // deadlock against a full pipe buffer while we wait for exit.
    var outData = Data()
    var errData = Data()
    let readGroup = DispatchGroup()
    readGroup.enter()
    DispatchQueue.global().async {
        outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        readGroup.leave()
    }
    readGroup.enter()
    DispatchQueue.global().async {
        errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        readGroup.leave()
    }

    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        process.waitUntilExit()
        exited.signal()
    }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        _ = exited.wait(timeout: .now() + 2)
        throw ToolError("osascript timed out after \(Int(timeout))s")
    }
    readGroup.wait()

    let stdout = String(decoding: outData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let stderr = String(decoding: errData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if process.terminationStatus != 0 {
        var message = stderr.isEmpty
            ? "osascript failed (exit \(process.terminationStatus))"
            : stderr
        let lower = message.lowercased()
        if lower.contains("javascript through applescript")
            || lower.contains("javascript from apple events") {
            message += "\nHint: enable Safari > Develop > Developer Settings >"
                + " \"Allow JavaScript from Apple Events\" (Develop menu itself is"
                + " enabled in Safari Settings > Advanced)."
        } else if lower.contains("not authorized") || message.contains("-1743") {
            message += "\nHint: grant this app Automation permission for Safari in"
                + " System Settings > Privacy & Security > Automation."
        }
        throw ToolError(message)
    }
    return stdout
}

// MARK: - JXA drivers

/// Driver that evaluates a page-JS payload in Safari's front document and
/// prints the result.
private func evalDriver(payload: String) -> String {
    """
    function run() {
      const Safari = Application('Safari');
      if (Safari.documents.length === 0) {
        return 'ERR: no Safari document open — use safari_open first';
      }
      const r = Safari.doJavaScript(\(jsLiteral(payload)), {in: Safari.documents[0]});
      return (r === undefined || r === null) ? '' : String(r);
    }
    """
}

// MARK: - Page-JS payloads

/// The snapshot script: walks the DOM for interactive/salient elements,
/// stores them in window.__mk.els (refs "e0", "e1", ... valid until the next
/// snapshot), and returns one compact line per element.
private let snapshotPayload = #"""
(() => {
  try {
    const cap = 150;
    const reg = [];
    const lines = [];
    const roleAttrs = new Set(['button','link','tab','checkbox','radio','combobox','menuitem','searchbox']);
    const isVisible = (el) => {
      const st = window.getComputedStyle(el);
      if (st.display === 'none' || st.visibility === 'hidden') return false;
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };
    const clean = (s) => (s || '').replace(/\s+/g, ' ').trim();
    const nameOf = (el) => {
      let n = clean(el.getAttribute('aria-label'));
      if (!n) n = clean(el.innerText);
      if (!n) n = clean(el.getAttribute('placeholder'));
      if (!n && typeof el.value === 'string') n = clean(el.value);
      if (!n) n = clean(el.getAttribute('alt'));
      if (!n) n = clean(el.getAttribute('title'));
      if (n.length > 80) n = n.slice(0, 77) + '...';
      return n;
    };
    const roleOf = (el) => {
      const ra = (el.getAttribute('role') || '').toLowerCase();
      if (ra) return ra;
      const tag = el.tagName.toLowerCase();
      if (tag === 'a') return 'link';
      if (tag === 'button') return 'button';
      if (tag === 'select') return 'combobox';
      if (tag === 'textarea') return 'textbox';
      if (tag === 'input') {
        const t = (el.type || 'text').toLowerCase();
        if (t === 'checkbox' || t === 'radio') return t;
        if (t === 'submit' || t === 'button' || t === 'image') return 'button';
        if (t === 'search') return 'searchbox';
        return 'textbox';
      }
      if (/^h[1-3]$/.test(tag)) return 'heading';
      if (el.isContentEditable) return 'textbox';
      if (el.hasAttribute('onclick')) return 'clickable';
      return 'element';
    };
    const wanted = (el) => {
      const tag = el.tagName.toLowerCase();
      if (tag === 'a') return el.hasAttribute('href');
      if (['button','input','select','textarea','h1','h2','h3'].includes(tag)) return true;
      if (roleAttrs.has((el.getAttribute('role') || '').toLowerCase())) return true;
      if (el.hasAttribute('onclick')) return true;
      if (el.isContentEditable) return true;
      return el.hasAttribute('aria-label');
    };
    const all = document.querySelectorAll(
      'a[href],button,input,select,textarea,h1,h2,h3,[role],[onclick],[contenteditable],[aria-label]'
    );
    let total = 0;
    for (const el of all) {
      if (!wanted(el) || !isVisible(el)) continue;
      total++;
      if (reg.length >= cap) continue;
      const ref = 'e' + reg.length;
      reg.push(el);
      const tag = el.tagName.toLowerCase();
      let extra = '';
      if (tag === 'a') {
        try {
          const u = new URL(el.getAttribute('href'), location.href);
          let p = u.hostname + u.pathname + u.search;
          if (p.length > 60) p = p.slice(0, 57) + '...';
          extra = p;
        } catch (e) {}
      } else if (tag === 'input' && (el.type === 'checkbox' || el.type === 'radio')) {
        extra = el.checked ? 'checked' : 'unchecked';
      } else if ((tag === 'input' || tag === 'textarea') && el.value) {
        let v = String(el.value);
        if (v.length > 40) v = v.slice(0, 37) + '...';
        extra = 'value=' + JSON.stringify(v);
      } else if (tag === 'select') {
        const o = el.selectedOptions && el.selectedOptions[0];
        if (o) extra = 'selected=' + JSON.stringify(clean(o.textContent).slice(0, 40));
      }
      lines.push('[' + ref + '] ' + roleOf(el) + ' "' + nameOf(el) + '"'
        + (extra ? ' (' + extra + ')' : ''));
    }
    window.__mk = window.__mk || {};
    window.__mk.els = reg;
    if (total > reg.length) {
      lines.push('+' + (total - reg.length) + ' more (capped at ' + cap + ')');
    }
    return lines.length ? lines.join('\n') : '(no interactive elements found)';
  } catch (e) {
    return 'ERR: snapshot failed: ' + e;
  }
})()
"""#

private let readPayload = #"""
(() => {
  try {
    const max = 8000;
    let text = ((document.body && document.body.innerText) || '').trim();
    let note = '';
    if (text.length > max) {
      note = '\n\n[truncated: showing ' + max + ' of ' + text.length + ' chars]';
      text = text.slice(0, max);
    }
    return 'Title: ' + document.title + '\nURL: ' + location.href + '\n\n' + text + note;
  } catch (e) {
    return 'ERR: read failed: ' + e;
  }
})()
"""#

private func lookupSnippet(ref: String) -> String {
    #"""
    const reg = window.__mk && window.__mk.els;
    if (!reg) return 'ERR: no element registry — run safari_snapshot first';
    const ref = \#(jsLiteral(ref));
    const m = /^e(\d+)$/.exec(ref);
    if (!m) return 'ERR: bad ref "' + ref + '" — expected a snapshot ref like "e12"';
    const el = reg[parseInt(m[1], 10)];
    if (!el) return 'ERR: ' + ref + ' not in registry (stale snapshot? re-run safari_snapshot)';
    """#
}

private func clickPayload(ref: String) -> String {
    """
    (() => {
      try {
        \(lookupSnippet(ref: ref))
        el.scrollIntoView({block: 'center'});
        el.click();
        return 'ok: clicked ' + ref;
      } catch (e) {
        return 'ERR: click failed: ' + e;
      }
    })()
    """
}

private func fillPayload(ref: String, text: String) -> String {
    """
    (() => {
      try {
        \(lookupSnippet(ref: ref))
        const text = \(jsLiteral(text));
        el.focus();
        if (el.isContentEditable) {
          el.textContent = text;
          el.dispatchEvent(new Event('input', {bubbles: true}));
        } else {
          el.value = text;
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
        }
        return 'ok: filled ' + ref;
      } catch (e) {
        return 'ERR: fill failed: ' + e;
      }
    })()
    """
}

// MARK: - Tool implementations

func safariOpenText(url: String) throws -> String {
    var target = url
    if !target.contains("://") { target = "https://" + target }
    let source = """
    function run() {
      const Safari = Application('Safari');
      const target = \(jsLiteral(target));
      // Compare URLs ignoring a trailing slash: Safari reports
      // "https://x.com/" for a "https://x.com" request.
      const norm = (u) => String(u || '').replace(/\\/+$/, '');
      if (Safari.documents.length === 0) {
        Safari.documents.push(Safari.Document());
      }
      const readDoc = () => {
        let u = '', t = '';
        try { u = String(Safari.documents[0].url() || ''); } catch (e) {}
        try { t = String(Safari.documents[0].name() || ''); } catch (e) {}
        return {u: u, t: t};
      };
      // Root cause of the old stale-page race: assigning doc.url is
      // asynchronous — the previous document (old URL/title, readyState
      // 'complete') stays in place until WebKit commits the new navigation,
      // so a bare readyState poll can "succeed" instantly against the OLD
      // page. Snapshot the pre-navigation page first, then require the
      // navigation to actually START before polling readyState.
      const before = readDoc();
      const sameTarget = norm(before.u) === norm(target);

      Safari.documents[0].url = target;

      const t0 = Date.now();
      const NAV_START_MS = 5000;      // per set-url attempt
      const SAME_URL_GRACE_MS = 1000; // same-URL reload never changes the URL
      const TOTAL_MS = 20000;

      // Phase 1: wait for navigation to start (URL or title moves away from
      // the pre-navigation snapshot). If nothing happens within 5s, re-set
      // doc.url once; if it still doesn't start, error out rather than
      // return the stale page.
      //
      // Same-URL edge case (target == already-loaded URL): the URL never
      // "changes", so after a short grace we treat navigation as started and
      // accept the current/re-requested page. Chosen over forcing
      // location.reload(): assigning doc.url already asks Safari to load the
      // target, and stacking an explicit reload on top risks a double load.
      let attempts = 1;
      while (true) {
        const now = readDoc();
        if (norm(now.u) !== norm(before.u) || now.t !== before.t) break;
        const elapsed = Date.now() - t0;
        if (sameTarget && elapsed >= SAME_URL_GRACE_MS) break;
        if (elapsed >= NAV_START_MS * attempts) {
          if (attempts === 1) {
            attempts = 2;
            Safari.documents[0].url = target;
          } else {
            return 'ERR: navigation to ' + target + ' did not start within '
              + Math.round(elapsed / 1000) + 's (page still at "' + now.u
              + '") — refusing to return the stale page. Safari may be'
              + ' blocking or ignoring the load; try again.';
          }
        }
        delay(0.1);
      }

      // Phase 2: navigation has started — now wait for the new page to
      // finish loading.
      let state = 'unknown';
      let lastErr = '';
      while (Date.now() - t0 < TOTAL_MS) {
        try {
          state = String(Safari.doJavaScript('document.readyState', {in: Safari.documents[0]}));
        } catch (e) {
          state = 'loading';
          lastErr = String(e);
        }
        if (state === 'complete') break;
        delay(0.25);
      }
      const d = Safari.documents[0];
      let out = 'URL: ' + d.url() + '\\nTitle: ' + d.name() + '\\nreadyState: ' + state;
      if (state !== 'complete' && lastErr) out += '\\n(last error while polling: ' + lastErr + ')';
      return out;
    }
    """
    return try runJXA(source, timeout: 25)
}

func safariSnapshotText() throws -> String {
    try runJXA(evalDriver(payload: snapshotPayload))
}

func safariClickText(ref: String) throws -> String {
    let source = """
    function run() {
      const Safari = Application('Safari');
      if (Safari.documents.length === 0) {
        return 'ERR: no Safari document open — use safari_open first';
      }
      const r = Safari.doJavaScript(\(jsLiteral(clickPayload(ref: ref))), {in: Safari.documents[0]});
      const result = (r === undefined || r === null) ? '' : String(r);
      if (result.indexOf('ERR') === 0) return result;
      delay(0.5);
      let state = 'unknown';
      const t0 = Date.now();
      while (Date.now() - t0 < 3000) {
        try {
          state = String(Safari.doJavaScript('document.readyState', {in: Safari.documents[0]}));
        } catch (e) {
          state = 'loading';
        }
        if (state === 'complete') break;
        delay(0.25);
      }
      const d = Safari.documents[0];
      return result + ' | readyState=' + state + ' | title=' + d.name() + ' | url=' + d.url();
    }
    """
    return try runJXA(source)
}

func safariFillText(ref: String, text: String) throws -> String {
    try runJXA(evalDriver(payload: fillPayload(ref: ref, text: text)))
}

func safariReadText() throws -> String {
    try runJXA(evalDriver(payload: readPayload))
}

func safariJSText(script: String) throws -> String {
    let payload = """
    (() => {
      try {
        const r = eval(\(jsLiteral(script)));
        return r === undefined ? 'undefined' : String(r);
      } catch (e) {
        return 'JS error: ' + e;
      }
    })()
    """
    return try runJXA(evalDriver(payload: payload))
}
