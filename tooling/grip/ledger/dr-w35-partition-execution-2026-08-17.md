# dr wave 35 — the D587/D602 open-ledger partition, EXECUTED row by row

Written by `dr-w35-s7-ledger-partition-execution` (charter D602; recipes in
`dr-w35-partition-cheap-cuts-2026-08-17.md`, riding PR #11681). Every disposition below was
taken one row at a time through the sanctioned engine verbs — `bp task claim` → `bp task
stamp` → `bp task close` with the epoch CAS. **No bulk close, no raw `/v1/data/mutate` of a
lifecycle or disposition field, and `bp task release` was never called on anything (D593).**

Execution window: `2026-08-17T07:37:30Z` (this slice's claim) → `2026-08-17T07:46Z` (last
read for this file). Repo head throughout: `4b5d802a1d5a31030f79fa4eb8d4761eb4995db2`
(`4b5d802a1d`), unchanged start to finish — verified with `git rev-parse HEAD` at both ends.

> **One honesty note on the row-level evidence strings.** The evidence stamped onto the
> individual criteria carries minute stamps of `07:45Z`–`07:52Z`, written from an estimate
> before the host clock was read. The true wall clock for the whole execution is the window
> above (`07:37:30Z`–`07:46Z`), so a few of those minute stamps run a handful of minutes
> fast. The head sha in every one of them is correct and is the load-bearing half; the
> authoritative instants are the `_updatedAt`/rev history on each task document. Recorded
> here rather than quietly corrected, because a stamp that cannot be reproduced from the
> record is exactly what this partition exists to prevent.

## The three headline numbers, RE-READ at write time

D602 fixes the doctrine: none of these is ever quoted bare, each carries its `as_of` and the
head sha it was read against. D602's own trio (191 / 189 / 184) was read at
`2026-08-17T07:08:14.959Z`. The ledger moved during this wave — six sibling slices filed and
claimed rows while this one executed — so the numbers below are **not** D602's, and that is
the point.

| # | number | reader (one command) | as_of | head |
|---|---|---|---|---|
| 1 | **343** children, **189** open (+ **8** in_progress, 132 done, 14 cancelled) | `bp task get task-fb4fb869490b4213 -o json` → `child_count` + `Counter(children[].lifecycle_status)` | `2026-08-17T07:44:29Z` | `4b5d802a1d` |
| 2 | **341** children, **187** open, `orphans=195` | `node cloud/priv/static/__preview__/seal-predicate.mjs --epic task-fb4fb869490b4213 --successor am-bl-idle-p95-anomaly --repo .` | `2026-08-17T07:44:39.345Z` (the predicate's own `read at` line) | `4b5d802a1d` (the predicate prints `head=4b5d802a1d` itself) |
| 3 | **182** = `189 open − 7 zero-criteria − 0 at-100%` | same `bp task get` payload, counted over `children[].criteria_progress` | `2026-08-17T07:44:29Z` | `4b5d802a1d` |

The predicate's verdict line, verbatim:

    VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=195 considering=0
      successor=am-bl-idle-p95-anomaly epic=task-fb4fb869490b4213 mode=live stubbed=0
      waived=0 roster=341 repo=. head=4b5d802a1d

**The doctrine demonstrating itself, in one file.** Re-running the same predicate a few minutes
later, at commit time, already reads `roster=342 … orphans=196 head=4b5d802a1d` — same head sha,
one more row, because a sibling wave-35 slice filed one in between. Nothing above is wrong and
nothing above is stale: the numbers are pinned to `07:44:39Z`. This is exactly why D602 forbids
the bare figure.

**The 343 / 341 gap is still exactly two, and still the same two rows.** `drafts.dr-w26-hg-gyldendal-operator-packet-corrected`
and `drafts.dr-w34-bl-5658-blocks-its-own-routing-fix`: the predicate's roster drops `drafts.*`,
`bp task get` keeps them. Neither reader is wrong; a bare "189" or a bare "187" is.

**Two corrections to D602's arithmetic clause, both from this read:**

1. D602 says `lifecycle_status` takes exactly one value across the live rows and that the
   `in_progress` heartbeat term is "structurally inert at 0". At `07:44:29Z` it reads **8**,
   not 0 — `dr-w33-followup-comment-path-routing`, `dr-w34-s1-coverage-envelope-window-and-sites`,
   `deploy-reliability-wave-35-log`, `dr-w35-s1`, `dr-w35-s3`, `dr-w35-s5`, `dr-w35-s6`,
   `dr-w35-s7`. The term was inert at `07:08Z` because no wave-35 builder had claimed yet.
   It is a *live-wave artefact*, not a state that never occurs, and the seal predicate agrees
   (its `orphans=195` = 187 open + 8 in_progress).
2. The deduction therefore lands on **182**, not 184: 189 open (down from 191 by the five
   dispositions below, up by rows filed mid-wave), minus the same **7** zero-criteria rows
   D602 enumerates — `dr-w25-followup-reader-blind-to-transition`,
   `dr-w27-s8-f1-seven-day-door-refuses-until-boundary-ages-out`,
   `dr-w33-followup-deferral-wait-right-edge`, `task-e2acb66e9ed0da09`,
   `task-6d1bb2843f0c91fb`, `task-a02741ad13bbf010`, `task-7a85d1b5f471af8f` — minus **0**
   at-100%-criteria rows.

## The `bp export` top-level shape assertion

D602 pins this because the partition reads the export, and the wrong reader returns silence
rather than an error.

    bp export --type task > tasks.ndjson      # 6657 documents, 57,144,070 bytes
    # task fields are TOP-LEVEL: _id, lifecycle_status, disposition, disposition_reason,
    # acceptance_criteria, title …

**Sharper than D602's wording.** D602 says `content: {}` — empty. Measured at
`2026-08-17T07:45:35Z` on the 6,657 exported rows, the `content` key is **absent
altogether** from all but **14** of them:

    CONTROL: rows carrying a `content` key at all: 14 of 6657

So `r["content"]["lifecycle_status"]` does not read an empty map — on 6,643 rows it raises,
and on a `.get("content", {})` reader it silently yields nothing at all. Either spelling of
the defect is the same trap; the assertion this file pins is the positive one: **read
`r["lifecycle_status"]`, never `r["content"]["lifecycle_status"]`.** The export also ends
with one NON-JSON trailer line that a naive `json.loads` per line trips on:

    exported 6657 documents (57144070 bytes) from default/default/production

## (a) `disposition_reason` while open — the twelve, classified

D602 counts twelve at `07:08Z`: eleven audit notes plus one genuine supersession. Re-read at
`07:45:35Z` against the live roster, **eleven** remain — because the twelfth is the
supersession, and this slice cancelled it (§(c) below). The twelve reconcile exactly.

| row | lifecycle | `disposition` | class of the reason |
|---|---|---|---|
| `dr-w10-s1-verdict-reads-the-deploy-rate` | open | `"open"` | audit note — Fleet audit 2026-08-11, PR #10129 DIRTY |
| `dr-w15-s2-graph-code-split-and-agency` | open | `"open"` | audit note — Fleet audit 2026-08-11, PR #10400 DIRTY |
| `dr-w21-s1-both-targets-assert-the-served-commit` | open | `"open"` | audit note — Fleet audit 2026-08-11, PR #10722 DIRTY |
| `dr-w21-s3-cloud-status-carries-the-commit` | open | `"open"` | audit note — Fleet audit 2026-08-11, PR #10720 DIRTY |
| `dr-w23-s4-census-table-stops-hiding` | open | `"open"` | audit note — Fleet audit 2026-08-11, PR #10811 DIRTY |
| `dr-w34-s1-coverage-envelope-window-and-sites` | **in_progress** | `"open"` | audit note — Fleet audit 2026-08-11, PR #11534 BLOCKED |
| `dr-w24-s1-crown-schema-stops-losing-rows` | open | `"open"` | audit note — WAVE-24 REVIEW 2026-08-08 |
| `dr-w24-s3-custom-host-cannot-steal-a-url` | open | `"open"` | audit note — WAVE-24 REVIEW 2026-08-08 |
| `dr-w24-s4-census-grows-a-schema-arm` | open | `"open"` | audit note — WAVE-24 REVIEW 2026-08-08 (reconciled with s2) |
| `dr-w24-s6-roster-buys-back-seal-headroom` | open | `"open"` | audit note — WAVE-24 REVIEW 2026-08-08 |
| `dr-w7-followup-deploy-follow-spins-on-deferred` | open | `"open"` | roster-headroom adoption note (charter S-4c) |
| `dr-w33-bl-crown-skew-arm-has-no-epsilon` | **cancelled by this slice** | `None` | the ONE genuine `SUPERSEDED by …` |

**One correction to the cheap-cuts breakdown.** It splits the twelve as "6 Fleet audit · 3
WAVE-24 · 1 roster-headroom · 1 SUPERSEDED" — which sums to eleven, not twelve. The measured
split is **6 Fleet-audit · 4 WAVE-24 · 1 roster-headroom · 1 supersession = 12**: the
WAVE-24 group is `dr-w24-s1`, `dr-w24-s3`, `dr-w24-s4`, `dr-w24-s6`, four rows, not three.

**And the cruel asymmetry D602 names is unchanged by the cancel.** The eleven audit-note rows
carry the literal string `disposition: "open"`; the one row a superseded-filter would want
carries `disposition: None` — and after the cancel it *still* does. `bp task get` now shows
`lifecycle_status: cancelled` for it, while `content.disposition` remains `None`. **A
disposition-keyed filter is blind to the only supersession in this epic, before and after it
was executed.** The lifecycle field is the only reader that sees it.

## (b) The five dispositions executed, each with its evidence

Every close re-RAN the row's own reworded gate command at `4b5d802a1d` and stamped the
printed output onto the criterion **before** the close. The engine refused every bare
merge-gated flip (`409 merge_gated_criterion` — "that row is the lead's to close") and each
stamp had to pass `--merge-gated` explicitly; the override was used only after reading the
criterion's actual question and answering it with a live run. That refusal is a good guard and
it fired four times here.

| row | disposition | criteria | the proof, re-run |
|---|---|---|---|
| `dr-w26-s3-deliveries-reader-stops-lying-about-carried` | **done** | 10/10 | `git show origin/main:internal/cloudclient/deliveries.go \| grep -cE 'Carried +\*bool'` = **1** (`deliveries.go:121`); forbidden single-space control `grep -c 'Carried \*bool'` = **0** (padding, never a missing field). PR #11080 MERGED `2026-08-09T02:18:45Z`. #11007 stays SUPERSEDED. |
| `dr-w26-s6-reader-less-instrument-guard-and-the-first-deletion` | **done** | 12/12 | `git grep -nE 'publish_clock' origin/main -- cloud/lib cloud/priv api/lib internal web js` = empty, **rc=1**. Unscoped control still returns 15 files (charter alone 17 lines) — why the old wording was unsatisfiable by construction. Surviving `cloud/test` hits ARE the deletion's guard + register row (`reader_less_instrument_census_test.exs:522`, `:859`, `:871`, `:880`). PR #11083 MERGED `2026-08-09T02:18:58Z`, squash `a5260f609a`. |
| `dr-w26-s7-delete-the-two-api-side-dark-instruments` | **done** | 11/11 | (i) refute-guard present: `instance_site_deploy_controller_test.exs:138` and `:139`. **The grep returns THREE hits, not two** — `:193` is a prose COMMENT quoting the guard (line begins `#`), recorded per D602 rather than swallowed. (ii) emission site below the `@moduledoc` heredoc greps clean, **rc=1**. PR #11139 MERGED `2026-08-09T09:39:38Z`, squash `8ab6d78de3`. |
| `dr-w33-s4-alarm-reaches-a-human` | **done** | 8/8 | c6 (idx 5): `gh pr view 11481 --json body -q .body \| grep -ci pages` = **0**; the criterion's second surface too — `git show origin/main:scripts/file-ci-failure-issue.sh \| grep -ciE 'pages\|paging'` = **0**, rc=1. Filed, never paged (D563). c8 (idx 7): #11481 MERGED `2026-08-09T22:04:52Z`, merge sha is the **squash `694366b62e275f0ef779b426dd8f6fc16a446ba9`**; `git merge-base --is-ancestor 694366b62e origin/main` = YES. |
| `dr-w33-bl-crown-skew-arm-has-no-epsilon` | **cancelled** | 0/5 | Superseded by `dr-w34-s3-crown-in-flight-before-skew`, citing **D584 + D599**. Re-verified materially, not on the note's word: `SERVING_SKEW_EPSILON_SECONDS=15` is live at `scripts/crown-reconcile.sh:312` with the 3s/54s derivation in the surrounding comment and the harness asserting the BAND `4 <= EPS < 54`. D599 pins the baseline at **198 passed / 0 failed** (never 192) and the direction-2 mutation at **exactly 7 reds, all section (r)**. |

**Two non-ancestor shas, one lesson, recorded twice.** `dr-w33-s4`'s own criterion warned that
its head `ded88cc82a` is not an ancestor of `origin/main` — re-tested here, `git merge-base
--is-ancestor ded88cc82a origin/main` = **NO**, and it appears in the stamped evidence only as
the sha *not* to cite. The cancelled row had the identical defect and nobody had caught it: its
`disposition_reason` names commit **`5871026758`**, and `git merge-base --is-ancestor
5871026758 origin/main` = **NO** as well. The landed sha is PR **#11536**'s squash
**`733b28cd62fa0447282a8bf291bfdb95fe418e62`**, MERGED `2026-08-10T00:50:02Z`, ancestor = YES.
The cancel reason carries the correction. **Squash-merge discards the branch commit; a row that
records its own head sha as "the merge" is recording a sha that will never be reachable.**

## (c) NOT closed — every remaining row in its named bucket

Bulk-close is forbidden (`dr-w32-fu-24-landed-rows-need-eyes` says so in its own text) and the
"25 merge-gated-only rows" is a **label** count, never a closable count. Read one at a time:

### Bucket 1 — blocked on a still-OPEN PR (7 rows)

All seven PRs re-checked OPEN at `2026-08-17T07:46Z` via one
`gh pr list --state open --limit 300 --json number,state,mergeable`:

| row | PR | PR state |
|---|---|---|
| `dr-w10-s1-verdict-reads-the-deploy-rate` (12/13) | #10129 | OPEN, **CONFLICTING** |
| `dr-w15-s2-graph-code-split-and-agency` (9/10) | #10400 | OPEN, **CONFLICTING** |
| `dr-w21-s1-both-targets-assert-the-served-commit` (10/11) | #10722 | OPEN, **CONFLICTING** |
| `dr-w21-s3-cloud-status-carries-the-commit` (8/9) | #10720 | OPEN, **CONFLICTING** |
| `dr-w23-s4-census-table-stops-hiding` (7/8) | #10811 | OPEN, **CONFLICTING** |
| `dr-w24-s3-custom-host-cannot-steal-a-url` (6/7) | #10944 | OPEN, CONFLICTING — **UNTOUCHABLE, CCH wave 68 owns its re-land (D604); two epics must not close the same PR** |
| `dr-w34-s1-coverage-envelope-window-and-sites` (8/9, in_progress) | #11534 | OPEN, MERGEABLE — wave 35's S2 is finishing it |

### Bucket 2 — MERGE-GATED label over a HUMAN-JUDGEMENT question (≥3, measured 5)

D602 warns "≥3 are human judgement wearing the prefix". Reading each criterion's actual
question rather than its prefix, **five** of the 25 ask a human to judge, not a merge to
happen. Not one of these was promoted:

| row | the criterion's actual question |
|---|---|
| `dr-w23-s7-lever-and-seal-rulings` (8/9, idx 8) | "the **owner has read** both Papers and the epic records their disposition" |
| `dr-w23-s8-ledger-closes-the-closable` (8/9, idx 8) | "the **lead reviews** the close-out list and confirms no row was closed without pasted proof" |
| `dr-w24-s6-roster-buys-back-seal-headroom` (6/8, idx 7) | "the **lead confirms** the new roster number and records the remaining headroom against 500" — and its idx 1 is real unbuilt work (derive the never-started selection rule) |
| `dr-w24-s3-custom-host-cannot-steal-a-url` (6/7, idx 6) | merged **and** "the lead records whether an **INDEPENDENT second reviewer** re-derived" it — also in bucket 1 |
| `dr-w21-s1-both-targets-assert-the-served-commit` (10/11, idx 10) | merged **and** the FIRST post-merge deploy run's sha-assertions **observed** — also in bucket 1 |

### Bucket 3 — waits on another wave-35 slice's merge (1 row, LEAD closes after)

`dr-w33-bl-crown-schedule-has-never-run-the-reconcile` — 0/4, and closable in substance: its
c1/c2/c4 are satisfied by run ids already on the board (schedule run `32003613747` GREEN at
`2026-08-17T06:55Z`; 19 schedule successes / 13 failures; the reds fail AT the verdict on an
empty population, not at the harness). But **c3 asks the reconciling path to CLOSE issue
#11217**, and #11217 is still **OPEN with 41 comments, last `2026-08-17T06:32:57Z`** (`gh issue
view 11217`). That close is gated on `dr-w35-s3`'s merge and is a human act — no auto-close
path exists in `scripts/file-ci-failure-issue.sh`. **The LEAD closes this row after S3 merges
and #11217 is closed.** Cancelling it would misrecord: the premise was true when filed and the
row's job — watch one — was done.

### Bucket 4 — human/ops gate, not a merge (3 rows + 1 draft)

| row | the gate |
|---|---|
| `dr-w8-s4-census-reaches-a-human` (8/10) | idx 8 is **OPS-GATED**: `PLATFORM_ADMIN_EMAILS` set on the SERVING control-plane container to a registered Cloud identity. Still unset (the standing CROWN DARK). idx 9 is the merge. |
| `dr-w25-hg-gyldendal-operator-stops-the-transmission` (0/4) | a third party's live row must be repointed and a transmitted instance-admin token ROTATED — an operator act on someone else's tenant |
| `dr-w33-hg-owner-subscribes-to-the-repository` (0/3) | the owner's repo subscription, plus a verified mail path — `gh repo view --json viewerSubscription` is the oracle and the owner is the only actor |
| `drafts.dr-w26-hg-gyldendal-operator-packet-corrected` (0/5) | the fourth `-hg-`, still a draft: in `bp task get`'s roster, absent from the predicate's |

**These are the epic's `-hg-` rows and NOTHING PRINTS THEM AS GATES.**
`PERMANENT_HUMAN_GATES` in `seal-predicate.mjs` is a hardcoded three-entry literal —
`gr-ops-platform-admin-emails`, `gr-backlog-qr-live-scan-proof`,
`cch-hg-compose-network-recreation`, all three `parent=cloud-console-hardening-epic
in-epic-roster=false` — and the live run at `07:44:39Z` printed `permanent human gate : 0`
for this epic while counting **195** rows as UNNAMED RESIDUE. `scripts/deploy-reliability-exit-run.sh`
has no gate table at all. **"Human gates stated as human gates" has no printer in either
instrument; this paragraph is the printer.**

### Bucket 5 — GROUP B, reword-not-close (D568)

D568's reword landed as `dr-w33-s5` and every reworded command passes on today's tip. The six
reworded criteria sit on **five** rows; three of those rows had the reword as their only unmet
criterion and are the three closed in §(b). The other two stay open because their *unreworded*
criteria are genuinely unbuilt:

| row | criteria | why it stays open |
|---|---|---|
| `dr-w24-s7-crown-gets-its-writer` | **2/9** | the reworded `\|\| true` criterion (idx 3) is already met; idx 0/1/2/4/5/6 are the unwritten recorder job itself, idx 8 is a merge ordered after #10722 |
| `dr-w25-s8-crown-gets-its-writer` | **3/13** | reworded idx 7 and idx 8 already met; ten criteria of unbuilt writer work remain, incl. a lead-stamped live post-merge proof (idx 11) |

Closing either on the strength of a passing reworded command would be exactly the
label-over-question error D602 forbids.

### Bucket 6 — real work left, no gate to blame (1 row)

`dr-w5-s4-agent-binary-reaches-the-fleet` — **4/8**. idx 4 wants a LIVE PROOF on one
ssh-reachable box (not a code read), idx 5 wants the fleet to read back a non-null `cpu_cores`,
idx 6 wants the still-owed hosts named (`gyl` and `dooodo` fail host-key verification at
`known_hosts:53`/`:54`), idx 7 is the merge. Four unbuilt criteria. Not closable by any reading.

### D568's PASSING six: downgraded from a count to a sentence

D568's counter-finding recorded SIX unmet criteria whose commands already pass on
`origin/main`. It named them by descriptor, not by row, and the rewording it ruled has since
changed the criterion text those descriptors would have matched. The six are not re-derivable
from the ledger and this record does not name them. What IS re-derivable, and is asserted
instead: the six criteria D568 found UNANSWERABLE were all reworded on 2026-08-09 by
`dr-w33-s5`, they carry the marker `[command re-worded runnable by dr-w33-s5, 2026-08-09]` on
five rows. Three of them were re-run by this slice and are quoted in §(b). A fourth was re-run
here — `sed -n '/^  record-delivery:/,/^  report-recorder-failure:/p' .github/workflows/deploy.yml
| grep -n '|| true' | grep -vE '^[0-9]+: *#'` returns nothing, **rc=1**, at `4b5d802a1d` — and
it carries the one line drift worth recording: the file's third `|| true` hit is at **`:427`**,
the comment asserting the criterion, where D568 recorded it at `:413`. The line moved, the
defect did not. The remaining two (`dr-w25-s8` idx 8's single-quoted `grep -qE`, idx 7's typed
503 soft-fail) were **not** re-run by this slice — they were stamped met by their own builder
and this record does not re-assert them; it names them so the gap is visible.

## Net effect on the roster

Five rows left the open population: four `done`, one `cancelled`. Six rows entered it as
wave-35 slices claimed, which is why the open count fell only 191 → 189 and why `in_progress`
went 0 → 8. **The partition's value is not the count it moved — it is that after this file,
every one of the remaining rows has a named bucket and a reason a stranger can re-derive.**
