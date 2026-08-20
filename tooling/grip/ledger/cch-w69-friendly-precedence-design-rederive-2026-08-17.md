# cch w69 — friendly() singular-detail insertion design: re-derivation recipes (2026-08-17)

Verifier: friendly-precedence-design. All facts below re-derive from origin/main's shipped
`cloud/priv/static/app.js` via the vm-harness pattern (`__bpTestHook`), plus router.ex greps.

## Baseline

- Harness green before any claim: `cd cloud/priv/static && node --test __app.test.mjs`
  → `# pass 1075 / # fail 0` (measured 2026-08-17, ~1.8s).

## Census (paren-matched, comments excluded)

- 73 real `friendly(` calls = 9 arity-1 (no fallback, throw-capable) + 64 arity-2.
  Recipe: the paren-walking script (rebuild in scratchpad; logic = strip `//` tails,
  match `friendly(`, walk parens counting top-level commas). Matches cch-w62-bl's own
  census verbatim (that row: 73 = 9 + 64, grep-count 114 includes 41 comment mentions).

## Behavior probes (node:vm sandbox identical to __app.test.mjs's header block)

1. Nested envelope `{error:{code:…}}`:
   - `friendly(nested)` (arity-1) → `TypeError: key.replace is not a function`.
   - `friendly(nested, "FB")` → `"FB"` — silent drop, no throw.
   - `nested.detail` is `undefined` (detail lives at `error.detail`, router.ex:11007),
     so a top-level `data.detail` rung NEVER fires on nested shapes — even after
     w62-bl's one-line unwrap (`key = key.code`), unless detail is hoisted too.
2. Pin test guarding the nested silent-drop as correct: `__app.test.mjs` — search
   `const nested = { error: { code: "server_error" } }` (currently :16485-16496,
   the row's :16207 has drifted).
3. `siteCreateFailureCopy` today (all via probe): unregistered slug + any status →
   `"create failed (<status>)"` — the caller fallback beats BOTH the slug-humanize
   AND the server's singular `detail`. Only `name_required` (curated) and
   `invalid`+details (ladder) render meaning. `readable_types` menu is dropped:
   client reads `data.known_templates`, server sends `readable_types`
   (router.ex:12733) — and `known_templates` is emitted only by the dwb-4 launch
   template check (router.ex:8952-8953), never by POST /v1/sites.
4. Map-shaped detail (`invalid_settings`, router.ex:7044 `detail: errors(cs)`):
   a naive rung renders `"[object Object]"`; `typeof detail === "string"` fences it.
5. Unfenced rung above the fallback BREAKS cch-w30-s5's 5xx law: probe shows
   `faultCopy(502, {error:"vercel_error", detail:"upstream 500: ECONNRESET…"})`
   flips from `"Something broke on our side…"` to the raw upstream string, because
   faultCopy passes ERRORS.server_error AS THE FALLBACK and any rung above the
   fallback outranks it by construction.
6. CLI-voiced detail class: `content_binding_required`, `no_build_source`,
   `cloudflare_*`, and `content_binding_empty` itself (router.ex:12616-12626,
   `refuse_empty_binding` embeds a literal `bp cloud site create …` re-run) all
   carry backticked CLI incantations — verbatim relay into a WEB modal is
   wrong-surface copy even where the slug is "safe".

## Re-run commands

- Probes: `node <scratchpad>/friendly_probe.mjs`, `node <scratchpad>/seam_sim.mjs`
  (rebuild from wave paper / verifier report; both are ~90-line vm sandboxes).
- Server arms: `sed -n 6873,6925p cloud/lib/barkpark_cloud/web/router.ex` (the 8
  create arms); `grep -n "detail:" cloud/lib/barkpark_cloud/web/router.ex | grep -v details`
  (singular-detail emitters); `sed -n 12616,12626p …/router.ex` (binding_empty text).
