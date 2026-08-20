# cch-w47 — ledger-sweep-and-debt-filing re-derivation recipes

Verifier lane `ledger-sweep-and-debt-filing`, wave 47 of the Cloud Console Hardening epic.
Measured 2026-08-07T14:2x UTC against `origin/main` = `8e770a08e`.
Every row below is a command that re-derives the fact from scratch. Nothing here was inferred.

Shell prelude used by every `curl`/`node` row:

```sh
export BARKPARK_SERVER=https://guerrilla.barkpark.cloud
export BARKPARK_TOKEN=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
```

## 1. All FOUR round-1 rows carry a LAPSED claim (`worker: null`) — not just `cch-w46-s2`

The wave brief said to close three of them "with the worker+epoch of the CURRENT claim" and to
re-claim only `cch-w46-s2`. There is no current claim on ANY of the four: all four leases expired
at 14:02–14:06Z and the server nulled `claim.worker` while preserving `claim.epoch` and
`claim.previous_worker`. A CAS close against a null holder fails; three silent failures were queued.

```sh
cd /Volumes/SATECHI/github/barkpark
for t in cch-w45-s5-two-member-reachable-rail-verbs-stop-selling-a-403 \
         cch-w46-s2-decommission-refusal-is-terminal \
         cch-w46-s3-unknown-authority-gets-an-exit-and-the-rail-gets-a-repaint-seam \
         cch-w46-s4-post-verdict-job-category-unblocks-the-main-failure-reporter; do
  bp task get "$t" -o json | python3 -c "
import sys,json;d=json.load(sys.stdin)['doc'];c=d.get('content') or {};cl=c.get('claim') or {}
ac=c.get('acceptance_criteria') or []
print('%-72s worker=%r epoch=%s expired=%s met=%d/%d'%(d.get('_id') or '$t',cl.get('worker'),cl.get('epoch'),cl.get('expired_at'),sum(1 for a in ac if a.get('met')),len(ac)))"
done
```

Measured:

| row | claim.worker | epoch | expired_at | criteria |
|---|---|---|---|---|
| `cch-w45-s5-two-member-reachable-rail-verbs-stop-selling-a-403` | `null` | 6 | 14:06:00.476645Z | 10/11 |
| `cch-w46-s2-decommission-refusal-is-terminal` | `null` | 8 | 14:02:00.196032Z | 8/9 |
| `cch-w46-s3-unknown-authority-gets-an-exit-and-the-rail-gets-a-repaint-seam` | `null` | 5 | 14:06:00.492622Z | 8/9 |
| `cch-w46-s4-post-verdict-job-category-unblocks-the-main-failure-reporter` | `null` | 6 | 14:06:00.505636Z | 8/9 |

`claim.previous_worker` holds the original builder id on all four and is the re-claim identity.
The N−1/N shape is real: every row's last criterion is the merge-gated one the lead owns.

All four PRs are MERGED (`gh pr view <n> --json state,mergeCommit`):
`#10343` → `8763f8d8db818a348be947f68028e199a7a3cdc3`,
`#10344` → `38d70754cb3b7c536b25fa65f5815604219dd8b2`,
`#10345` → `8472d5e6ba2ab2bc03c898422c28d4e4890fc304`,
`#10346` → `bc934ad0b0d7eb6813eeb0754f9880030d114da0`.

## 2. Roster: 581 published children, LIVE 278 — and the seal predicate cannot see 81 of them

```sh
# what the seal predicate itself asks (seal-predicate.mjs:231, limit=500, no offset)
curl -sG "$BARKPARK_SERVER/v1/data/query/production/task" \
  --data-urlencode "filter[parent_id]=cloud-console-hardening-epic" \
  --data-urlencode "limit=500" -H "Authorization: Bearer $BARKPARK_TOKEN" \
  | python3 -c "import sys,json;r=json.load(sys.stdin)['result'];print('count=%s limit=%s len=%d'%(r['count'],r['limit'],len(r['documents'])))"
# → count=500 limit=500 len=500   (count is the PAGE LENGTH, not a total — D490 confirmed)
```

Paginated truth (`limit=200`, walk `offset` until a short page):

```
PAGINATED total published children: 581   (ids unique: 581)
lifecycle: {'open': 278, 'done': 258, 'cancelled': 44, 'considering': 1}
LIVE (open||in_progress, the seal predicate's own bucket): 278
```

81 rows are invisible to the instrument. Against wave 43's recorded Law-0 opening of
**230 LIVE / 530 published** (`charter:845`) this is **+48 LIVE / +51 published** over three waves
(44, 45, 46) — the arrears the brief predicted, with the integers now derived.

`orphans` is NOT derivable today: `orphans = residue − gates − forwarded` is computed inside
clause (a), which never runs. Any wave quoting an orphan count for this epic is quoting a
hand-count, not the instrument. The brief's "orphans 276" has no instrument behind it.

## 3. The truncation refusal, run live from `origin/main` (NOT the primary checkout)

```sh
rm -rf /tmp/mainsrc && mkdir -p /tmp/mainsrc && git archive origin/main | tar -x -C /tmp/mainsrc
node /tmp/mainsrc/cloud/priv/static/__preview__/seal-predicate.mjs --successor cch-instruments-epic; echo "rc=$?"
```

```
INFRA FAULT: the roster of cloud-console-hardening-epic came back FULL — 500 rows against a page
limit of 500, and this endpoint returns no total and no hasMore. A full page cannot be told from a
complete one, so every row beyond it is invisible: clause (a) would count orphans over a population
it silently truncated and report orphans=0 as evidence. Nothing is asserted about clause (a).
VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN code=ROSTER-TRUNCATED
rc=2
```

