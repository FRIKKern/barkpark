# dr wave 35 — the D587 partition's cheap cuts, re-derived on tip

Read timestamp (UTC): `2026-08-17T07:08:14.959Z` (the seal predicate's own `read at` line).
Repo tip at read: `4b5d802a1d`. Taken by the wave-35 verifier lane `partition-cheap-cuts`.
**Re-derive, do not re-discover.** Every number below is a command, never a quote.

## The two rosters disagree by exactly the two live drafts

```
bp task get task-fb4fb869490b4213 -o json | python3 -c 'import json,sys,collections; d=json.load(sys.stdin); print(d["child_count"], collections.Counter(c["lifecycle_status"] for c in d["children"]))'
332 Counter({'open': 191, 'done': 128, 'cancelled': 13})

node cloud/priv/static/__preview__/seal-predicate.mjs --epic task-fb4fb869490b4213 --successor am-bl-idle-p95-anomaly --repo . | grep -E '^roster|VERDICT-TOKEN'
roster: 330 children  {"done":128,"open":189,"cancelled":13}
VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=189 considering=0 successor=am-bl-idle-p95-anomaly epic=task-fb4fb869490b4213 mode=live stubbed=0 waived=0 roster=330 repo=. head=4b5d802a1d
```

`332 − 330 = 191 − 189 = 2` — `drafts.dr-w26-hg-gyldendal-operator-packet-corrected` and
`drafts.dr-w34-bl-5658-blocks-its-own-routing-fix`. The predicate's roster drops `drafts.*`;
`bp task get` keeps them. **Neither number is wrong; a bare "191" or a bare "189" is.**

## Lifecycle split (b): there is no third state to split

```
open 191 · in_progress 0 · considering 0 · researching 0   (bp task get, 2026-08-17)
considering=0                                              (seal predicate, same instant, independent reader)
```

`lifecycle_status` takes exactly one value across all 191 live rows: `open`. D587's
`in_progress` heartbeat term and D567's at-100%-criteria term are both structurally inert at 0.
D587's arithmetic re-runs: `191 live − 7 zero-criteria − 0 at-100% = 184`.

The 7 zero-criteria rows: `dr-w25-followup-reader-blind-to-transition`,
`dr-w27-s8-f1-seven-day-door-refuses-until-boundary-ages-out`, `dr-w33-followup-deferral-wait-right-edge`,
`task-e2acb66e9ed0da09`, `task-6d1bb2843f0c91fb`, `task-a02741ad13bbf010`, `task-7a85d1b5f471af8f`.

## (a) disposition_reason while open: TWELVE rows, and only ONE says superseded

```
bp export --type task > tasks.ndjson          # fields are TOP-LEVEL, content:{} is empty — do not read content.*
# join against the epic's open children, count non-empty disposition_reason
12
```

Breakdown: 6 `Fleet audit 2026-08-11` notes · 3 `WAVE-24 REVIEW (2026-08-08)` notes ·
1 roster-headroom adoption note · **1 genuine `SUPERSEDED by …`**
(`dr-w33-bl-crown-skew-arm-has-no-epsilon`, superseded by `dr-w34-s3-crown-in-flight-before-skew`).
`disposition` field: 11 rows carry the literal `open`, and the ONE superseded row carries `None` —
**the only row a superseded-filter would want is the only one with no machine-readable marker.**
There is no "superseded-but-open class"; there is one row and eleven audit notes.

## (c) No DR row can appear in PERMANENT_HUMAN_GATES — and nothing else prints them either

```
grep -n 'PERMANENT_HUMAN_GATES' -A8 cloud/priv/static/__preview__/seal-predicate.mjs   # 3-entry object literal
grep -cE "'dr-w[0-9]" cloud/priv/static/__preview__/seal-predicate.mjs                 # 0
grep -cE 'dr-w25-hg-|dr-w33-hg-|dr-w26-hg-' cloud/priv/static/__preview__/seal-predicate.mjs   # 0
grep -cE 'PERMANENT_HUMAN_GATES|HUMAN_GATE|dr-w..-hg-' scripts/deploy-reliability-exit-run.sh  # 0
```

The table is a hardcoded literal of `gr-ops-platform-admin-emails`, `gr-backlog-qr-live-scan-proof`,
`cch-hg-compose-network-recreation` — all three `parent=cloud-console-hardening-epic in-epic-roster=false`.
The live run confirms the consequence: `permanent human gate : 0` for this epic, so **the epic's own three
`-hg-` rows are counted as UNNAMED RESIDUE, not as gates.** And `scripts/deploy-reliability-exit-run.sh`
(506 lines) has no gate table at all — it prints three fleet numbers and nothing else.
**Conclusion: "human gates stated as human gates" has NO printer in either instrument; it must be prose.**

## (d) The two wave-33 rows, re-derived

`dr-w33-s4-alarm-reaches-a-human` — 6/8. Both remaining criteria are satisfiable TODAY:

```
gh pr view 11481 --json mergedAt,mergeCommit -q '.mergedAt, .mergeCommit.oid'
2026-08-09T22:04:52Z
694366b62e275f0ef779b426dd8f6fc16a446ba9
gh pr view 11481 --json body -q .body | grep -ci pages      # 0  (criterion 6)
git merge-base --is-ancestor ded88cc82a origin/main         # NO — squash-merged; cite 694366b62e, not ded88cc82a
```

`dr-w33-bl-crown-schedule-has-never-run-the-reconcile` — 0/4, and **its headline premise is REFUTED**:

```
gh run list --workflow crown-reconcile.yml --event schedule --limit 40 --json conclusion
32 schedule runs: success 19 · failure 13
gh run view 32003613747 --json event,conclusion   # schedule / success, step 5 SUCCESS
```

Criterion 1 met by run `32003613747` (schedule, 2026-08-17T06:55:40Z, step 5 succeeded).
Criterion 2 met by the failing runs' own diagnosis — the last five before it fail **at** step 5, not skipping it:

```
gh run view 31984449932 --log-failed | grep -E 'POPULATION|COULD NOT VERIFY|SILENCE'
POPULATION: 0 successful deploy.yml run(s) on main in the window; 0 of them DELIVERED …
COULD NOT VERIFY: the population was EMPTY — 0 successful run(s) in the window …
##[error]SILENCE — the reconciler COULD NOT READ part of what it compares, the population was empty …
```

Criterion 4's fact is in the same log: `READER: transport=ssh, answered by postgres-container (route=0 …) — the
/v1/deliveries route answered HTTP 401 to the WORKER` principal. **Criterion 3 is REFUTED, not pending:**
`gh issue view 11217` → OPEN, **41 comments**, 33 of them containing `SILENCE`, last at `2026-08-17T06:32:57Z`.
The residual is not "the schedule never runs" — it is **a quiet repo reds the crown every 6 h forever.**

D590's entailment also came true unattended: `gh issue view 5658` → OPEN, `assignees=0`, **16 comments**
(8 at D590's writing), latest `2026-08-17T06:19:50Z`.

## (e) D568 — the BROKEN six are CURED and the PASSING six are UNENUMERABLE

The reword ruled by D568 LANDED: all six criteria now carry
`[command re-worded runnable by dr-w33-s5, 2026-08-09]`, and all six rows are still `open`.
Every reworded command PASSES on `origin/main` today:

```
git show origin/main:internal/cloudclient/deliveries.go | grep -cE 'Carried +\*bool'                 # 1   (must be 1)
git grep -nE 'publish_clock' origin/main -- cloud/lib cloud/priv api/lib internal web js; echo $?     # rc=1 (must be empty)
git grep -n 'refute Map.has_key?(body, "build_slots")\|refute Map.has_key?(body, "runner_queue_len")' origin/main -- api/test
  → instance_site_deploy_controller_test.exs:138 and :139 (as named)
git show origin/main:api/lib/.../instance_site_deploy_controller.ex | sed -n '/^  """/,$p' | grep -nE 'runner_queue_len|build_slots'; echo $?   # rc=1
sed -n '/^  record-delivery:/,/^  report-recorder-failure:/p' .github/workflows/deploy.yml | grep -n '|| true' | grep -vE '^[0-9]+: *#'; echo $?  # rc=1
bash scripts/stale-verdict-watch.test.sh   # ── stale-verdict-watch: 87 passed, 0 failed ──  rc=0
```

The three OLD forms still reproduce their defect, with one line drift to record:
`grep -c 'Carried \*bool'` → 0 while `grep -cE 'Carried +\*bool'` → 1 (`internal/cloudclient/deliveries.go:121`);
`grep -n '|| true' .github/workflows/deploy.yml` → `:63 :161 :427` and **:427 is the comment asserting the
criterion** (D568 recorded it at `:413` — the line moved, the defect did not).

**The "six unmet criteria whose commands PASS" cannot be enumerated from the ledger.** D568 names them only
by descriptor. Matching the descriptors against the 191 open rows' unmet criteria yields
`stale-verdict-watch.test.sh` → 1, "path-escape" → 6, "go build/vet/test" → 8 (15 candidates for 6 slots),
while `|| true`, `grep -qE` and `Carried *bool` → **0 unmet matches each**, because those very criteria were
reworded. Membership is not recoverable. **The downgrade sentence the exit artefact prints instead:**

> D568's counter-finding recorded SIX unmet criteria whose commands already pass on `origin/main`.
> It named them by descriptor, not by row, and the rewording it ruled has since changed the criterion
> text those descriptors would have matched. The six are not re-derivable from the ledger and this
> artefact does not name them. What IS re-derivable, and is asserted instead: the six criteria D568
> found UNANSWERABLE were all reworded on 2026-08-09 (`dr-w33-s5`), and all six reworded commands pass
> on today's tip — quoted above, one command each.

## The partition's single most useful derived cut

```
# rows whose ONLY unmet criteria are labelled MERGE-GATED
25   (24 with exactly one unmet criterion, 1 with two — reconciles with D587's "24 at L4")
```

**But the label is polluted and 25 is NOT the closable count.** At least three of the 25 are human
judgement, not a merge: `dr-w23-s7` ("the owner has read both Papers"), `dr-w23-s8` ("the lead reviews
the close-out list"), `dr-w24-s6` ("the lead confirms the new roster number"). Seven more are blocked on
a still-OPEN PR: `dr-w10-s1` #10129 · `dr-w15-s2` #10400 · `dr-w21-s1` #10722 · `dr-w21-s3` #10720 ·
`dr-w23-s4` #10811 · `dr-w24-s3` #10944 · `dr-w34-s1` #11534 (all OPEN as of this read).
Only three are **run-proven** closable, by the commands quoted under (e):
`dr-w26-s3` (#11080 MERGED 08-09), `dr-w26-s6` (#11083 MERGED 08-09), `dr-w26-s7` (#11139 MERGED 08-09).

Also derived, for the partition's own rows: `-hg-` rows = 3 (one a draft) · `-bl-` rows = 87 ·
follow-up rows = 25 · rows with a live claim = 59 of 191.
