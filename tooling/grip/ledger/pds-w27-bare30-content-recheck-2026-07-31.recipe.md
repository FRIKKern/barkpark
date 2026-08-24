<!-- doc-tier: cold | canonical-for: pds-w27-bare30-content-recheck | budget: 6000tok -->

# PDS wave 27 — re-derivation recipe: the 30 bare live rows, re-checked BY CONTENT against origin/main

Every command below is literal and re-runnable from a clean shell. The primary
checkout may sit on a foreign commit and may not carry
`scripts/pds-ledger-census.sh` at all — every read is `git show origin/main:` or
`git grep … origin/main`, never a worktree path.

## 0. Pin the population (the 30 bare live rows)

```bash
cd /Volumes/SATECHI/github/barkpark && git fetch origin main -q
# A DEDICATED scratch dir, never a bare `cd /tmp`: the census reads code relative
# to its CWD, and /tmp is the most polluted directory on the host — the shadowing
# hazard pds-w28-census-isolation fixed.
work=$(mktemp -d)
git show origin/main:scripts/pds-ledger-census.sh > "$work/c.sh"
cd "$work" && bash c.sh --json --assert-round-done --anchor-from-paper pds-wave-27-2026-07-31 > census.json 2>&1
python3 -c "import json;s=open('census.json').read();d,_=json.JSONDecoder().raw_decode(s);print('\n'.join(d['live_bare']))"
```

Observed 2026-07-31: `live_bare` = 30, `live_bare_residue` = 0, clause 3 FAIL at
15, clause 4(a) 156/186 FAIL, clause 1 `183 == 183 PASS`. `bash c.sh` exits 1.

## 1. Per-row content checks (one command per claim)

