# Re-derivation recipes — second-review protocol, ledger correction, live credential; search-template W10, 2026-07-26

Verifier lane: `second-review-protocol-and-ledger`. Every row is one literal command that
re-derives the fact from a primary source. Nothing here was mutated: no bp writes, no repo
edits outside this file, no DB writes (all psql is SELECT). The two `curl` probes used a
credential that is ALREADY published in plaintext in a public Barkpark task — reading it did
not widen exposure; the probe is what proves the exposure is live.

Host shorthand: `SSH="ssh -i ~/.ssh/barkpark_indx root@157.180.90.121"`,
`PSQL="sudo -u postgres psql -d barkpark_prod -At -F'|' -c"`.

| # | Fact | Rerun |
|---|---|---|
| 1 | `stw7-backlog-drafts-clamp-gap` is lifecycle `done` with all 3 criteria `met=true` | `bp task get stw7-backlog-drafts-clamp-gap -o json \| python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status']);[print(c['met'],c['criterion']) for c in d['content']['acceptance_criteria']]"` |
| 2 | The false close sentence, verbatim: "only anon + public-read-clamped are pinned" / "VERIFIED NOT A LEAK" | `bp task get stw7-backlog-drafts-clamp-gap -o json \| python3 -c "import sys,json;print(json.load(sys.stdin)['doc']['content']['close_reason'])"` |
| 3 | AC#2's evidence names `public_read_enforcement_test.exs` + `plugs/public_read_test.exs` as proving 403 — neither file makes a search request | `for f in $(git grep -l "public-read" origin/main -- api/test); do git show "$f" \| grep -q "data/search" && echo "BOTH: $f"; done` → prints nothing |
| 4 | `main` has NO branch protection ⇒ no CI check can mechanically block a merge | `gh api repos/:owner/:repo/branches/main/protection` → `{"message":"Branch not protected", "status":"404"}` |
| 5 | pr-task-gate.yml says so itself ("a red check here does not yet mechanically block a merge") | `git show origin/main:.github/workflows/pr-task-gate.yml \| sed -n '26,31p'` |
| 6 | `api/**` is in deploy.yml's push paths ⇒ merge = live | `git show origin/main:.github/workflows/deploy.yml \| sed -n '8,12p'` |
| 7 | Both W7 verifier tokens still exist and are UNREVOKED (revoked_at NULL) | `$SSH "$PSQL \"SELECT id,label,permissions,revoked_at FROM api_tokens WHERE label IN ('stw7-verify-public-read','ws-live-query-proof-verifier')\""` |
| 8 | The bearer in `stw7-backlog-revoke-verify-tokens`'s brief IS the live `stw7-verify-public-read` row: sha256(raw) == its `token_hash` | extract the 43-char base64url run from the brief, `python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" <raw>` → `057118c0…3859e`; then `$SSH "$PSQL \"SELECT label,revoked_at FROM api_tokens WHERE token_hash='057118c08cef80f0f36b81c58dd6fe854c05dbf2c25c51b83e3c1bc011d3859e'\""` |
| 9 | That published credential reads DRAFTS on guerrilla TODAY | `curl -s -H "Authorization: Bearer <raw from brief>" "https://guerrilla.barkpark.cloud/w/default/p/default/v1/data/search/production?q=the&perspective=drafts&limit=100"` → `"_draft": true`, `"_id":"drafts.…"` |
| 10 | Fail-broken oracle: same token, NO perspective → 200, count 1869, zero `_draft` rows | same curl minus `&perspective=drafts` |
| 11 | The secret survives redaction: 14 `revisions` rows + 1 `documents` row still contain it | `$SSH "$PSQL \"SELECT count(*) FROM revisions WHERE content::text ~ '<FIRST-8-CHARS-OF-THE-BEARER — read it from the task brief, never committed here>'\"" ; $SSH "$PSQL \"SELECT count(*) FROM documents WHERE content::text ~ '<FIRST-8-CHARS-OF-THE-BEARER — read it from the task brief, never committed here>'\""` |
| 12 | Fleet-wide blast radius: 25 live `{public-read}` tokens, 40 live of 122 total | `$SSH "$PSQL \"SELECT permissions,count(*) FROM api_tokens WHERE revoked_at IS NULL GROUP BY 1 ORDER BY 2 DESC\""` |
| 13 | Secret-shaped-string sweep over ALL bp documents: 8 docs carry a 43-char base64url run; the detector finds the known positive (`stw7-backlog-revoke-verify-tokens`), so it is able to fail | `$SSH "$PSQL \"SELECT d.doc_id,d.type,m[1] FROM documents d, LATERAL regexp_matches(d.content::text,'[A-Za-z0-9_-]{40,}','g') m\""` then keep runs of exactly 43 chars with upper+lower+digit and ≤3 of `-_`, dropping pure-hex |
| 14 | Only 1 of the 5 distinct candidate secrets matches a guerrilla `api_tokens` row — the other 4 are NOT cleared, they are un-triaged (control-plane / connector secrets live in a different DB) | `$SSH "$PSQL \"SELECT token_hash,label,revoked_at FROM api_tokens WHERE token_hash IN (<5 sha256s>)\""` → one row |
| 15 | There is NO revoke-by-label verb: `DELETE /v1/auth/app-tokens` takes `{"token": raw}` or `{"email": e}` only | `git show origin/main:api/lib/barkpark_web/controllers/app_token_controller.ex \| sed -n '150,186p'` |
| 16 | Revoke = set `revoked_at`; `Auth.verify_token/1` already filters revoked rows ⇒ fail-closed on next use, no read-path change | `git show origin/main:api/lib/barkpark_web/router.ex \| sed -n '816,826p'` |
| 17 | The wave log's #6216 anchor (router.ex:2373-2374) is the SCOPED mirror; the CP calls the UNSCOPED paths (1996-1997) | `git show origin/main:api/lib/barkpark_web/router.ex \| grep -n "WebhookController, :update\|WebhookController, :delete"` + `git show origin/main:cloud/lib/barkpark_cloud/registry.ex \| sed -n '4510,4512p'` |
| 18 | #6216 leg ALREADY sound (do not send a reviewer at it): PUT drops `secret` — `Webhooks.update_webhook` `Map.drop(["secret", :secret])` | `git show origin/main:api/lib/barkpark/webhooks.ex \| grep -n "def update_webhook" -A 12` |
| 19 | #6216 leg ALREADY sound: the webhook identity key carries the site UUID (`site-autodeploy-<id>`), so name collision across sites is impossible | `git show origin/main:cloud/lib/barkpark_cloud/registry.ex \| grep -n "defp content_webhook_name" -A 2` |
| 20 | #6216 leg GENUINELY UNVERIFIED: `deregister_content_webhook` is best-effort (`_ =` discarded), and its stated fallback "we can reap later (the same reconciler finds it by name)" needs a `%Site{}` that the delete has just destroyed | `git show origin/main:cloud/lib/barkpark_cloud/registry.ex \| sed -n '4463,4500p'` + `sed -n '660,666p'` |
| 21 | #6216 leg GENUINELY UNVERIFIED: `relay_admin`'s `:put`/`:delete` widening is module-wide — it applies to every caller (BoxRelay deploy/poll/rollback/teardown, `mint_public_read_token`, Deploy.content_rev_probe), not just webhooks | `git grep -n "relay_admin(" origin/main -- cloud/lib` |
| 22 | Transient: one `?perspective=published` request 500'd (`request_id GMXlA3j8hZfQEiYAhBVB`), two immediate retries 200'd — NOT a stable finding, recorded so nobody re-derives it as one | rerun the published probe from row 10 with `&perspective=published` |
