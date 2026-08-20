# Re-derivation recipes — doc_type readback, three surfaces / five hunks, search-template W10, 2026-07-26

Verifier lane: `doctype-three-surface-proof` (task stw9-backlog-doctype-readback).
All edits were applied, gated, mutated, and REVERTED — origin/main is unchanged.
Probe test bodies live in the session scratchpad backup dir (NOT committed).

| # | Fact | Rerun |
|---|---|---|
| 1 | `doc_type` does not exist anywhere in `api/` router — the brief's bare `router.ex:9609-9630` means the CLOUD router | `git show origin/main:api/lib/barkpark_web/router.ex \| grep -c doc_type` → `0` |
| 2 | `site_json` (cloud router 9606-9652) serializes template + theme but NOT doc_type | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| sed -n '9606,9652p' \| grep -c doc_type` → `0` |
| 3 | doc_type IS a real column (NOT NULL default "post"), settable at create + PATCH, injected into the build env | `git grep -n doc_type origin/main -- cloud/lib cloud/priv/repo` |
| 4 | `cloudclient.SpawnSite` has no DocType field → Go silently drops the key | `git show origin/main:internal/cloudclient/client.go \| sed -n '1358,1382p'` |
| 5 | `spawnSiteStatusMap` (TABLE mode) carries neither template nor theme today | `git show origin/main:internal/cli/cloud_site_cmd.go \| sed -n '951,975p'` |
| 6 | The existing Elixir test asserts `body["site"]["theme"]` but reloads the DB for doc_type — the author worked around the missing echo | `git show origin/main:cloud/test/barkpark_cloud/web/router_sites_test.exs \| sed -n '1127,1152p'` |
| 7 | The console rail (`siteDetailHtml`) shows Framework/Theme/Repo/Port/Scale — no Content type, no Template | `git show origin/main:cloud/priv/static/app.js \| sed -n '9314,9336p'` |
| 8 | SILENT-DROP MUTATION: with site_json patched and Go untouched, the server sends doc_type and `-o json` omits it, exit 0 | apply site_json hunk only, then `CC=/usr/bin/clang go test ./internal/cli/ -run TestVerifierDocTypeReadback -v` → `JSON-MAP GAP: -o json dropped doc_type` |
| 9 | The Elixir gate is GREEN in that same broken state — it cannot catch the CLI omission | `cd cloud && CC=/usr/bin/clang MIX_ENV=test mix test test/barkpark_cloud/web/router_sites_test.exs` → `53 tests, 0 failures` |
| 10 | Removing the struct field AFTER the maps thread it is a COMPILE error, not a silent drop (the two Go hunks are order-coupled) | delete the `DocType` line, `CC=/usr/bin/clang go build ./...` → `s.DocType undefined (type cloudclient.SpawnSite has no field or method DocType)` ×3 |
| 11 | With all 5 hunks in: json carries doc_type, table shows `doc type paper` + `theme ember`, full Go suite green | `CC=/usr/bin/clang go test ./internal/cli/...` → `ok github.com/FRIKKern/barkpark/internal/cli 25.833s` |
| 12 | The console gate CAN fail: the rail assertion reds before the app.js hunk, greens after | `node cloud/priv/static/__app.test.mjs` → `# fail 1` before, `# pass 699 / # fail 0` after |
| 13 | omitempty question: `-o json` against a pre-W10 control plane ALREADY prints `"template":"","theme":""` — unconditional emission is the established convention | probe with a server body lacking the keys → `{"site":{...,"doc_type":"","template":"","theme":"",...}}` |
| 14 | Tree clean after the whole experiment | `git status --short` |
