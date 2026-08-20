# CSP-on-304 independent second review — VERDICT (2026-08-08)

Reviewed design: D10 delete-CSP-on-304 in `paper_revision_headers.ex` (PR #10834, http-edge-truth W1 s1).
Recipe reviewed against: `csp-304-browser-retention-2026-08-08.md`. Reviewer: independent session, adversarial brief.

## VERDICT: CONFIRM-WITH-CONDITIONS

The premise ("a 304 that omits CSP leaves the stored entry's CSP enforced") is **not** Chrome-only or
spec-implied — it is **spec-mandated and source-verified in all three engines**. The wave under-sold
its own confidence.

## Spec answer — stored headers are MERGED on 304; absent = RETAINED

- RFC 9111 §3.2: the cache "MUST add each header field in the provided response to the stored
  response, replacing field values that are already present" — additive/overwriting only; **no
  delete-on-absence step exists anywhere in RFC 9111**. §4.3.4 delegates to §3.2.
- RFC 9110 §15.4.5: a server "SHOULD NOT generate representation metadata other than" six listed
  fields on a 304 — an instruction only coherent under retain semantics.
- CSP appears zero times in RFC 9111 → ordinary field. Fetch §4.6 enforces CSP from the MERGED
  cache entry (w3c/webappsec-csp#161 closed as "fetch/HTTP level").

## Per-browser evidence (source, not inference)

- **Gecko**: `nsHttpResponseHead::UpdateHeaders` loops the 304's headers onto the stored head;
  CSP not on the exclusion list. (Bugzilla 1213734.)
- **WebKit**: `updateResponseHeadersAfterRevalidation` loops validating response only; explicit
  carve-IN updates `content-security-*` when PRESENT (bug 244637, 258931@main); blanket content-
  prefix skip removed citing RFC 9111 §3.2 (bug 317250).
- **Blink**: `HttpResponseHeaders::Update()`/`MergeWithHeaders()`; CSP removed from
  kNonUpdatedHeaders in CL 1286427 (2018).
- WPT: 304-update.any.js and 304-response-should-update-csp pass on all three; **no WPT covers the
  ABSENT case** — retention rests on §3.2 + three structurally-incapable-of-deleting loops.
- No documented case of CSP lost across a 304 in any engine was found.

## Conditions (co-merged in this PR)

1. **The reader emitted NO cache-control at all** — the Chrome proof ran under a `must-revalidate`
   the production response never carried, freshness was engine-heuristic (RFC 9111 §4.2.2), and the
   reader HTML embeds per-visitor CSRF + LiveView session tokens that shared caches must never
   store. FIXED: the plug now emits `cache-control: private, max-age=0, must-revalidate` on every
   matched published-paper response (200 and 304 alike) — the same shape as
   `share_link_controller.ex:153` / `media_controller.ex:201`.
2. **The cache-control pin was vacuously green** (`[] == []`). FIXED: literal-string pins on both
   the 200 and the 304.
3. (Recommended) **Router-level scoped-route 304 test** — the scoped route's CSP-free 304 depends
   on pipeline ORDER (PaperRevisionHeaders is the last plug of `:shared_paper_browser`, halting
   before `:paper_reader_csp` mints a nonce); the only scoped test was a direct plug call that a
   pipeline reorder could silently defeat. FIXED: added in `scoped_paper_controller_test.exs`.

## Residual risk

Not the cache merge (settled). The 304 **pass-through** path — an engine handing the raw 304 to the
consumer instead of the merged entry — has precedent for OTHER headers in WebKit (bugs 319945
Content-Type, 289517 CORP) on subresource/memory-cache paths; never reported for CSP, and our case
is a top-level navigation from the disk cache. If it ever bit: page renders with no CSP — a silent
loss of the layer-2 XSS backstop with layer-1 (store-time HtmlSanitizer) still standing. Strictly
milder and less likely than the failure the design avoids (fresh-nonce CSP on a 304 permanently
killing the cached reader, invisible to curl proofs).