| row | command | observed |
|---|---|---|
| census-count-true | `git show origin/main:scripts/pds-ledger-census.sh \| grep -n 'limit=%d&offset=%d'` | `387:    query = "limit=%d&offset=%d"` — no `count=true`, no `perspective` |
| close-409-hint | `git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex \| sed -n '519,533p'` | body carries **top-level** `current_rev` + `changed_fields`; there is no `details` key and never was |
| close-409-hint (CLI half) | `git show origin/main:internal/cli/errors.go \| sed -n '152,160p'; git show origin/main:internal/cli/errors.go \| sed -n '173,178p'` | `canon` decodes only code/message/request_id/hint; the `{ok:false,reason}` branch decodes only `Reason` — the two fields are dropped CLIENT-side |
| publish-refusal-teaching-text | `git show origin/main:api/lib/barkpark/content/errors.ex \| sed -n '535,542p'` | `%{code: "validation_failed", status: 422, details: errors}` — the composed message IS in the envelope; same CLI `canon` struct drops it |
| cond-b non-numeric | see §2 (settled by experiment) | FAILS CLOSED |
| criteria-fence-http-pin | `git show origin/main:api/test/barkpark_web/controllers/mutate_controller_test.exs \| grep -c acceptance_criteria` | `0` |
| disposition-owner-registry | `git grep -n disposition_owner origin/main -- api/lib internal` | zero code writers; only charter prose + one test fixture + tooling scripts |
| export-close-delimited | `git show origin/main:internal/apiclient/export.go \| sed -n '86,98p'` | comment + `return scanner.Err()` unchanged |
| github-linkput-erasure | `git show origin/main:api/lib/barkpark/content/lifecycle.ex \| sed -n '292,312p'` | source states `:github` FALLS THROUGH to the fence; only `:sync` exempt |
| github-linkput (log half) | `git show origin/main:api/lib/barkpark/plugins/github/link.ex \| sed -n '191,203p'` | `Logger.warning("github link: draft-twin collapse publish for #{pid} rejected: …")` — no longer silent |
| create-image ×2 | `git grep -n hzServerPostConditionExemptions origin/main -- internal/cli` | exemption live at `hetzner_cmd.go:1099`/`:1554`; `image_id` still echoed at `:1560` |
| hzResDone vacuous | `git show origin/main:internal/cli/success_claim_registry_test.go \| sed -n '233,240p'` | still `hzResDone(out,…, nil)` with Volume{9}/{10} |
| hzResDone population | `git grep -n 'hzResDone(' origin/main -- internal/cli \| grep -v _test.go \| grep -v 'func hzResDone' \| wc -l` | `50` (charter D367 says 51) |
| os.Create sinks | `git grep -n 'os.Create(' origin/main -- internal \| grep -v _test.go` | `cloud_workspace_cmd.go:747`, `context_render.go:177`, `export_cmd.go:180` (partialPath — FIXED), `hetzner_instance_transfer_cmd.go:229`, `hetzner_storage_cmd.go:453` |
| sync bypass | `git show origin/main:api/lib/barkpark/content/lifecycle.ex \| grep -n '== :sync'` | `310:    if Keyword.get(opts, :source, :api) == :sync do` |
| tagregistry transcripts | `for f in scripts/pds-pull-proof.crown-transcript{,-w8,-w10}.txt; do git show origin/main:$f \| grep -ic 'suite-only\|unasserted\|tag_skip'; done` | `0 0 0` |
| task-create-500 | `git show origin/main:api/lib/barkpark/content/errors.ex \| sed -n '420,421p'` | a brief-less **publish** is `{:halted,…}` → 409 with a teaching message, NOT 500 — the 500 is on the CREATE leg and is not content-settleable |
| stamp silent non-land | `git show origin/main:internal/cli/tasks_stamp_cmd.go \| sed -n '166,173p;185,205p'` | read-back shipped; `renderStampVerdict` returns `exitConflict` on disagreement |
| mcp stamp bypass | `git show origin/main:internal/cli/mcp_tasks.go \| sed -n '670p'` | `return mcpRun(execManifestCommand(g, ctx, m, stampCmd, tail)), nil` |
| close/pulse read-back | `git ls-tree -r --name-only origin/main -- internal/cli \| grep tasks_.*cmd.go` | no `tasks_close_cmd.go`, no `tasks_pulse_cmd.go` — manifest dispatch only |
| close refusal taxonomy | `git show origin/main:internal/cli/errors.go \| grep -n 'criteria_unmet\|invalid_lifecycle\|sentinel_worker_id'` | `99`–`101` only — a COMMENT, not a `codeExit` row |
| api-v1 headroom | `git show origin/main:docs/api-v1.md \| wc -c` | `13998` (row's figure is CURRENT) |
| armed draft twin | `bp doc query task --fields doc_id --perspective drafts --all -o json` then filter `drafts.` | 336 draft rows; exactly one `drafts.pds*`: `drafts.pds-bl-tagregistry-guard-no-rung`; published twin still `rev 43e6314f…`, criteria met `[T,T,F,T]`, evidence `609/373/131` = 1113 B |

## 2. The one row settled BY EXPERIMENT (cond_b non-numeric floor)

`scripts/pds-pull-proof.sh:1304-1310` reproduced verbatim under `set -euo pipefail`:

```bash
cat > /tmp/condb.sh <<'EOF'
set -euo pipefail
FULL_MIN_MEM_MB="${PDS_FULL_EXPORT_MIN_MEM_MB:-2200}"
mem_mb=8000
ok=1
if [ -z "$mem_mb" ]; then cond_b="UNKNOWN"; ok=0
elif [ "$mem_mb" -ge "$FULL_MIN_MEM_MB" ]; then cond_b="OK"
else cond_b="FAILED"; ok=0
fi
echo "cond_b=$cond_b ok=$ok"
EOF
PDS_FULL_EXPORT_MIN_MEM_MB=2200 bash /tmp/condb.sh
PDS_FULL_EXPORT_MIN_MEM_MB=abc  bash /tmp/condb.sh
```

Observed:

```
cond_b=OK ok=1
/tmp/condb.sh: line 6: [: abc: integer expression expected
cond_b=FAILED ok=0
```

**It fails CLOSED**, with a stderr diagnostic. The row's worry — a silent gate
bypass in the opposite direction — does not exist.

## 3. The wave-25 shard counters, re-run from origin/main

```bash
git show origin/main:tooling/grip/ledger/pds-w25-shard-count.py > /tmp/w25c.py
git show origin/main:tooling/grip/ledger/pds-w25-board-manifest-2026-07-30.tsv > /tmp/w25m.tsv
for c in bare open-normalise parked; do python3 /tmp/w25c.py $c /tmp/w25m.tsv > /tmp/o 2>&1; echo "$c rc=$?"; tail -2 /tmp/o; done
```

Observed:

```
bare rc=1            class=bare pinned=34 COUNTED_OK=33 FAILING=1
                       FAIL pds-w12-crown-climb-preconditions disposition=''; no reason
open-normalise rc=0  class=open-normalise pinned=103 COUNTED_OK=103 FAILING=0
parked rc=0          class=parked pinned=27 COUNTED_OK=27 FAILING=0
```

Both files are ON origin/main — the three `pds-w25-round-*` briefs' "PIN FIRST
(the manifest is not on main yet — it rides charter PR #8177)" instruction is
stale.

**Never pipe a counter into `tail` inside an `&&` chain** — `rc=$?` then reports
`tail`'s status, not the counter's (this recipe's first pass did exactly that and
read `rc=0` off a script that exits 1).
