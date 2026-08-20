# cch wave 49 — false-open close sweep: re-derivation recipes + EXECUTION RECORD (2026-08-07)

Baseline: `origin/main` @ `9af98373d`. Epic roster: 632 children / 309 open / 265 done / 57 cancelled / 1 considering.

EXECUTED by `cch-w49-s5` against `origin/main` @ `6d80e8344`. What follows is both the recipe (so the
next sweep re-derives instead of inheriting) and the record of what was actually done.

## R1 — enumerate every partially-stamped cch-w4x row

```
bp task get cloud-console-hardening-epic -o json > /tmp/epic.json
python3 -c "
import json,re
d=json.load(open('/tmp/epic.json'))
rows=[c for c in d['children'] if re.match(r'cch-w4[0-9]',c['doc_id']) and c['lifecycle_status']=='open' and c.get('criteria_progress') and 0<c['criteria_progress']['met']<c['criteria_progress']['total']]
for c in sorted(rows,key=lambda x:x['doc_id']): print(c['doc_id'],c['criteria_progress'])
"
```
Expect 29 rows: 25 at N-1 (merge-gated clause only), 4 with a wider gap.

RE-DERIVED at execution time, not inherited: the scan returned the SAME 29 rows (wave 49's own PRs had
not yet minted new N-1 rows at 19:20Z). Re-run it anyway next time — the membership is a function of the
clock, and a stale membership list is the exact failure this sweep exists to correct.

## R2 — read the UNMET criteria and the live claim

`bp task get <id> -o json` puts criteria at `.doc.content.acceptance_criteria` and the claim at
`.doc.claim` (`epoch`, `worker`, `expired_at`, `now.text`). `worker: null` + `expired_at` in the past
== lapsed. Every one of the 29 is lapsed as of 2026-08-07T18:13Z.

```
bp task get <id> -o json | python3 -c "
import json,sys,re
d=json.load(sys.stdin)['doc']
print(d['doc_id'],d['criteria_progress'],(d.get('claim') or {}).get('epoch'),(d.get('claim') or {}).get('worker'))
for i,c in enumerate(d['content']['acceptance_criteria']):
    if not c.get('met'): print(i, re.sub(r'\s+',' ',str(c['criterion']))[:300])
"
```
Note the index printed here is 0-BASED, which is what `--criterion N` takes. The earlier version of this
recipe enumerated from 1 and would have pointed every stamp at the wrong row.

## R3 — row -> PR: the PR BODY TRAILER, not the branch and not the commit message

SUPERSEDES the branch heuristic. Every one of the 29 PRs ends its body with a machine-checkable line
`Task: <slug>`. That resolved 29/29, including the 12 rows whose `claim.now.text` is empty.

```
gh pr view <pr> --repo FRIKKern/barkpark --json body -q '.body' | grep -oE '^Task: *[a-z0-9-]+'
```

The two weaker keys and how each fails:
- **branch** (`loop-epic/…` inside `.doc.claim.now.text`, sometimes with a reviewer `-r` suffix) —
  resolved only 17/29; the other 12 rows carry an empty now-line.