Do NOT capture this rc through a pipe. `node … | tail` prints `rc=0` (tail's). Redirect to a file,
then read `$?`. Without `--successor` the predicate exits on `NO-SUCCESSOR` before it ever reaches
the roster, so the truncation is invisible on a bare run.

**This bug is ALREADY FILED — do not file a duplicate.** `task-35e4fa473743f866`, published, open,
parent `cch-instruments-epic`, 5 acceptance criteria, filed by wave 43 per D490
(`charter:780`: "page, never raise the limit; keep ROSTER-TRUNCATED as the fail-closed floor").

```sh
bp task get task-35e4fa473743f866 -o json
```

## 4. 32 zero-criteria LIVE rows; 8 carry `w46` — and one of them already IS the lapsed-claim row

```sh
# from the paginated roster above
python3 -c "
import json;d=json.load(open('roster.json'))
z=[x for x in d if x.get('lifecycle_status') in ('open','in_progress') and not (x.get('acceptance_criteria') or [])]
print(len(z), sum(1 for x in z if 'w46' in x['_id']))
for x in sorted(z,key=lambda y:y['_id']): print(' ',x['_id'])"
# → 32 8
```

The 8 `w46` rows include **`cch-w46-bl-lapsed-claim-arrears-close-path`** — wave 46 already filed the
close-path debt this lane was told to file. Also already filed:
`cch-w46-bl-launch-is-offered-to-a-member-who-will-be-refused` (the crown),
`cch-w46-bl-rebase-10256-and-rescue-10054-ledger-rows`,
`cch-w46-bl-breakpoint-sweep-title-is-a-five-integer-claim-that-cannot-lose`.
Three of the brief's five filing instructions are duplicates of existing rows.

Note `cch-w45-s5-fu-panel-unknown-arm-has-no-exit` is in this set — a wave-45 follow-up row with
zero criteria, distinct from the merged `cch-w45-s5-two-member-…` row.

## 5. The missing charter entry is WAVE 45, not wave 44

```sh
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md > /tmp/charter_main.md
grep -ci "wave 45" /tmp/charter_main.md          # → 1 (a single incidental mention inside D512)
grep -n "^### .*45" /tmp/charter_main.md          # → (no output): no roadmap section, no wave-log entry
grep -n "wave 44 REVIEW" /tmp/charter_main.md     # → present in the wave log
```

Wave 44's REVIEW entry IS on `origin/main`. Wave 45 has **zero** structural presence: no
`### Wave 45` roadmap section and no `### … wave 45 REVIEW` wave-log entry. The brief's
"missing wave-44 entry" is a STALE quote — it is prose written *inside* PR #10256
(`+4. **The wave-44 log entry is missing from this charter.**`), true when authored, since paid.

Wave 45's own review entry is stranded on that still-open PR. This is the
merging-charter-PR-orphans-wave-log class: wave 46's log entry absorbed wave 45's slices
(its first row is `cch-w45-s5-…` / #10343) while wave 45's section never landed.

## 6. #10256's D-numbering does NOT collide — D499–D510 were RESERVED

```sh
for n in $(seq 492 525); do grep -q "^| D$n |" /tmp/charter_main.md && printf "D%s " $n; done; echo
# → D492 D493 D494 D495 D496 D497 D498 D511 D512 D513 D514 D515 D516 D517 D518 D519 D520 D521 D522
gh pr diff 10256 | grep -o "^+| D[0-9]* |" | grep -o "[0-9]*" | tr '\n' ' '
# → 499 500 501 502 503 504 505 506 507 508 509 510
```

`origin/main` has a **hole** at D499–D510, held open deliberately by D512
("D499–D510 ARE RESERVED, NOT AVAILABLE — WAVE 46 NUMBERS FROM D511"). #10256 fills exactly that
hole. The brief's fear that "the PR's D499-D510 fall numerically INSIDE main's D492-D522" so a
`-X theirs`/`-X ours` resolve deletes one side is **half right**: the textual conflict is real
(same table region, `mergeable: CONFLICTING`, `mergeStateStatus: DIRTY`), but the numbers are
disjoint. The correct resolution is a **UNION insert into the hole between D498 and D511** — no
renumbering, no side dropped. Ceiling on main is D522, so wave 47 numbers from D523.

## 7. #9956's third consumer is real, and its pinned test is vacuously green

#9956 (OPEN) flips the no-team refusal from `422 {"error":"no_team"}` to
`403 {forbidden, reason: "no_team", scope: "team"}` in both primary-team gates.

```sh
gh pr diff 9956 | grep -n "^[+-].*no_team" | head
# -        json_halt(conn, 422, %{error: "no_team"})
# +        forbidden(conn, reason: "no_team", scope: "team")
git show origin/main:internal/cli/cloud_support_cmd.go | grep -n "no_team"
# 643:	case status == http.StatusUnprocessableEntity && supportCPErrorCode(resp) == "no_team":
```

`origin/main:internal/cli/cloud_support_cmd.go:643` is the unnamed third consumer: a Go CLI branch
keyed on `http.StatusUnprocessableEntity`. After #9956 merges the server sends 403 and this branch
goes dead — the user loses the named `bp team use` narration and falls into the generic forbidden arm.

The test that "covers" it cannot catch this:

```sh
grep -n "422 no_team" internal/cli/cloud_support_cmd_test.go
# 1117:		{"422 no_team", http.StatusUnprocessableEntity, `{"error":"no_team"}`, "bp team use", exitGeneric},
```

The table fabricates a 422 from a fake server, so it stays green while production stops sending 422.
This is a stamped-evidence-overstates case: the pin asserts the CLI's reaction to a status the
server will no longer emit. The guard that can lose must assert the status the *gate* emits, not one
the test types.
