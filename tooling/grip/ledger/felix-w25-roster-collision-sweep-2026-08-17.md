<!-- doc-tier: cold | canonical-for: felix-w25-roster-collision-sweep-recipe | budget: 1200tok -->
# Felix W25 — roster-collision-sweep re-derivation recipe (2026-08-17)

> HISTORICAL RECORD (2026-08-17) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

VERDICT: fence CLEAN, dup CLEAN, on_mount(:admin) FAIL-CLOSED. Verifier lane [roster-collision-sweep].

## (a) Per-file open-PR fence — zero collisions

30 open PRs enumerated (gh returned a full list on both attempts; never blipped empty).
Assignment carried three STALE paths; corrected on main:
- catalog.ex -> api/lib/barkpark/tenancy/workspace_bundle/catalog.ex (nested)
- staleness_live.ex -> api/lib/barkpark/plugins/onixedit/web/staleness_live.ex
- status.ex -> api/lib/barkpark/plugins/onixedit/bokbasen/status.ex

Re-derive:
```
cd /Volumes/SATECHI/github/barkpark
CANDS='tasks/board.ex|tasks/close.ex|tenancy/dataset.ex|tenancy/workspace_bundle.ex|tenancy/workspace_bundle/catalog.ex|plugins/onixedit/web/staleness_live.ex|plugins/onixedit/bokbasen/status.ex|accounts/user_notifier.ex|access/grant_notifier.ex|studio_chat/recorder.ex'
for pr in $(gh pr list --state open --limit 100 --json number --jq '.[].number'); do
  gh pr view $pr --json files --jq '.files[].path' 2>/dev/null | grep -E "$CANDS" && echo "COLLISION PR $pr"
done
```
Empty output = no roster file is open on any PR. Confirmed 2026-08-17.

## (b) Claim-level dup — no foreign open task claims a candidate fix

```
bp search query "board load_task_docs unbounded Repo.all limit LiveView"
bp search query "workspace_bundle import_member catalog allowlist guard"
bp search query "dataset slug validate_format tenancy changeset"
```
Top hits are the wave Paper + past-wave papers/tasks; NO open builder task under any
epic claims the board.ex bound, bundle guard, or dataset-slug fix. Concurrent waves
(api-read-path-security-sweep, cloud-console-hardening-w69) own read-path/console files,
none in the roster set — corroborated by the (a) PR scan returning empty.

## (c) LiveAuth.on_mount(:admin) is fail-closed

git show origin/main:api/lib/barkpark_web/live_auth.ex — :admin -> authorize/3 -> on nil
grant -> authorize_user/3. Anonymous (nil session) -> user_from_session returns nil ->
`with` first clause fails -> {:halt, redirect}. Non-admin token -> has_permission? false
-> nil -> authorize_user -> Tenancy.Auth.authorize(:admin) fails -> halt. Deny by default.
```
git show origin/main:api/lib/barkpark_web/live_auth.ex | sed -n '71,215p'
```