- **slug in the squash commit message** — actively WRONG for at least one row. `git log origin/main
  --grep=cch-w42-s3` returns `b00d793c0` (#10252), which only MENTIONS w42-s3 in prose ("The console's
  members row (cch-w42-s3) mirrors two server laws"); #10252's own trailer is `cch-w44-s5`. w42-s3's
  real PR is #10250. A slug-grep map would have closed the wrong row on the wrong evidence.

The four mappings the survey had reached by title search alone were each confirmed by one body read:
#10124 -> `Task: cch-w41-s1-…`, #10125 -> `Task: cch-w41-s2-…`, #10250 -> `Task: cch-w42-s3-…`,
#10252 -> `Task: cch-w44-s5-…`.

## R4 — per-head gate verdict (NOT `gh run list`)

`gh run list` rolls advisory failures up as success. Read the PR head's own rollup:

```
gh pr view <pr> --repo FRIKKern/barkpark --json state,mergeable,statusCheckRollup \
  -q '"state=\(.state) mergeable=\(.mergeable) checks=\([.statusCheckRollup[]?|"\(.name)=\(.conclusion)"]|join(" "))"'
```

The instrument was proved losable BEFORE it was trusted, not after: #10154 returns
`Console gate=FAILURE` (`Overflow guard (rendered)=FAILURE`) and #10155 returns
`Console gate=FAILURE Cloud gate=FAILURE` (`Cloud path-escape ratchet=FAILURE`,
`Console path-escape ratchet=FAILURE`) — while all 25 merged heads return
`Cloud gate=SUCCESS Security gate=SUCCESS Console gate=SUCCESS Elixir gate=SUCCESS`.
A green from an instrument that has not been shown red in the same session is not evidence.

### THE RETROACTIVE LIMIT — state it, do not hide it

A MERGED PR's `statusCheckRollup` returns roughly **10 entries where an OPEN PR's returns ~35**. GitHub
does not retain the leaf check-runs against a deleted head branch. Consequences, exactly:

- The four AGGREGATE gates (`Cloud gate`, `Console gate`, `Security gate`, `Elixir gate`) survive and
  ARE provable after the fact. Every close in this sweep rests on those four and nothing else.
- Leaf jobs — `Overflow guard (rendered)`, `Cloud path-escape ratchet`, `CSSOM parity`, the advisory
  `gofmt -l`, `Format (… advisory)`, `Required-check spec drift (advisory)` — are **unauditable
  retroactively**. A post-hoc sweep cannot tell whether an advisory leaf was green, red, or skipped.
- Therefore: an advisory-leaf claim can only be honestly made from an OPEN PR. Once merged, the window
  is shut. Anyone asserting a leaf outcome about a merged PR is reading something that is not there.

## R5 — the four rows that are NOT falsely open (REFUSED, and why)

```
gh api repos/FRIKKern/barkpark/pulls/<n> --jq '"state=\(.state) mergeable=\(.mergeable) mergeable_state=\(.mergeable_state)"'
```
`mergeable` is computed lazily: the FIRST call after a base move returns `null`/`UNKNOWN`. Call twice.
`gh pr view --json mergeable` returned `UNKNOWN` for both #10085 and #10086 where the REST endpoint,
called again, returned `mergeable=false mergeable_state=dirty`.

| row | PR | state | why it stays open |
|---|---|---|---|
| `cch-w40-s3` | #10085 | OPEN, `mergeable_state=dirty` | conflicting, unmerged |
| `cch-w40-s4` | #10086 | OPEN, `mergeable_state=dirty` | conflicting, unmerged |
| `cch-w42-s2` | #10154 | OPEN | `Console gate=FAILURE` |
| `cch-w42-s4` | #10155 | OPEN | `Console gate=FAILURE`, `Cloud gate=FAILURE` |

**One inherited premise CORRECTED here.** The survey said #10085/#10086's "gates silently never run"
because the PRs are CONFLICTING. That is false as stated: both rollups are populated and both return
all four aggregate gates SUCCESS. They are honestly open for the simpler reason — they are **not
merged**, and their merge-gated criterion says "merged to main". The refusal stands; the stated reason
was wrong and is corrected rather than repeated.

## R5b — `cch-w40-s4`'s criterion named a check that does not exist

Its merge-gated criterion demanded "the Go gate green on its head". No check by that name appears in
any rollup in this repo:

```
gh pr view 10086 --repo FRIKKern/barkpark --json statusCheckRollup -q '[.statusCheckRollup[]?|.name]|join(" | ")'
```
returns 36 names whose Go-related members are exactly `gofmt -l (advisory)`, `go vet + test`,
`gofmt drift ceiling (blocking)` — plus the four aggregates. As written the criterion was unevaluable
even AFTER the PR merges. It was RE-WORDED in place (`bp doc patch task` + `bp doc publish task`, then
the stored text READ BACK — a printed `rev` is not proof a write landed) to name the two blocking Go
checks.

## R5c — three MORE conjunctive criteria found, and re-worded rather than stamped

Not in the inherited list. Three merge-gated criteria are CONJUNCTIONS whose second half a merge cannot
discharge — "…and `task-X` is closed with it" — where `task-X` is separate, unbuilt, and still open:

| row | merged PR | conjoined companion | companion state |
|---|---|---|---|
| `cch-w40-s1` | #10083 | `task-ed706f4e1c616f89` | open (console copy for the two new refusal reasons — never built) |
| `cch-w40-s5` | #10087 | `task-78c7fdb9783e3459` | open, 0/3 (post-guard cond census widening) |
| `cch-w40-s6` | #10088 | `task-fda5b6f19f1e06c9` | open, 0/2, and parented to `cch-instruments-epic`, not this epic |

Stamping these met as written would have asserted three closes that did not happen — precisely the
fabrication this sweep exists to prevent. Each was re-worded to the merge half only, with the companion
row named as still-open follow-up, then closed on the merge proof. **Rule for authors:** a merge-gated
criterion gates on the merge. Binding it to a backlog row makes the slice permanently unclosable by the
event it names.

## R6 — the census path check (the "unevaluable criteria" premise) — REFUTED

```
git ls-tree -r --name-only origin/main | grep -i census
git cat-file -e origin/main:cloud/priv/static/__binding_census.mjs && echo EXISTS
git cat-file -e origin/main:cloud/priv/static/__preview__/__binding_census.mjs || echo ABSENT
```
The "no row cites it" half needs a LEDGER scan, not just a tree check. FTS tokenizes the path, so a
bare `bp search` for it returns 17 unrelated hits and proves nothing. Bounded scan actually run: pool
the task-typed results of `bp search` over `__preview__/__binding_census.mjs`, `binding_census` and
`__binding_census.mjs` (91 distinct task docs), fetch each in full, and grep for the literal substring
`__preview__/__binding_census`. Exactly one hit — `cch-w49-s5` itself, which quotes the path only to
refute it. Labelled as bounded: it covers the 91 census-adjacent docs, not all 632 children.

No row in the epic cites `cloud/priv/static/__preview__/__binding_census.mjs`. `cch-w46-s5` #7 and
`cch-w46-s6` #7 (criterion 7, one-based — index 6 zero-based) cite bare `__binding_census.mjs`, which
resolves to the path that EXISTS. Nothing needed re-pointing. Both rows stand at 0/N, unbuilt, and were
left open — they are not false-opens, they are not-yet-started.

## R7 — closing a lapsed row without a 409, and WITHOUT grading your own homework

Every claim is lapsed and `worker` is null, so `close` on the stale epoch is the only path that can
raise `doc_changed_since_claim`. A FRESH claim recomputes `work_field_digests` from current content, so
re-claim first, then act on the new epoch. No 409 was raised in this sweep.

The non-obvious blocker: **`bp task close --set 'criteria:=[…]'` cannot flip a criterion and count it in
the same breath.** The server answers:

> acceptance criteria N (0-BASED) are not met on the task AS STORED, and criteria flipped in this very
> close command do not count — that would be the closer grading its own homework.

So the order is: **claim → `bp task stamp` each criterion → `bp task close`.** Three calls, not one.

```
bp task claim <id> <worker> -o json           # epoch at .doc.claim.epoch
bp task stamp <id> <worker> <epoch> --criterion N \
     --criterion-text "<acceptance_criteria[N].criterion, verbatim>" \
     --met --evidence "…" --merge-gated
bp task close <id> <worker> <epoch> done "…" --set 'criteria:=[{"index":N,"met":true,"criterion":"…"}]'
```

`--merge-gated` is required on the stamp because bp refuses a builder-flip of a MERGE-GATED row. Note
the guard matches the literal string `merge-gated` **anywhere** in `--criterion-text`, so a criterion
that merely DESCRIBES a merge-gated row also needs the override. Loud false positive, correct default.

## EXECUTION RECORD — 25 closed, 4 refused

Every close carries both proofs in its criterion evidence: `git merge-base --is-ancestor <sha>
origin/main` exiting 0 against `origin/main` @ `6d80e8344`, and the four aggregate gate conclusions
from the PR head.

| row | PR | merge commit | ancestry | four gates |
|---|---|---|---|---|
| cch-w40-s1 | #10083 | `209ec49fb` | rc 0 | all SUCCESS |
| cch-w40-s5 | #10087 | `8be3dedea` | rc 0 | all SUCCESS |
| cch-w40-s6 | #10088 | `c7c3b803a` | rc 0 | all SUCCESS |
| cch-w41-s1 | #10124 | `f020b0741` | rc 0 | all SUCCESS |
| cch-w41-s2 | #10125 | `f85b944c4` | rc 0 | all SUCCESS |
| cch-w41-s3 | #10126 | `a476352a4` | rc 0 | all SUCCESS |
| cch-w42-s1 | #10153 | `b2d1b0ea3` | rc 0 | all SUCCESS |
| cch-w42-s3 | #10250 | `e60acb0d4` | rc 0 | all SUCCESS |
| cch-w42-s5 | #10156 | `dad66869e` | rc 0 | all SUCCESS |
| cch-w42-s6 | #10200 | `6ddbda7c6` | rc 0 | all SUCCESS |
| cch-w43-bl-me-census-onboarding-subtree | #10251 | `39620dfd3` | rc 0 | all SUCCESS |
| cch-w43-s3 | #10201 | `f2e3283bf` | rc 0 | all SUCCESS |
| cch-w44-s5 | #10252 | `b00d793c0` | rc 0 | all SUCCESS |
| cch-w45-s1 | #10295 | `45980e8d7` | rc 0 | all SUCCESS |
| cch-w45-s2 | #10296 | `5c865f769` | rc 0 | all SUCCESS |
| cch-w45-s3 | #10297 | `5cf2b6dee` | rc 0 | all SUCCESS |
| cch-w45-s4 | #10298 | `21ad50efb` | rc 0 | all SUCCESS |
| cch-w46-s3 | #10345 | `8472d5e6b` | rc 0 | all SUCCESS |
| cch-w46-s4 | #10346 | `bc934ad0b` | rc 0 | all SUCCESS |
| cch-w47-s6 | #10449 | `fe3ed6185` | rc 0 | all SUCCESS |
| cch-w48-s1 | #10445 | `5c7299d61` | rc 0 | all SUCCESS |
| cch-w48-s2 | #10446 | `fb5ac1652` | rc 0 | all SUCCESS |
| cch-w48-s3 | #10447 | `4f2598801` | rc 0 | all SUCCESS |
| cch-w48-s4 | #10448 | `dd436fe29` | rc 0 | all SUCCESS |
| cch-w48-s7 | #10450 | `9af98373d` | rc 0 | all SUCCESS |

### The two rows stamped ONLY with a qualifying sentence

**`cch-w42-s1` criterion index 4** — TRUE on `origin/main`, NOT paid by its own PR. The criterion's own
instrument, `grep -c 'meCache.role === "owner"' cloud/priv/static/app.js`, reads **4 at `b2d1b0ea3^`
and 4 at `b2d1b0ea3`** — structurally unable to witness the change it was written for, because #10153
deliberately KEPT both compatibility floors (its body says so outright: "Criterion 4 is stamped a MISS,
not flipped green"). The payer is **#10199** (`d2a721ba2`, trailer `Task: cch-w43-s1-corpus-mints-the-
account-the-server-mints`), which killed both floors. On main today `canManageOnboarding` is
`return teamAuthorityState() === "grant";` and `membersContext` sources role from `(ta && ta.role) ||
"member"` with `|| me.role` gone. Stamped against main's state, crediting #10199.

**`cch-w42-s6` criterion index 9** — the prose half is satisfied, the ledger half is not. #10200's body
reads "This PR **promotes and closes** the filed row `cch-w40-bl-two-owner-only-billing-remedies-are-
mailed-to-every-team-member`. No second row was minted for the same defect." But that row's
`lifecycle_status` is **`cancelled`**, not `done`, and its `updated_at` is `2026-08-07T11:04:35Z` —
**2h36m AFTER** #10200 merged at `2026-08-07T08:28:33Z`. It was not closed by this merge; something
else cancelled it later. Stamped with that stated, not with "closed".

### A note on the arithmetic

Before: 29 rows. Closed: 25. Refused: 4. The after-scan must return exactly the four refusals plus any
row wave 49's own merges mint while the sweep runs — which is why R1 is re-derived, never inherited.

The after-scan, run at 19:52Z, returned exactly 4:

```
cch-w40-s3-…-2d-stops-freezing-a-live-defect        {'met': 9,  'total': 10}
cch-w40-s4-the-cli-reads-the-refusal-evidence-…     {'met': 8,  'total': 9}
cch-w42-s2-role-ladder-census-derives-its-domain    {'met': 8,  'total': 10}
cch-w42-s4-main-push-gate-failures-find-a-human     {'met': 7,  'total': 9}
```

`cch-w40-s4` still reads 8/9 after its re-word: re-wording changes the TEXT, never the met flag, so the
row correctly stays open. That is the intended behaviour — a re-word is a repair to the question, not
an answer to it.

### Filed, not silently absorbed

`cch-w49-bl-merge-gated-stamp-guard-fires-on-any-mention` (published, under this epic, priority 3):
`bp task stamp`'s `merge_gated_criterion` refusal matches the literal `merge-gated` anywhere in
`--criterion-text`, so a criterion that merely DESCRIBES a merge-gated row also needs `--merge-gated`.
Correct default, loud failure, cheap fix — anchor to the authored `MERGE-GATED` prefix. Its own
acceptance criteria demand the guard be shown to lose in BOTH directions before the fix counts.
