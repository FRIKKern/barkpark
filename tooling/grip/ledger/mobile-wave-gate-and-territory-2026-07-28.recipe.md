# Re-derivation recipes — mobile chat-streaming wave: gate state, territory, fixture placement (verify, 2026-07-28)

Flight-time recheck of the sequencing facts. Every row is a single command whose
output IS the fact; nothing here is reasoned from a snapshot.

Baseline at time of run: `origin/main` = `a1583aed597a383ccfafe4de33514d4d55c70f32`
(the survey's `c69cc0b1e` is one commit stale; `a1583aed` touched only
`.claude/workflows/bp-personal-dev-fleet-charter.md`).

## R1 — main's own gate on current HEAD

```bash
cd /Volumes/SATECHI/github/barkpark && git fetch origin && git rev-parse origin/main
gh run list --branch main --limit 8 --json workflowName,conclusion,headSha,databaseId
```
On `a1583aed` only `doc-gates` + `elixir` ran (a `.claude/**` push matches no other
workflow's paths). Both `success`. The blocking aggregator `Elixir gate` is green.

## R2 — the real elixir wall clock, job by job (two data points)

```bash
gh run view 30315794114 --json workflowName,createdAt,updatedAt,jobs \
  -q '.createdAt+" -> "+.updatedAt, (.jobs[]|"\(.conclusion) \(.name) \(.startedAt)->\(.completedAt)")'
gh run view 30312040303 --json createdAt,updatedAt,jobs \
  -q '.createdAt+" -> "+.updatedAt, (.jobs[]|"\(.conclusion) \(.name) \(.startedAt)->\(.completedAt)")'
```
`30315794114` (HEAD, no queue): 23:57:04 -> 00:10:31 = **13m27s**; Test 10m33s,
Prod compile 2m29s (serial, `needs: mix-test`).
`30312040303` (prev commit, 12m of runner queue before the first job): 22:48:54 ->
23:15:49 = **26m55s**; Test 11m37s, Prod compile 2m45s.
=> the "~27 min" figure is queue-inflated. Job floor is ~13.5 min; budget 13-27 min.

## R3 — elixir has no workflow-level paths filter, by DESIGN, and never skips on push

```bash
git show origin/main:.github/workflows/elixir.yml | sed -n '25,40p'      # the skip-shim rationale
git show origin/main:.github/workflows/elixir.yml | sed -n '104,115p'    # non-PR => every path set true
```
`THIS WORKFLOW MUST NEVER GAIN A WORKFLOW-LEVEL 'on: … paths:' KEY.` Path decisions
live in the always-running `changes` dispatcher, which emits `compile=true test=true`
for any non-`pull_request` event. Confirms the survey; adds that it is deliberate.

## R4 — the Format advisory is RED ON MAIN, 94 files, none of them chat

```bash
jid=$(gh run view 30315794114 --json jobs -q '.jobs[]|select(.conclusion=="failure")|.databaseId')
gh run view --job "$jid" --log | grep -oE '(api/)?(lib|test)/[a-z_/0-9.-]+\.exs?' | sort -u | wc -l
gh run view --job "$jid" --log | grep -cE 'chat_live\.ex|chat_controller\.ex'
```
=> `94` and `0`. Pre-existing drift, advisory, not attributable to this wave — and
`mix format` on the chat files will NOT clear it.

## R5 — territory collision scan across every open PR

```bash
for pr in $(gh pr list --state open --limit 60 --json number -q '.[].number'); do
  gh pr diff "$pr" --name-only 2>/dev/null \
    | grep -Ei 'chat_live|chat_controller|internal/chat|internal/pdrender|apps/mobile|from_markdown|openapi|capabilities' \
    | sed "s|^|PR $pr |"
done
```
Total output is three lines, all PR 6426, all outside the wave's territory:
`api/lib/barkpark/plugins/capabilities.ex`,
`api/test/barkpark_web/contract/capabilities_manifest_test.exs`, `docs/openapi.json`.
=> ZERO open PRs touch chat_live.ex / chat_controller.ex / internal/chat /
internal/pdrender / apps/mobile / from_markdown.ex.

## R6 — PR 6426 is a rebase-order item, not a conflict

```bash
gh pr view 6426 --json mergeable,mergeStateStatus -q '.mergeable, .mergeStateStatus'
git show origin/main:docs/openapi.json | grep -c 'event-stream'
grep -n 'OpenAPI drift check' -A6 .github/workflows/elixir.yml
```
`MERGEABLE` / `UNSTABLE`. `docs/openapi.json` documents ZERO SSE surface
(`event-stream` count = 0), so an `event: stable` frame does not enter it. The
drift check regenerates from the manifest and fails on staleness — so the only
hazard is ORDER: land 6426 first, then rebase, or leave `capabilities.ex` and
`docs/openapi.json` untouched (which this wave should).

## R7 — branch protection 404 is the TRUE state, not a token artefact

```bash
gh api repos/FRIKKern/barkpark --jq .permissions
gh api repos/FRIKKern/barkpark/branches/main/protection
gh api repos/FRIKKern/barkpark/rulesets
```
`{"admin":true,...}` + `{"message":"Branch not protected","status":"404"}` + `[]`.
An admin token gets 404 => genuinely unprotected, and zero rulesets. Every merge
gate is convention; D37's co-ruling gate is reviewer-enforced only.

## R8 — where recorded stable-frame fixtures must live

```bash
git show origin/main:.github/workflows/mobile.yml | sed -n '36,52p'
grep -n 'internal/pdrender/testdata' scripts/elixir-path-escape-check.sh
git show origin/main:.github/workflows/go-tests.yml | sed -n '15,35p'
git show origin/main:apps/mobile/__tests__/crownFloor.test.tsx | sed -n '79,104p;199,203p'
```
`internal/pdrender/testdata/**` is the ONLY path in all three gates:
mobile.yml `paths`, go-tests.yml `paths`, and `ELIXIR_TEST_PATHS` (line 94 of the
path-escape ratchet). Precedent: `internal/pdrender/testdata/chat_golden_toolrows.json`,
imported by `apps/mobile/__tests__/chatRenderers.test.tsx:32` and read by
`internal/pdrender/chat_golden_toolrows_test.go`.

Do NOT use `api/test/support/fixtures/pd-parity/`: `crownFloor.test.tsx:92` globs
`readdirSync(FIXTURE_DIR).filter(f => f.endsWith('.golden.json'))` and :200 asserts
`BLOCK_RENDERERS[f.type] !== undefined` for every file. A frame ENVELOPE dropped
there fails the mobile gate. That dir also binds `doc-gates` via
`scripts/pd-parity-completeness.sh`.
