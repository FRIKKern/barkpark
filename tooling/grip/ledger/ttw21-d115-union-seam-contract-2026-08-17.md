# ttw21 — D115 union-seam contract re-derivation recipes (2026-08-17)

Verifier: vf-union-seam-contract. Anchors pinned against origin/main 94b12757a0.

| # | Fact | Re-derive |
|---|------|-----------|
| 1 | FetchSnapshotFull: one 30s ctx, wg.Add(2), each goroutine writes own vars, list>prime error order, composeSnapshot then syncDetails | `git show origin/main:internal/taskboard/detail_data.go \| sed -n '63,98p'` |
| 2 | composeSnapshot signature + ready overlay only upgrades open\|blocked; Counts come straight from extras.counts | `git show origin/main:internal/taskboard/fetch.go \| sed -n '58,79p'` |
| 3 | decodeTaskListFull envelope fence: `{"docs":[]}` is a legitimate empty list (err=nil) — reusable unchanged for the in_progress fetch | `git show origin/main:internal/taskboard/fetch.go \| sed -n '187,231p'` |
| 4 | isSnapshotTimeout is TYPED (url.Error.Timeout / context.DeadlineExceeded); timeout class degrades ◐/●, never ✗ (live.go applySnapshot) | `git show origin/main:internal/taskboard/live.go \| sed -n '352,400p'` and `sed -n '185,210p'` |
| 5 | Counts consumers are exactly render.go:285 (in flight), :287 (done), :335 (summed M), :347/:356 (progressPct) + board.go:321 copy | `git show origin/main:internal/taskboard/render.go \| grep -n 'Counts\['` |
| 6 | Now predicate: Claim!=nil && Worker!="" && lifecycle==in_progress over s.Tasks (union rows flow through untouched) | `git show origin/main:internal/taskboard/board.go \| sed -n '355,361p'` |
| 7 | Missing-detail reader fallback: thin best-effort from board row, never crash | `git show origin/main:internal/taskboard/program.go \| sed -n '1565,1576p'` |
| 8 | Server: lifecycle_status read OPTIONALLY (nil → identity filter), WHERE composes before the base LIMIT, collapse_twins on the same base | `git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex \| sed -n '247,302p'` + `git show origin/main:api/lib/barkpark/tasks/query.ex \| sed -n '44,60p'` |
| 9 | Live: GET /v1/tasks?lifecycle_status=in_progress&limit=1000 → 200 {ok,docs}, 15 rows all in_progress all claimed, 0.34s/125KB; prime counts in_progress=15 (no divergence TODAY — the 11v10 twin split is episodic) | `TOKEN=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])"); curl -s -H "Authorization: Bearer $TOKEN" "https://guerrilla.barkpark.cloud/v1/tasks?lifecycle_status=in_progress&limit=1000" \| python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d['docs']),{x['lifecycle_status'] for x in d['docs']})"` |
| 10 | composeSnapshot call sites (signature-change blast radius): detail_data.go:95 + board_test.go:50/:372/:567 + fetch_test.go:242/:281 — keeping the signature spares board_test | `git grep -n "composeSnapshot(" origin/main -- internal/taskboard` |
