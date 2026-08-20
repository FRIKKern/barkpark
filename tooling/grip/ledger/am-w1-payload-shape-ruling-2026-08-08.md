# Re-derivation recipes — anonymous-metering W1 payload-shape ruling (2026-08-08)

Verifier lane `payload-shape-ruling`. Baseline `origin/main` @ `5b68852f4`.
Each row re-derives a fact the four rulings stand on. The rulings themselves live
in the wave Paper; this file is only the commands.

| Fact | Rerun |
|---|---|
| Wire pin is CLOSED-WORLD: `Map.keys \|> Enum.sort == [4 keys]` at test `:41-42` — any additive key reds it; slice 1 carries ONE deliberate test edit | `git show origin/main:api/test/barkpark_web/controllers/request_stats_controller_test.exs \| sed -n '41,42p'` |
| `compute/4` computes `count` (`:130`) and returns a map WITHOUT it — the read shape today carries NO volume, so no D3-legal line is writable from it | `git show origin/main:api/lib/barkpark_web/request_stats.ex \| sed -n '130p;168,173p'` |
| dr D3 verbatim: rate over a PINNED window with VOLUME beside it, refusing below n≈200; absolute before/after counts FORBIDDEN | `git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md \| sed -n '44,47p'` |
| dr D34(b): a pinned window is reproducible only if `to` sits behind wall clock — the RequestStats monotonic ring can NEVER satisfy this (dies on restart, keys are monotonic, re-read ≠ re-query) | `git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md \| sed -n '339,350p'` |
| am charter D2 transfers dr D3 verbatim to EVERY number this epic reports | `git show origin/main:.claude/workflows/bp-anonymous-metering-charter.md \| sed -n '48,50p'` |
| `OptionalToken` on anonymous passes the conn UNTOUCHED (no assign) — assign absence cannot distinguish anon from never-covered; auth MUST derive from pipeline coverage | `git show origin/main:api/lib/barkpark_web/plugs/optional_token.ex` |
| bare `:browser` pipeline (router `:15-28`) runs NO auth plug; `:api` (`:30-47`) runs `OptionalToken`; `:api_unlimited` (`:436-441`) runs neither; `:require_token` (`:461`) runs `RequireToken` | `git show origin/main:api/lib/barkpark_web/router.ex \| sed -n '15,52p;436,478p'` |
| LiveView identity resolves on the SOCKET (`on_mount :fetch_api_token`, session-read) — never on conn.assigns at endpoint-stop; the `:lv_dead` class is structurally auth-unknown | `git show origin/main:api/lib/barkpark_web/live_auth.ex \| sed -n '105,130p'` |
| Phoenix 1.8.9 `route_info/4` returns `:pipe_through` + `:plug` and `:error` on no match — the one door to pipeline names at stop time (docstring + impl) | `sed -n '1398,1440p' api/deps/phoenix/lib/phoenix/router.ex` |
| `err_5xx_per_s` dead-key precedent: agent EXTRACTS it (`report.go:262,461`) but CP ingest reads only `req_per_s`/`p95_ms` — the beat carries a key no eye ever sees | `git show origin/main:cloud/lib/barkpark_cloud/telemetry.ex \| sed -n '115,116p'; git show origin/main:internal/agent/report.go \| sed -n '243,262p'` |
| the 5xx carriage is deploy-reliability's own OPEN row at 8/10 (lapsed claim) — W2 carriage filing must CITE `dr-w5-s2-beat-carries-load15-and-5xx`, never rebuild it | `bp task get dr-w5-s2-beat-carries-load15-and-5xx -o json` |
| router.ex meter comment block starts `:1603`; the fence grants only "router.ex pipeline bodies (D7)" — a comment edit is OUT of fence, not merely D7-sequenced | `git show origin/main:api/lib/barkpark_web/router.ex \| grep -n 'Instance machine meter'; git show origin/main:.claude/workflows/bp-anonymous-metering-charter.md \| sed -n '98,104p'` |
| cch idiom for the grant: `Wave-N widening` blocks under §Surface fence (`:123`), per-bullet "and nothing else" (D346/D357 smoke grants by READING those bullets); D397 = the foreign-charter-edit-by-line-number precedent; last D-row on origin = D616 | `git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \| grep -oE '^\| D[0-9]+' \| sed 's/\| D//' \| sort -n \| tail -1` |
| the two D8 files by exact path: `api/lib/barkpark_web/live/{bulldocs_live,finder_live}.ex`; both inside cch's fence (`api/lib/barkpark_web/live/`) | `git ls-tree -r origin/main --name-only \| grep -E 'bulldocs_live.ex\|finder_live.ex' \| grep -v test` |
| cloud robots trio (grant subject 1 must name all three): file + `only:` token at `cloud/lib/barkpark_cloud/web/router.ex:418` + pinned test — file alone 404s (proven by sibling rows `am-w1-slice2-cloud-robots-gate` §3 and `anon-metering-live-box-l1` live) | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| grep -n 'only: ~w'` |
