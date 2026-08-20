# CSP-on-304 browser truth — Chrome retains omitted CSP, applies fresh CSP (2026-08-08)

Verifier: csp-304-browser-truth (http-edge-truth W1, slice 1 design ruling).

## Claims proved (Chrome 151, real browser, HTTP disk cache, navigation-level document loads)

1. **A 304 carrying a FRESH-nonce CSP is applied to the cache-served body** — the stored
   body's nonced inline script is blocked (`window.__scriptRan` stays false, console logs
   `Executing inline script violates ... 'nonce-<FRESH>'`). The break is **permanent**:
   each 304 overwrites the stored entry's CSP with the newest nonce, so the script never
   runs again. This happens on ordinary navigations, not just reloads, under
   `cache-control: max-age=0, must-revalidate`. → A bare 304 downstream of PaperReaderCsp
   (which mints a fresh nonce eagerly in `call/2`) kills the reader's JS for every
   returning visitor while curl proofs stay green.
2. **A 304 that OMITS the CSP header retains the STORED response's CSP, still enforced** —
   nonced script runs (`__scriptRan: true`), un-nonced script stays blocked with a
   violation citing the ORIGINAL stored nonce. Retention survives repeated 304s.
   → delete-CSP-on-304 is safe: no security regression, no JS break.

## Re-derivation recipe (~3 min)

1. Probe server (60 lines, node, no deps): serves HTML with TWO inline scripts —
   one nonced (`window.__scriptRan=true`), one un-nonced (`window.__unrestricted=true`) —
   plus strong ETag, `cache-control: max-age=0, must-revalidate`, and
   `content-security-policy: script-src 'nonce-<N>'` (N fixed for server lifetime so the
   body/etag are stable). On If-None-Match match: `?mode=A` → 304 + fresh-nonce CSP;
   `?mode=B` → 304 with NO CSP header; `?mode=C` → always 200 (control).
   Source preserved at the wave's scratchpad: `scratchpad/csp304/server.js`
   (session 5525dc66, dir /private/tmp/claude-501/-Volumes-SATECHI-github-barkpark/).
2. `node server.js &` then in real Chrome (chrome-devtools MCP): `new_page` on
   `http://localhost:8931/?mode=A` (prime: 200, scriptRan=true, unrestricted=false,
   1 violation), `navigate_page reload` (network shows 304), `evaluate_script`
   `({scriptRan: window.__scriptRan===true, unrestricted: window.__unrestricted===true})`,
   `list_console_messages`. Repeat for mode B. Reload each a second time to test
   persistence of the header merge into the stored entry.
3. Decisive observations (verbatim excerpts):
   - Mode A reload: network `GET /?mode=A [304]`, response header
     `content-security-policy:script-src 'nonce-EJ0/AK07t4lm1oWB'` (stored body nonce
     `rd9kAQ7rxLO4YBdp`); eval → `{"scriptRan":false,"unrestricted":false}`; console:
     two `Executing inline script violates ... 'nonce-EJ0/AK07t4lm1oWB'` errors.
     Second visit (plain navigation): still 304, violations now cite a THIRD nonce
     (`bpTWcuJWohNHKU+q`) — stored CSP is overwritten every revalidation.
   - Mode B reload: network `GET /?mode=B [304]`, response headers carry etag +
     cache-control and NO content-security-policy; eval →
     `{"scriptRan":true,"unrestricted":false}`; console: one violation citing the
     ORIGINAL `'nonce-rd9kAQ7rxLO4YBdp'`. Second reload identical.
   - Mode C control: 200 both loads, `{"scriptRan":true,"unrestricted":false}`.

## Ruling consumed by Decide

Ship **delete-CSP-on-304**: the slice-1 plug's 304 halt branch must
`delete_resp_header(conn, "content-security-policy")` before `send_resp(304, "")`
(robust to plug order — `paper_reader_csp.ex:87` sets the header eagerly), pinned by an
exact-string test asserting the 304 carries NO content-security-policy header while the
200 still does. Bare 304 = permanent reader JS kill (spec-mandated by RFC 9111 §3.2
stored-header update — all conforming browsers). sha256 hashes and no-HTML-304 rejected
as needlessly large. Weak ETag + time-bucket land in the SAME PR: same plug branch, same
pins; a strong ETag over a per-request-varying body is the validator lie the epic exists
to end. Caveat: Chrome-only observation; retention semantics for Safari/Firefox are
spec-implied (headers absent from a 304 keep stored values) but unobserved.
