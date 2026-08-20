# W33 — the ledger's questions become runnable, and its count becomes reproducible

Slice `dr-w33-s5-ledger-questions-become-runnable`, epic `task-fb4fb869490b4213`.
Worktree head `6d8f1f1c43`, all commands run against `origin/main` at that sha.

This file exists because a count published into a mutable task string is not a
measurement. Wave 32's act published `done 126`; the server says `done 125`. The
difference is not a rounding error, it is the reason the epic could not be shown
finished. What follows is committed so the next reader can re-run it rather than
trust it.

---

## 1. The read command, and three timestamped runs of it

```
$ date -u +%Y-%m-%dT%H:%M:%SZ
$ bp task get task-fb4fb869490b4213 -o json | python3 -c "
import json,sys,collections
ch=json.load(sys.stdin)['children']
c=collections.Counter(x['lifecycle_status'] for x in ch)
o=[x for x in ch if x['lifecycle_status'] in ('open','in_progress')]
f=[x for x in o if (x.get('criteria_progress') or {}).get('total',0)>0
                and x['criteria_progress']['met']==x['criteria_progress']['total']]
n=[x for x in o if not (x.get('criteria_progress') or {}).get('total',0)]
print('total=%d %s | openish=%d full=%d nocrit=%d GENUINE-OPEN=%d'
      % (len(ch), dict(sorted(c.items())), len(o), len(f), len(n), len(o)-len(f)-len(n)))"
```

| UTC instant | total | cancelled | done | in_progress | open | openish | 100%-met | criteria-less | **GENUINE-OPEN** |
|---|---|---|---|---|---|---|---|---|---|
| 2026-08-09T21:17:15Z | 321 | 12 | 125 | 5 | 179 | 184 | 2 | 13 | **169** |
| 2026-08-09T21:29:31Z | 324 | 18 | 128 | 5 | 173 | 178 | 0 | 13 | **165** |
| 2026-08-09T21:30:27Z | 323 | 18 | 128 | 5 | 172 | 177 | 0 | 13 | **164** |

**Every count carries its instant because the count moves under you.** Wave 33
watched three claims expire mid-read, flipping `in_progress` 3 → 0 with zero work
done. An untimestamped count is not reproducible by construction, and a count
quoted without its command is not a count at all.

The reads are fetched SERIALLY. Parallel `bp task get` triggers HTTP 429 and
writes EMPTY files, which silently truncates the population — a census taken that
way once reported 137 rows instead of 163.

### The deltas are arithmetic, not mystery

`169 → 165` (read 1 → read 2) decomposes exactly, with no residue:

| movement | Δ GENUINE-OPEN | why |
|---|---|---|
| 6 duplicate `drafts.*` rows cancelled | −6 | this slice, §3 |
| 2 rows at 100%-met closed | 0 | already excluded as `full` |
| 1 criteria-less row closed | 0 | already excluded as `nocrit` |
| 1 new row filed with criteria | +1 | `dr-w33-followup-comment-path-routing` (0/3) |
| 1 transient draft shadow | +1 | `drafts.dr-w25-s8-crown-gets-its-writer` (3/13) — see §6 |
| 1 new row filed criteria-less | 0 | `dr-w33-followup-deferral-wait-right-edge` (0/0), lands in `nocrit` |

`nocrit` holds at 13 across all three reads because the criteria-less row this
slice closed and the criteria-less row another slice filed cancel exactly.

`165 → 164` (read 2 → read 3) is one row: `drafts.dr-w25-s8-crown-gets-its-writer`,
a shadow that appeared and collapsed inside 56 seconds — see §6.

---

## 2. GENUINE-OPEN, defined lease-independently

> **GENUINE-OPEN** = (`open` ∪ `in_progress`) − rows at 100% met criteria − rows with no criteria.

The definition deliberately does not read the claim. A row reads `open` for two
completely different reasons and the lifecycle field cannot tell them apart:

- **work is outstanding** — the honest open, and the only kind that should count;
- **a claim lease lapsed** — the worker's lease expired and `worker` fell to
  `None`, so the row rolled back to `open` with all its criteria still met.

Both of the 100%-met rows in read 1 were the second kind. Subtracting them is not
generosity, it is refusing to count a timer as work.

Rows with no criteria are subtracted for the opposite reason: they are unclosable
by construction, so they can neither be proven done nor honestly counted as
remaining. There are **13** of them, and they are a disease, not a rounding
allowance — see §5.

---

## 3. The `done 126` erratum

