# Re-derivation recipes — flagship `search` mint feasibility, search-template W10, 2026-07-26

Verifier lane: `flagship-mint-feasibility` (task stw9-backlog-flagship-identity).
The mint was RUN FOR REAL on guerrilla. The `search` site row EXISTS and was left in
place (reversible Phase-A; NOTHING was deleted — teardown is user-approval-gated).
Five deploy attempts, zero HEALTH passes. No repo code was edited by this lane.

| # | Fact | Rerun |
|---|---|---|
| 1 | `search` did not exist before the mint; `/sites/search/` was 404 | `bp cloud site status search -o json` → `{"error":{"code":"not_found",...}}` ; `curl -s -o /dev/null -w '%{http_code}' https://guerrilla.barkpark.cloud/sites/search/` → `404` |
| 2 | The mint SUCCEEDS at the control plane — site row created, port_base 7012, template+theme persisted | `bp cloud site create --name search --instance guerrilla -d default/default/production --framework nextjs --kind node --template search-starter --doc-type paper --theme ember -o json` |
| 3 | `doc_type` is absent from `site_json` for EVERY site (search, search-ember, perfect-proof, live-auto, astro-search) — corroborates stw9-backlog-doctype-readback fleet-wide | `bp cloud site status search-ember -o json \| python3 -c "import sys,json;print(json.load(sys.stdin)['site'].get('doc_type','<ABSENT>'))"` → `<ABSENT>` |
| 4 | BUILD DOES NOT STARVE on the 2-core box: 1.0G memory peak, 27.3s CPU, ~40s wall, 39M staged | `ssh root@157.180.90.121 journalctl -u 'bp-site-build-search-*' --no-pager \| grep 'Consumed'` → `Consumed 27.306s CPU time, 1.0G memory peak, 420.0K memory swap peak` |
| 5 | HEALTH fails every time; fail-closed holds — release purged, live slot untouched, no flip | `ssh root@157.180.90.121 journalctl --since '2026-07-26 16:40' --no-pager \| grep 'HEALTH gate FAILED'` |
| 6 | THREE distinct HEALTH symptoms across 5 attempts: `bp-doc-id marker is empty` (×2), `slot a on :8404 returned 308 (want 200) ... curl exit 28` (×2), CP-side `HTTP 500`/`HTTP 409` refusals | `ssh root@157.180.90.121 journalctl --since '2026-07-26 16:40' --no-pager \| grep 'BPSTAGE name=HEALTH status=failed'` |
| 7 | ROOT CAUSE is DB pool exhaustion, not build starvation: `/v1/graph` 500s dump every in-flight request at one instant with durations 2.7s–132s | `ssh root@157.180.90.121 journalctl --since '2026-07-26 16:48:30' --until '2026-07-26 16:49:30' --no-pager \| grep DBConnection` → `(DBConnection.ConnectionError) [Elixir.Barkpark.Repo] connection not available and request was dropped from queue after 513ms` |
| 8 | The search-starter SSR home page fetches the corpus graph; a graph throw renders an EMPTY `bp-doc-id`, which is exactly the gated symptom | `ssh root@157.180.90.121 journalctl --no-pager \| grep 'graph 500: unknown error'` ; also `graph 0: search API is restarting, try again in a moment` |
| 9 | THE LIVE FLAGSHIP IS AFFECTED TOO — `search-ember` build 4fea097db844bec7 failed the identical gate at the same second as the mint | `ssh root@157.180.90.121 journalctl --since '2026-07-26 16:42' --no-pager \| grep 4fea097db844bec7` → `HEALTH gate FAILED for build 4fea097db844bec7` |
| 10 | The two sites that PASSED HEALTH in the same window are astro/static (different engine, no graph fetch) — the failure tracks nextjs search-starter | `bp cloud site status perfect-proof -o json` / `live-auto` → `framework=astro kind=static` |
| 11 | search-capstone IS genuinely stale: single release dir dated Jul 16, vs ember's Jul 26 | `ssh root@157.180.90.121 ls -la /opt/barkpark/sites/search-capstone/releases/ /opt/barkpark/sites/search-ember/releases/` |
| 12 | Staleness also provable from served bytes: build-id + content-rev differ (title/size do NOT) | `curl -sL https://guerrilla.barkpark.cloud/sites/search-capstone/ \| grep -oE '<meta name="bp-(build-id\|content-rev)" content="[^"]*"'` → `b-20260716063737-stw1e` / `stw1-live-proof-5` vs ember `a7352b9caa0d3f55` / `707a5dd7c1eb` |
| 13 | search-capstone has NO `current_deployment_id` — the control plane holds no live deployment record for it | `bp cloud site status search-capstone -o json \| grep -c current_deployment_id` → `0` |
| 14 | The control plane exposes NO deploy timestamp: neither `deployment` nor `site` envelope carries one, in json OR human mode, though `deployment_json/1` server-side DOES build `became_live_at` | `bp cloud site status search-ember -o json \| python3 -c "import sys,json;print(sorted(json.load(sys.stdin)['deployment'].keys()))"` → no time key ; `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| sed -n '9672,9700p'` |
| 15 | search-ember's real last-deploy time comes only from the box: 2026-07-26 14:29:41 UTC | `ssh root@157.180.90.121 stat -c '%n %y' /opt/barkpark/sites/search-ember/releases/a7352b9caa0d3f55` |
| 16 | CP/box state DIVERGE: build 4709448c98a5fb7e was reported `failed` at BUILD by the CLI while its systemd unit kept running to a HEALTH failure 3 min later | `ssh root@157.180.90.121 systemctl list-units 'bp-site-build*' --all` (unit active after CLI reported failure) |
| 17 | `base_path` is baked into the build — the `.basepath` marker states it outright, confirming a domain attach cannot re-root a site | `ssh root@157.180.90.121 cat /opt/barkpark/sites/search/src/.basepath` → `This template bakes basePath=$BARKPARK_SITE_BASE into the build (next.config.mjs).` |
| 18 | TWO separate help strings are both incomplete, in different ways: the `bp cloud site -h` block omits `--template` AND `--theme`; the create `usage` const on origin/main lists `--template` but omits `--theme`; `parseHzArgs` accepts both | `bp cloud site -h \| grep 'site create'` ; `git show origin/main:internal/cli/cloud_site_cmd.go \| sed -n '151,152p'` |
| 19 | The token path is NOT the cause — deploy fails closed BEFORE building on a missing token, and our builds ran | `git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex \| sed -n '285,297p'` (`fail(ctx, "site read token missing or unreadable")`) |
| 20 | Slot ports are NOT derived from `port_base`: search has port_base 7012 but boots on `:8404`; ember has 7008 but runs on `:9808/:9809` | `ssh root@157.180.90.121 journalctl --no-pager \| grep "PLAN: deploy 'search' build"` → `onto slot a :8404` |
| 21 | End state: `search` row exists with no deployment, `/sites/search/` still 404, both existing sites still 200 | `curl -s -o /dev/null -w '%{http_code}' https://guerrilla.barkpark.cloud/sites/search/` → `404` ; search-ember + search-capstone → `200` |

## Ordering law for the approval-gated teardown (NOT executed)

NEVER delete before `/sites/search/` proves 200. Today it does not, so **no teardown is
eligible**. The sequence, once a mint goes live:

1. `curl -sL -o /dev/null -w '%{http_code}' https://guerrilla.barkpark.cloud/sites/search/` → must be `200`.
2. Confirm markers are real content, not a vacuous green: `bp-doc-id` and `bp-content-rev` both non-empty.
3. Surface to the lead and obtain explicit user approval — teardown is user-approval-gated.
4. Only then retire `search-capstone` (stale, no `current_deployment_id` — the safer first removal).
5. Only after `search` has served correctly for an observation window, reconcile `search-ember`.

Port note: retiring a site does not obviously free its `port_base`; the allocator picks the
lowest-free EVEN base in [7002,7998] by scanning existing rows
(`cloud/lib/barkpark_cloud/sites/node_port_allocator.ex`), so a delete + re-mint may reuse a base.
