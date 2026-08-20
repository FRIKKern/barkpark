# V5 premise re-anchor + gate-inertness — wave 2b (cloud-build search-tenancy)

Anchor SHA: `origin/main` = `3ddc00a0c12a00095ba27fafe25f2d68fa38359c`
Re-derive: `git rev-parse origin/main`

## Door 1 — search_controller.ex def lines (content-anchored)
```
git show origin/main:api/lib/barkpark_web/controllers/search_controller.ex | grep -n -E 'def (create_search_synonym|promote_search_synonym|delete_search_synonym|preview_search_synonym|search_synonyms|search_insights|update_search_settings|search_settings)\b'
```
Yields: search_insights=219, search_synonyms=245, create_search_synonym=252,
promote_search_synonym=262, preview_search_synonym=275, search_settings=282,
update_search_settings=289, delete_search_synonym=313. (Wish cited 252/262/313 — MATCH.)
create/promote/preview/delete all call `Synonyms.<op>(..., workspace_id(conn))` with NO token-tenancy guard.

## Door 1 — guard source (verbatim template) + helpers
`update_search_settings` (289-311) carries the ONLY fail-closed wrapper:
`case token_workspace_id(conn) do nil -> nil_workspace_write_error(conn); _ws_id -> <upsert with workspace_id(conn)> end`
Helpers: `workspace_id/1` @456 (reads `:current_workspace`), `token_workspace_id/1` @467 (reads RAW `:api_token.workspace_id`), `nil_workspace_write_error/1` @477 (emit_custom 422 "unprocessable" — NOT 403/404).
Re-derive: `git show origin/main:api/lib/barkpark_web/controllers/search_controller.ex | sed -n '289,311p;456,481p'`

## Door 2 — flat block + settings pair + scoped twins
```
git show origin/main:api/lib/barkpark_web/router.ex | sed -n '1966,1982p;2402,2410p'
```
- settings pair @1967-1970 on `pipe_through(:search_settings_admin)` (1967).
- flat block @1974 `pipe_through([:api, :require_admin])`; six routes 1976-1981: insights(1976), synonyms GET(1977), preview(1978), synonyms POST(1979), promote(1980), delete(1981).
- scoped twins @2403-2409 `[:scoped_api, :scoped_admin]`: insights(2406), synonyms GET(2407), create POST(2408), delete(2409). **preview(1978) and promote(1980) have NO scoped twin** — GET /synonyms + GET /insights DO. (Wish's inventory WRONG; charter D81 RIGHT; vindicates REPOINT-over-twins.)

## require_admin — mintable by workspace-bound admin
`git show origin/main:api/lib/barkpark_web/plugs/require_admin.ex | sed -n '15,17p'`
Line 17: `true <- Auth.has_permission?(token, "admin")` — plain admin, NOT super-only. Halts 403 otherwise.

## Drift-gate INERT (proof, both zero)
```
grep -c -E 'synonym|insights|search_settings' docs/openapi.json          # -> 0
grep -rn -E 'search_synonym|search_insights|search_settings' api/lib/barkpark/plugins/ | wc -l   # -> 0
```
Routes are manifest-absent → a pipe_through repoint / guard copy trips NO OpenAPI drift gate. No local regen, no OOM.

## Open-PR fence DISJOINT
```
gh pr diff 9600 --patch | grep -E '^(diff|@@)'   # search_controller.ex @@ -357 (below Door1 252-321); + new test file
gh pr diff 9530 --patch | grep -E '^(diff|@@)'   # auth_controller + router.ex @@ -1553 (far above Door2 1966-1981); + new test
```
Neither touches Door 1 (252-321) nor Door 2 (1966-1981). Hunk-disjoint.

## Third bleed OUT OF SCOPE (different pipeline)
`git show origin/main:api/lib/barkpark_web/router.ex | sed -n '1727,1731p'`
`get("/search/:dataset/suggestions", ...)` @1731 sits on `pipe_through([:api, :api_grant_read])` @1728 — a PUBLIC read pipeline, distinct from BOTH `:search_settings_admin` and `[:api, :require_admin]`. suggestions.recent/anon-actor_key bleed (task-bb39315359cfc33d) is correctly excluded from wave-2b.