Wave 32's `dr-w32-s7-reclaim-the-ledger-in-one-act` published, in its own now-line:

> `act complete: 52 closed / 4 cancelled / 6 discarded; gate run (300 children, open 149, done 126, cancelled 12)`

`done 126` is wrong by one. The arithmetic:

```
done at claim time   73
closes in the act   +52
                   ----
                    125       ← the server agrees: read 1, 2026-08-09T21:17:15Z, done=125
published            126       ← off by one
```

The cancelled arm reconciles **exactly**, which is what makes the `done` slip a
transcription error rather than a systematic one:

```
cancelled before   8
cancelled in act  +4
                 ----
                   12         ← read 1 says cancelled=12
```

One arm of the same sentence is exact and the other is off by one. That is the
signature of a number typed rather than read — and the whole reason this file
exists as a committed artifact instead of a task string.

---

## 4. The eight rows that rest on the PR body ALONE

These eight PRs are merged and are ancestors of `origin/main`, and each names its
slug **only** in the PR body — not in the code diff, not in the task's own stored
evidence. Delete the PR body and the link between the work and its ledger row is
gone. Verified 2026-08-09T21:31Z with `gh pr view <n> --json state,mergeCommit,body`:

| PR | merge commit | the slug, findable only in the body |
|---|---|---|
| #10350 | `a554ed967f` | `dr-w13-s5-cli-reads-columns-and-names-its-window` |
| #10565 | `ebfab89e3c` | `dr-bl-w19-console-gate-red-on-a-merged-main-commit` |
| #9727 | `9edfd15a64` | `dr-w2-s1-followup-oom-tee-flush` |
| #10942 | `531cb6502a` | `dr-w24-s1-crown-schema-stops-losing-rows` |
| #10949 | `4a48161881` | `dr-w24-s6-roster-buys-back-seal-headroom` |
| #11207 | `5f38136591` | `dr-w28-s4-the-deferral-wait-becomes-a-number` |
| #10017 | `16d47c7bfa` | `dr-w8-s4-census-reaches-a-human` |
| #11080 | `fd20408b4a` | `dr-w26-bl-deliveries-reader-two-keys-behind-11008` |

Note #11080: the row that cites it is `dr-w26-s3`, but the body names
`dr-w26-bl-…`. A scan keyed on the citing row's own slug misses it.

### The floor: why the count is an UPPER bound and never a census

The count can only ever be an upper bound on remaining work, because a merged PR
whose slug appears in no body, no commit message and no diff is findable by no
scan of any strictness — and such a PR leaves its row open forever while the work
is done.

**ERRATUM, re-derived this wave.** Wave 33's brief named **#11319** as that hard
floor: a merged PR that never names its slug. Checked directly, that is no longer
true:

```
$ gh pr view 11319 --json state,mergeCommit --jq '.state + " " + .mergeCommit.oid'
MERGED 917521fbe87883a4d7e5adc4f4cfd043d64c01f0
$ git log -1 --format='%s%n%b' 917521fbe87883a4d7e5adc4f4cfd043d64c01f0 | grep -oE 'dr-[a-z0-9-]+'
dr-w30-s2-transport-silence-gets-its-own-code
$ git merge-base --is-ancestor 917521fb origin/main && echo YES
YES
```

#11319 **does** name its slug, in the squashed merge commit body, and the row it
names reads `done 9/9`. The exemplar is stale. The argument survives without it —
an unnamed merged PR is undetectable *by definition*, so no scan can bound the
error — but the epic should not close on a floor illustrated by a case that
resolves. Recorded as an erratum rather than transcribed, because transcribing a
stale claim is precisely the failure this file is about.

---

## 5. The six unrunnable questions, made runnable

Six acceptance criteria could not be run as written. Each was re-worded, RUN, and
the output written into that criterion's own evidence field; every write was read
back from the server before moving on.

Three failure modes, and each has a rule.

**(a) Column padding.** `dr-w26-s3` #9 asked for `grep -c 'Carried \*bool'` to
return 1. It returns 0 — against completely correct code, because the struct is
column-aligned:

```
$ grep -c 'Carried \*bool' internal/cloudclient/deliveries.go          → 0
$ grep -cE 'Carried +\*bool' internal/cloudclient/deliveries.go        → 1
$ grep -nE 'Carried +\*bool' internal/cloudclient/deliveries.go
121:	Carried             *bool   `json:"carried"`
```

> **Rule: ask padding-insensitively.** `grep -cE 'X +\*Y'`, never a fixed single space.

