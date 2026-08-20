# cch-w35 verify — s6 residue re-derivation recipes (2026-08-06)

Every claim in the wave-35 verify finding `s6-residue` re-derives from the commands
below. `origin/main` = `c73bbc07c` at time of writing. The LOCAL checkout was
`a31faa52d` — BEHIND — so every read is `git show origin/main:` or an extraction,
never a worktree path.

## 0. Materialise origin/main's console (the local tree is stale)

    S=$(mktemp -d)
    git -C /Volumes/SATECHI/github/barkpark archive origin/main cloud internal deploy | tar -x -C $S

`cloud/priv/static/__unknown_census.mjs` does NOT exist in the local checkout; it
exists on `origin/main` (shipped by #9742). Running the s6 gate against the local
tree yields `MODULE_NOT_FOUND` — an absence that is an artefact of the checkout,
not of the tree. Extract `cloud internal deploy` TOGETHER: `cloud/priv/static`
alone reds 15 tests on cross-tree `readFileSync` (13 into `cloud/lib`, 2 into
`deploy/`) — those reds are extraction artefacts, not gate failures.

## 1. The s6 gate on origin/main (criteria 10 + 11)

    node --check $S/cloud/priv/static/app.js
    node $S/cloud/priv/static/__unknown_census.mjs        # exits 0, 5-site pin matches
    node $S/cloud/priv/static/__app.test.mjs | tail -8    # 873 tests, 0 fail

## 2. statusOf's Unknown branch is dead (criterion 5)

    node scratchpad/probe.mjs $S/cloud/priv/static/app.js

`probe.mjs` loads app.js in the same `vm` sandbox `__app.test.mjs` uses, then
brute-forces `statusOf` over the cross-product of the six deciding fields
(health × agent × deprovision × provision × host × suspended × update_state =
16,200 cases). `classifyBp`'s range is exactly its 8 keys; `statusOf` returns
`{role:"neutral",label:"Unknown"}` in **0** of 16,200. `statusOf(null)` and
`statusOf(undefined)` both fall to `Provisioning`, not to the neutral tail.

## 3. consoleTail's terminal promise is reachable (criterion 6)

Same probe: `instanceTimelineHtml({provision_status:"failed", host:null,
provision_console:[]})` contains `No console output yet.` — `instanceDetailHtml`
mounts the timeline on `lc.provisioning || lc.failed` (app.js:6305-6307), and
`isProvisionFailed` (:15403) is true for a terminal, host-less, failed row.

## 4. The rail for a never-reported box (criterion 1)

    node scratchpad/probe2.mjs $S/cloud/priv/static/app.js

Renders `Last seen — —` and `Created 29.6.2026, 02:00:00` beside
`Health unknown · Agent offline`. `fmtWhen` (:7810) is `!iso → "—"`; it is NOT in
`__bpTestHook`, so a criterion asserting it must go through `instanceDetailHtml`.
The in-file precedent for the honest form is `lastCheckedText(null) === "Never
checked"` (:7126).

## 5. The evidence is on the wire and discarded

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '8611,8700p' | grep -n 'unreachable\|last_seen_at\|inserted_at'
    grep -n 'unreachable_count' $S/cloud/priv/static/app.js   # → no hits

`barkpark_json/3` emits `last_seen_at`, `unreachable_count`,
`unreachable_notification_sent`, `inserted_at`. The console reads none of the
last three.

## 6. Charter phantom-by-location

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -oE '\bD3(8[2-9]|9[0-3])\b'   # → empty
    git fetch origin pull/9705/head:refs/tmp/pr9705
    git show refs/tmp/pr9705:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -oE '\bD3(8[2-9]|9[0-3])\b' | sort -u   # → D382…D393

`refs/tmp/pr9705` = `7eba91b3f99cafe7f5610929f74fe29afd0826e0` = PR #9705's
`headRefOid` (`gh pr view 9705 --json headRefOid`). s6's brief orders "READ
CHARTER D384, D385 AND D386 FIRST" — unsatisfiable from `origin/main`.

## 7. Dependency state

    bp task get cch-w34-s1-absence-is-not-an-answer -o json   # lifecycle_status: done  (PR #9742)
    bp task get cch-w34-s2-health-never-measured   -o json   # lifecycle_status: done  (PR #9739, gh issue 9711)
    bp task get cch-w34-s6-console-says-never-reported -o json # lifecycle_status: open, unclaimed (gh issue 9712)

s6 has NO server half of its own — its `files` are the three
`cloud/priv/static/*` paths only. #9739 is s2, s6's DEPENDENCY.

## 8. Live fleet premise

    bp cloud status -o json | python3 -c "import json,sys;bs=json.load(sys.stdin)['barkparks'];print(len(bs));print([b['name'] for b in bs if b['health_status']=='up' and b['agent_status']!='online'])"

6 visible rows, zero `up`+`offline`. `bp cloud status` does NOT carry
`last_seen_at`, so the NULL-heartbeat population is not measurable from the CLI —
only the `up`+`offline` half of the brief's exhibit is.