**(b) Unscoped greps over a tree containing the charter.** `dr-w26-s6` #11 asked
`git grep -c publish_clock origin/main` to return nothing. It cannot, ever: this
epic's own charter carries 17 matching lines and nine ledger rows carry more, and
those are historical record that must not be scrubbed to make a grep green.

```
$ git grep -nE 'publish_clock' origin/main -- cloud/lib cloud/priv api/lib internal web js
(no output; rc=1)                                    ← the re-worded question, and it PASSES
```

The surviving hits under `cloud/test` are the deletion's own guard and its
register row. Their presence is the proof, not a violation.

> **Rule: path-scope to implementation trees.** Never an unscoped `git grep` over
> a tree that contains its own charter.

**(c) Prose defeating its own absence grep.** This is the sharpest one, and it
bit three separate criteria.

`dr-w26-s7` #10 asked a repo-wide absence grep to prove two keys were deleted.
Scoped even to `api/lib`, seven hits remain — four `@moduledoc` lines and three
`#` comments, *all of which document the deletion the criterion is checking for*.
The `@moduledoc` hits are inside a heredoc, so no comment filter can strip them.
The question is unanswerable without scrubbing the documentation. It was replaced
with a two-part positive proof:

```
$ git grep -n 'refute Map.has_key?(body, "build_slots")\|refute Map.has_key?(body, "runner_queue_len")' origin/main -- api/test
api/test/barkpark_web/controllers/instance_site_deploy_controller_test.exs:138:      refute Map.has_key?(body, "build_slots")
api/test/barkpark_web/controllers/instance_site_deploy_controller_test.exs:139:      refute Map.has_key?(body, "runner_queue_len")

$ git show origin/main:api/lib/barkpark_web/controllers/instance_site_deploy_controller.ex \
    | sed -n '/^  """/,$p' | grep -nE 'runner_queue_len|build_slots'
(no output; rc=1)                                    ← below the moduledoc, in real code, gone
```

`dr-w24-s7` #3 and `dr-w25-s8` #7 both demanded
`grep -n '|| true' .github/workflows/deploy.yml` return nothing. It returns three
lines:

```
63:   ... --jq '.[0].headSha' 2>/dev/null || true)"      ← the `changes` job. Legitimate.
161:  ... "https://barkpark.cloud/v1/auth/login" || true)"  ← control-plane login. Legitimate.
413:  # below. There is NO `|| true` and NO `|| echo 0` anywhere in this job — a
```

**Line 413 is a comment asserting the criterion.** The sentence written to satisfy
the check is what defeats its own command. Scoped to the job it was always about,
excluding comments, it passes:

```
$ sed -n '/^  record-delivery:/,/^  report-recorder-failure:/p' .github/workflows/deploy.yml \
    | grep -n '|| true' | grep -vE '^[0-9]+: *#'
(no output; rc=1)                                    ← record-delivery spans deploy.yml:382-985
```

`dr-w25-s8` #8 demanded the job contain no single-quoted `grep -qE`. Three exist —
`:79`, `:87`, `:157` — all in the `changes` and `control-plane` jobs, all
legitimate (two path-prefix filters and an HTTP status match). The criterion was
never about them:

```
$ sed -n '/^  record-delivery:/,/^  report-recorder-failure:/p' .github/workflows/deploy.yml \
    | grep -n "grep -qE '"
(no output; rc=1)
```

> **Rule: a deletion is proven by its refute-guard, never by a repo-wide absence
> grep.** An absence grep cannot distinguish code from the prose describing its
> removal, and the better a deletion is documented the more certainly its own
> absence check fails.

The sed-range form is used deliberately over hard line numbers: it survives the
file drifting under it, which a `NR>=382` window does not.

### Corroborating re-runs

Taken this wave on a quiet tree, not quoted from a prior report:

```
$ bash scripts/stale-verdict-watch.test.sh
  ok   an empty population exits 0 — the red is conditional, not unconditional
  ok   a nonsense assertion fails, so the greps above are load-bearing
── stale-verdict-watch: 87 passed, 0 failed ──

$ bash scripts/cloud-path-escape-check.sh --check
cloud-path-escape-check: 14 distinct repo-root read(s) resolved from cloud/lib + cloud/test
OK: every repo-root read from cloud/lib + cloud/test is dispatched on.
$ bash scripts/cloud-path-escape-check.sh --selftest      → 168 passed, 0 failed
$ printf '.github/workflows/deploy.yml\n' | bash scripts/cloud-path-escape-check.sh --match cloud
true

$ CC=/usr/bin/clang go build ./...                        → silent
$ CC=/usr/bin/clang go vet ./internal/cli/...             → silent
$ CC=/usr/bin/clang go test ./internal/cli/...
ok  github.com/FRIKKern/barkpark/internal/cli                23.637s
ok  github.com/FRIKKern/barkpark/internal/cli/cloud          (cached)
ok  github.com/FRIKKern/barkpark/internal/cli/cloud/azure    (cached)
ok  github.com/FRIKKern/barkpark/internal/cli/setup          (cached)
```

`CC=/usr/bin/clang` is load-bearing: a shell alias shadows `cc`, and without it
`runtime/cgo` fails with `error: unknown option '-E'` while the pipeline still
reports rc=0 — a green that means nothing.

**Honest correction.** The brief named six unmet-but-passing criteria. Five were
found and flipped (`dr-w24-s7` #3 #7, `dr-w25-s8` #7 #8 #10). The other two the
brief describes — the watch harness and the Go gate — are **already met** on their
rows (`dr-w30-s2` is `done 9/9`; `dr-w26-s3` #7 is met), so the true figure is
five, not six. No sixth was hunted, because finding it would need the
backlog-wide scan this slice is forbidden to run.

---

## 6. Rows discarded, rows closed, and one shadow that appeared while we watched

**Six duplicate `drafts.*` rows cancelled** (not deleted — deleting them would
destroy the 409-dedup history that explains why they exist). Each twin's state was
read from the server BEFORE the discard:

| discarded draft | its twin, verified |
|---|---|
| `drafts.dr-w26-s5-crown-gets-its-writer` | `done` 14/16 |
| `drafts.dr-w28-s2-crown-reconciler-can-say-behind-or-wrong` | `done` 8/9 |
| `drafts.dr-w28-s5-digest-deploy-health-is-per-team` | `done` 9/10 |
| `drafts.dr-w30-s6-push-dedupe-claim-gets-its-pin` | `done` 8/8 |
| `drafts.dr-w31-s1-500-names-its-fault-family` | `done` 7/7 |
| `drafts.dr-w31-s2-crown-reader-state-and-silence` | `done` 8/9 |

`drafts.dr-w26-hg-gyldendal-operator-packet-corrected` was **deliberately left
open**. It resolves to *itself* — no non-draft twin exists among the epic's
children — which is exactly what makes it the genuine 409-dedup blocker rather
than a duplicate.

**Three rows closed:**

- `dr-w28-s4-followup-payload-key-census-deferral-wait` — 3/3, lease expired
  2026-08-09T12:05:00Z with `worker=None`. Its own now-line had held it for a
  branch merge, so the hold was verified discharged before closing:
  `renderDeployDeferralWait` at `internal/cli/cloud_deploy_census_cmd.go:1041`,
  shipped by `5f38136591` (#11207), and `@emitted_floor` now `144` at
  `cloud/test/barkpark_cloud/payload_key_set_census_test.exs:863`, past the 142
  the row measured.
- `dr-w32-s7-reclaim-the-ledger-in-one-act` — 7/7, lease expired
  2026-08-09T20:01:02Z with `worker=None`. Its close reason carries the §3 erratum.
- `dr-w32-s4-followup-prove-the-first-run-path-live` — **no acceptance criteria at
  all**, so unclosable on criteria by construction. Closed citing the five live
  Actions runs that walked the whole first-run round trip: `31332605576`
  (ABSENT-FIRST-RUN), `31332716688` (PRESENT-EMPTY), `31332806984` (wrote 1
  entry), `31333052697` (loaded and retired it), `31333565555` (retired the armed
  sha, RECONCILED).

  **Let that be the last row this epic closes that way.** A criteria-less row can
  only ever be closed on prose, and 13 of them remain. The cure is a write-side
  refusal of criteria-less task creation, not a seventh backfill — the zero-criteria
  disease has regressed three times in 24 hours, which is what a backfill loop
  looks like when the write side never learns.

**One shadow, observed live.** Between read 2 and read 3, a
`drafts.dr-w25-s8-crown-gets-its-writer` row appeared in the epic's children at
3/13, counted as GENUINE-OPEN, and collapsed 56 seconds later — it is not
fetchable by `bp task get` (`not_found`) and the published row is intact and
correct. It was spawned by this slice's own `bp doc patch` + `bp doc publish`
cycle on that task. So the census has a transient term: **patching a published
task row can put a `drafts.<slug>` child into the count for the length of a
publish**. Any count read while another agent is mid-write is high by the number
of writes in flight. This is filed as its own row rather than fixed here.

---

## 7. What this file does and does not claim

It claims: the six questions now run, and their answers are pasted where the
questions live; the count has a stated command, a stated definition, three stated
instants, and a delta that decomposes without residue.

It does not claim the count is a census. §4 is the reason — the error is bounded
below by nothing, because an unnamed merged PR is invisible to every scan by
construction. **GENUINE-OPEN 164 at 2026-08-09T21:30:27Z is an upper bound on
remaining work.**

An epic should close because its numbers are boring. These are getting there:
the deltas are arithmetic, the errata are one-off transcription slips rather than
systematic drift, and the remaining disorder has exactly two named shapes —
13 criteria-less rows and a transient draft term — both with a structural cure
filed rather than a manual sweep scheduled.

---

## 8. Review addendum — the charter and this file are reconciled, exactly

Appended at wave-33 review. Two numbers looked like a contradiction between
`main` and the ledger, which is precisely what this wave exists to clear:
charter **D567 publishes `GENUINE-OPEN = 163 − 2 − 6 = 155`** (read 20:20–20:45Z)
and §1 above publishes **164–169** (read 21:17–21:30Z). Both are right, the same
command produced both, and the gap decomposes with zero residue.

### The read, re-run independently

```
2026-08-09T21:45:47Z  total=324  cancelled=18 done=128 in_progress=5 open=173
                      openish=178 full=0 nocrit=13 GENUINE-OPEN=165
```

Run from a third worktree with §1's command verbatim, it reproduces read 2
(`165`) exactly. The file is reproducible, which is the property it was written
to have.

### What the 13 criteria-less rows actually were

Seven of them were ONE row. A Decide-phase filing retried **seven times at ~45s
intervals** (20:51:23 → 20:56:26Z), and every attempt landed:

| doc_id | state before | disposition |
|---|---|---|
| `drafts.task-89df296faff8e793` | open (draft shadow) | discarded |
| `drafts.task-6d880b2b50f28b89` | open (draft shadow) | discarded |
| `drafts.task-ff1bcf58b557f27b` | open (draft shadow) | discarded |
| `drafts.task-8082dddb1b9e5a41` | open (draft shadow) | discarded |
| `drafts.task-39815714006452db` | open (draft shadow) | discarded |
| `drafts.task-19821582f6154665` | open (draft shadow) | discarded |
| `task-7aa685d254609ad1` | open, published, 0 criteria | cancelled as duplicate |

All seven carry the same subject, and the finding was re-filed **correctly** ten
minutes later as `dr-w33-bl-crown-skew-arm-has-no-epsilon` (21:06:40Z, 3
criteria, open) — that is the row to work. This is §6's draft-shadow mechanism
caught a second time, from a different write path, on a bigger burst: it is not a
one-off, and `dr-w33-fu-patch-spawns-a-counted-draft-shadow` is the right
structural cure.

### The reconciliation

```
2026-08-09T21:47:56Z  total=318  cancelled=19 done=128 in_progress=5 open=166
                      openish=171 full=0 nocrit=6 GENUINE-OPEN=165
```

`nocrit` falls **13 → 6**, which is D567's six, unchanged. The gap to D567 is then
entirely in the other two terms:

| term | D567 (20:45Z) | after this fix (21:47Z) | Δ |
|---|---|---|---|
| openish (`open ∪ in_progress`) | 163 | 171 | **+8** — rows this wave FILED (5 slices' followups + backlog) |
| − rows at 100% met | 2 | 0 | **+2** — both closed by this slice (§4) |
| − rows with no criteria | 6 | 6 | 0 |
| **GENUINE-OPEN** | **155** | **165** | **+10 = 8 + 2** |

Zero residue. **D567's 155 is not superseded and this file's number is not a
correction of it** — 155 was true at 20:45Z, 165 is true at 21:47Z, and every one
of the ten rows between them is a row this wave filed or a row this wave closed.
An epic whose count moves only by its own filings and closes is an epic whose
numbers are boring.

**The published upper bound is therefore `GENUINE-OPEN 165 at
2026-08-09T21:47:56Z`,** superseding §7's 164 (which counted the seven duplicate
rows above inside `nocrit`, so it was arithmetically right and substantively
stale). §7's caveat stands unchanged: this is an upper bound on remaining work,
never a census.
