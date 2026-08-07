# Spec-gate flip packet, REFRESHED — and the seven rows no board could see (2026-08-07, wave 39 / cch-w39-s5)

This row supersedes the integers in `spec-gate-packet-recheck-2026-08-07.md` (wave 38). That row is
not wrong; it is STALE, and its refusal is the stale part. It refused the flip because **#9921 had
not merged**. #9921 merged at `4cb1072ec2305ba43fd5dd3f845974997db42e76`, 2026-08-07T00:15:00Z, and
its merge commit is an ancestor of `origin/main`. Re-quoting wave 38's reason today would itself be
the dishonest gate this epic exists to delete.

Every number below was re-run at `origin/main` `9e39c60c0`, in a worktree cut from it, **with each
exit code read by redirect and never through a pipe** — `cmd > out 2>&1; echo "rc=$?" > rc`. A pipe
eats the return code of everything but its last stage, so `cmd | tail && echo ok` prints `ok` for a
failing `cmd`.

    git worktree add --detach /tmp/wt-sg39 origin/main
    cd /tmp/wt-sg39
    git rev-list --count HEAD..origin/main      # must be 0 before you quote anything

---

## Part 1 — the refreshed packet

### The candidate spec, and the trap in building it

    jq '.protection.required_status_checks.checks += [{"context":"Required-check spec gate","app_id":15368}]
        | .exclusions |= map(select(.context != "Required-check spec gate"))' \
       .github/required-checks.json > /tmp/_cand5.json

**`app_id` IS LOAD-BEARING AND THE OBVIOUS ONE-LINER DROPS IT.** Appending
`{"context":"Required-check spec gate"}` alone yields `app_id: null`, which registers a context
*any* GitHub App may satisfy. It is visible but easy to miss: the floor prints the added row as
`ADDED  Required-check spec gate<TAB>null` instead of `<TAB>15368`. The verifier already treats this
as a hard error on the read-back side — its own probe 3 is *"app_id:null where the spec pins an id
is HARD"* — but nothing stops you authoring the candidate that way. All four live contexts carry
`app_id 15368`; the fifth must too.

### Today's integers

| claim | rerun (rc by redirect) |
|---|---|
| hermetic suite **124 passed, 0 failed**, rc 0 — *not* wave 38's 119 | `bash scripts/required-checks.test.sh --hermetic > o 2>&1; echo "rc=$?" > rc` |
| live suite **128 passed, 0 failed**, rc 0 — *not* wave 38's 123 | `bash scripts/required-checks.test.sh > o 2>&1; echo "rc=$?" > rc` |
| live protection: **4 contexts** (Cloud gate, Console gate, Elixir gate, PR references an active task), `enforce_admins=true`, `strict=false` | `gh api repos/FRIKKern/barkpark/branches/main/protection > prot.json 2>&1; echo "rc=$?" > rc` |
| floor **rc 2** without `--acknowledge-growth`, naming `ADDED Required-check spec gate	15368` | `bash scripts/required-checks-floor.sh /tmp/_cand5.json > o 2>&1; echo "rc=$?" > rc` |
| floor **rc 0** with it: `FLOOR OK: superset held; growth ACKNOWLEDGED, 5 context(s)` | `bash scripts/required-checks-floor.sh --acknowledge-growth /tmp/_cand5.json > o 2>&1; echo "rc=$?" > rc` |
| sweep **rc 0, casualties 0** — and now it reports its own coverage | `bash scripts/registration-deadlock-sweep.sh --spec /tmp/_cand5.json > o 2>&1; echo "rc=$?" > rc` |
| verify **rc 1** against the candidate — for TWO reasons, only one of which the PUT clears | `bash scripts/required-checks-verify.sh --spec /tmp/_cand5.json > o 2>&1; echo "rc=$?" > rc` |
| verify **rc 0** against main's own committed spec (live and spec agree today) | `bash scripts/required-checks-verify.sh > o 2>&1; echo "rc=$?" > rc` |

Note the floor's `--spec` flag does **not** exist — it takes the candidate positionally. Passing
`--spec` exits 1 with `FAIL: unknown argument`, which is easy to misread as a refusal.

### THE DENOMINATOR MOVES HOURLY — RE-RUN IT AT THE MOMENT OF THE FLIP

The sweep's verdict as measured at 2026-08-07T01:3xZ, quoted whole because the last line is the
point:

    swept 14 open PR(s); evaluated 2, skipped 12 (draft 1, conflicting 5, already-blocked 6, other 0); casualties: 0
    NO CASUALTY among the 2 of 14 open PR(s) this sweep could evaluate: each renders every newly proposed context.
    PARTIAL COVERAGE: 12 PR(s) were skipped and say nothing either way. Quote this line, not just the verdict, wherever the flip is authorized.

**Do not inherit `2 of 14`.** Wave 38 measured `2 of 22`. `already-blocked` is the state every open
PR passes through while any required check is in flight, so this denominator is partly a reading of
what CI happened to be doing at that minute. The authorizing sentence must quote a sweep run in the
same session as the PUT, and must carry the `PARTIAL COVERAGE` line, not just `casualties: 0`.

#9921's fix is doing exactly what it shipped to do: the coverage accounting and the `PARTIAL
COVERAGE` line are its output. `cch-w37-bl-register-spec-gate-human-gate`'s criterion 1 ("a
zero-evaluated green is REFUSED as authorization") is now *checkable*: 2 is not 0, so the run is not
refused on that clause — and it is also not a broad mandate.

### THE ORDERING TRAP

Run the sweep **before** the spec PR merges. After it merges, the sweep short-circuits to *"proposes
no context that origin/main does not already require"* and exits 0 — a vacuous green
indistinguishable from a real authorization.

**ADDENDUM 2026-08-07 (wave 39 REVIEW) — the trap above stops being prose.** This section had been
written as a sentence twice (the wave-38 ledger recipe and `cch-w37-bl-register-spec-gate-human-gate`)
and was still unenforced, so wave 39 shipped it as a mechanism:
`scripts/registration-deadlock-sweep.sh --require-new-context` routes the identity short-circuit
through the script's own `fail()` and exits **2**. Without the flag the bare run stays exit 0 (a
sweep on a spec-untouching branch is a legitimate no-op) but now prints a `NO COVERAGE:` line naming
what it did not examine. **The flip's step 2 must therefore be run WITH the flag** — the prose above
is the reason, not the guard.

The flag is inert on a correctly-ordered run, and that is measured, not assumed. Re-run at review
against the candidate this packet builds, rc read by redirect:

    bash scripts/registration-deadlock-sweep.sh --spec /tmp/_cand5.json --require-new-context
    → rc 0
      swept 14 open PR(s); evaluated 2, skipped 12 (draft 1, conflicting 5, already-blocked 6, other 0); casualties: 0
      NO CASUALTY among the 2 of 14 open PR(s) this sweep could evaluate: each renders every newly proposed context.
      PARTIAL COVERAGE: 12 PR(s) were skipped and say nothing either way. Quote this line, not just the verdict, wherever the flip is authorized.

Identical to the unflagged row in *Today's integers* — the flag costs a correctly-ordered sweep
nothing and refuses the out-of-order one. **Ships on a different branch than this file**
(`loop-epic/the-registration-sweep-stops-returning-a-2-r`, wave 39 S4); until that merges, the flag
is not yet on `main` and passing it exits 2 with `FAIL: unknown argument`, which is a refusal for the
wrong reason. Check `grep -c require-new-context scripts/registration-deadlock-sweep.sh` before
quoting this addendum in an authorization.

### THE FLIP IS NOT AUTHORIZED, AND THIS PACKET DOES NOT AUTHORIZE IT

The packet is turnkey. It is not permission.

- `cch-w37-bl-register-spec-gate-human-gate` still requires **explicit owner sign-off**. It is NOT
  closed by this row, and completing a packet is not paying a human gate. Closing a human gate
  because its packet is finished is precisely the false-done this epic exists to cure.
- **The post-PUT read-back is UNPROVEN BY RUN.** Nobody has ever executed
  `scripts/required-checks-apply.sh --confirm`. Every claim about what happens after the PUT is a
  claim about a code path that has not run on this repo.
- No branch-protection PUT was performed by this row. `enforce_admins` is `true`; a wrong flip
  deadlocks `main` for everyone.

### AND THE PUT WILL NOT MAKE `verify` GREEN — MEASURED, NOT PREDICTED

Wave 38's D435 frames verify's `rc 1` as the announced live-vs-spec drift, which reads as *"the PUT
clears it."* It clears **half** of it. Against the 5-context candidate, verify fails twice:

1. `MISSING from live: Required-check spec gate (app_id 15368)` — the announced drift. The PUT clears this.
2. the advisory-prose clause: `.github/workflows/required-checks-drift.yml:9  claims "Required-check spec gate" is not blocking`.

Cause (2) does not clear. Proven **before** any PUT, using the script's own read-back seam with a
synthetic post-PUT protection object:

    jq '.required_status_checks.checks += [{"context":"Required-check spec gate","app_id":15368}]' prot.json > postput.json
    bash scripts/required-checks-verify.sh --spec /tmp/_cand5.json --readback postput.json > o 2>&1; echo "rc=$?" > rc

Result: clause (1) turns green — `ok required_status_checks.checks match on context AND app_id (5
context(s))` — clause (2) still `FAIL`, and **rc is still 1**.

This is not a bug in the guard, and the guard says so itself: the clause is *"proximity, not
attribution — a required context named within the window of somebody else's disclaimer is flagged,
and the fix is to reword, not to widen the window."* `required-checks-drift.yml`'s header describes
the BLOCKING job on line 9 and the ADVISORY job on line 12, and the 200-character window spans both.
The moment `Required-check spec gate` becomes required, that header trips its own verifier.

**Consequence for the flip: the prose reword must land in the same commit as the spec change.**
Otherwise the operator performs the hardest-to-undo operation in this repo, runs the verifier, sees
`rc 1`, and cannot tell a successful flip from a failed one. Filed as
`cch-w39-bl-spec-gate-flip-leaves-verify-red-on-workflow-prose` (open, 0/5). The same header also
still claims the hermetic suite is *"72 assertions"*; it is 124.

### THE REGENERATION LIE IS STILL LIVE, AND THE FLIP CURES IT FOR FREE

    grep -c 'CORRECTED AGAIN 2026-08-06' scripts/required-checks-generate.sh   # 0
    grep -c 'CORRECTED AGAIN 2026-08-06' .github/required-checks.json          # 1

Wave 36 hand-corrected the `Required-check spec gate` exclusion reason in the JSON.
`scripts/required-checks-generate.sh:146` still carries the pre-correction text, ending *"Re-evaluate
once #8222 lands or is rebased"* — a trigger that can never fire (#8222 is CLOSED with `mergedAt`
null). **The next regeneration silently reverts the correction.**

    grep -n 'EXCLUDED_BY_DECISION' scripts/required-checks-generate.sh
    # :141 NAMES  :145 REASONS  :713-715 the index zip

`EXCLUDED_BY_DECISION_NAMES` and `_REASONS` are **index-parallel** (`:713-715` walks `d` across both).
Registering the context requires deleting `"Required-check spec gate"` from NAMES, which structurally
forces deleting the reason at the same index. So the flip pays this debt for free.

**If the flip does not proceed, the debt is real and must be paid by hand** — the generator will
overwrite the JSON's corrected reason on its next run, and nothing gates that.

---

## Part 2 — the roster disposal, every write read back from the server

A printed `rev` is not persistence. Every write below was re-read from the server after it was made,
and two of this epic's own prior writes turned out not to have landed at all.

**Roster, re-derived (the brief's 465 was already stale):** `bp task get cloud-console-hardening-epic`
→ **477 children** at the start of this run, **480** at the end (three filed by concurrent wave-39
builders). Twelve `drafts.*` rows exist; **seven were live** (6 open + 1 in_progress).

### Why the seven were invisible

`bp search` indexes **published documents only**. Measured: any query returns
`facets.status: [{"count": 3894, "label": "published"}]` — a single facet, no `draft` facet exists. A
search for the exact title of `drafts.cch-w37-bl-roster-collapse-three-paid-rows` returned 3894
documents and **not that row**. Seven rows of real, stamped work were addressable only by someone who
already knew the id.

### (a) Three provably-paid rows closed — each verified twice, independently

| row | server read | gh proof | after |
|---|---|---|---|
| `cch-w38-s3-spec-gate-packet-and-roster-disposition` | 11/11 met, no merge-gate criterion, **claim LAPSED** (`worker: null`) → re-claimed epoch 8→9 | deps #9957 `6949a1ffc` and #9921 `4cb1072ec` both MERGED, both `git merge-base --is-ancestor` rc 0 | `done`, 11/11 |
| `cch-w37-s3-scope-stops-naming-a-team-it-did-not-consult` | 8/9; sole unmet is index 8, the merge gate | #9919 MERGED `9238cd542` 00:33:39Z, ancestor; PR body carries the matching `Task:` trailer; on head `7d3ec6886` the check-runs feed reads **Cloud gate: success, Console gate: success** (its criterion demands both) | `done`, 9/9 |
| `cch-w37-s5-the-sweep-stops-passing-on-what-it-did-not-see` | 9/10; sole unmet is index 9, the merge gate | #9921 MERGED `4cb1072ec` 00:15:00Z, ancestor; `Task:` trailer matches; behaviour re-proven live (the coverage line quoted above IS this row's deliverable) | `done`, 10/10 |

`bp task close` **refuses to flip a criterion in the close command itself** — *"criteria flipped in
this very close command do not count — that would be the closer grading its own homework."* Stamp
first, then close. A merge-gated criterion additionally refuses `--met` unless `--merge-gated` is
passed. **That flag exists**, which refutes D250's *"there is no `--merge-gated` flag on `bp task
stamp`."*

### (b) The seven drafts, disposed

**Five cancelled** — each claimed, closed `cancelled`, then re-read as `{status: draft, lifecycle:
cancelled}` with its published twin re-read intact:

| draft | draft met | published twin | evidence lost |
|---|---|---|---|
| `drafts.cch-w31-s4-followup-retire-status0-branches` | 9/10 | `done` 10/10 | none |
| `drafts.cch-w32-r2-notifications-withhold-branches` | 8/9 | `done` 9/9 | none |
| `drafts.cch-w34-s3-disclosure-survives-delivery` | 3/9 | `done` 8/9 | none |
| `drafts.cch-w35-s4-forbidden-evidence-beats-the-global-slug` | 11/14 | `done` 14/14 | none |
| `drafts.cch-w36-s3-me-cache-has-an-unknown-state` | 7/12 | `done` 12/12 | none |

Every published twin **strictly dominates** its draft, so no stamped evidence was destroyed. That
check is the whole safety argument and it must be re-run, not assumed: a draft that dominated its
twin would make cancelling it a deletion.

**Two published** (no twin existed, so they were draft-only rows nobody could reach):

- `cch-w37-s1-invalid-precedence-details-win` → published, `in_progress`, **9/10**, parented.
- `cch-w37-bl-roster-collapse-three-paid-rows` → published, `open`, 0/4.

Both re-found by `bp search` afterwards. Neither published cleanly, and the reasons are recorded on
`cch-w39-bl-publish-wall-refusals-name-a-details-list-they-do-not-send`:

- The `bl` row failed the `label_spine` wall whose hint promises *"details lists each field, the rule
  it broke, and the fix"* — the payload carried **no `details` key at all**. Two causes, found by
  bisection, neither named by the refusal: `main_tag` was `null`, and after fixing that the wall
  still refused until the top tag's strength was raised from 52. Wave 37's Decide filed the row
  without a `main_tag`, which is *why* it could never be published and stayed invisible.
- The `s1` row was refused by the near-duplicate guard, whose hint says *"the details.duplicate_of id
  names it"* — again no details. The offender, found via `bp search`, was
  `cch-w36-s6-invalid-precedence-details-win`, and **the guard kept refusing after that row was
  cancelled**: a cancelled row goes on blocking its own named successor. Cleared by differentiating
  title and tags exactly as the guard's own hint directs (title now names the successor relationship
  and the PR it rides; top tag is now `named-successor`).

### (c) TWO WRITES THIS EPIC BELIEVED IT HAD MADE, AND HAD NOT

Both surfaced while disposing the drafts, and both are the same failure in different directions.

1. **`cch-w36-s6-invalid-precedence-details-win`: the reason landed, the close did not.** The row
   carried a full `close_reason` beginning *"SUPERSEDED — cancelled by cch-w38-s3"*, while its
   `lifecycle_status` read `in_progress` with `claim.closed_at: null` and the wave-38 builder's claim
   still held. Its sibling `cch-w36-s5` shows the landed shape (`cancelled`, `closed_at` set).
   `cch-w38-s3`'s criterion 6 evidence asserts *"Both read back cancelled/published"* — one of them
   did not. Landed here: released the lapsed foreign claim (epoch 5→6, `worker: null`, lifecycle back
   to `open`), re-claimed on epoch 7, closed `cancelled`, re-read `{cancelled, closed_at
   2026-08-07T01:36:04Z}`. The wave-38 decision is unchanged and restated verbatim in the new reason;
   only the landing is new. (#9917, the payer, is still OPEN with `mergedAt: null`.)

2. **`cch-w36-bl-mecache-unknown-arms-remaining`: the cancel landed on the wrong document.** It is
   `status: published`, `lifecycle: cancelled`, 0/2 — and its `close_reason` reads *"This is a
   `drafts.` twin of the published row cch-w36-bl-mecache-unknown-arms-remaining … The published row
   is the one of record and is NOT touched here."* The document carrying that sentence **is** the
   published row. A scan of all 480 children finds exactly one document with that slug and **no
   `drafts.` twin of it has ever been in the roster**. A live row with two acceptance criteria was
   killed by a disposal aimed at a phantom, and its tombstone asserts the opposite. Filed as
   `cch-w39-bl-mecache-unknown-arms-cancelled-as-a-twin-that-never-existed` (open, 0/4) — **not**
   resurrected here, because that adjudication needs the row's body read, not a brief's say-so.

### (c-bis) IT HAPPENED TO THIS ROW'S OWN STAMP, WHILE WRITING IT

`bp task stamp` for criterion 8 of `cch-w39-s5` returned its success line —
`✓ the store holds it — criterion index 8 (#9 as boards number them): met=true  evidence 1005 bytes`
— and the store did **not** hold it. A read-back moments later, after the next stamp, showed
`[8] met=false`. Re-stamping the same criterion landed it (`met=true`, 962 bytes) and a second
read-back confirmed it stayed.

The confirmation line is emitted by the client and asserts persistence it did not re-read. That is
the same shape as the two lost writes above, on the same tooling, in the same session, against a row
whose subject **is** that shape — and it is why every criterion in this run was read back from the
server rather than trusted to its own success message. **A `✓` is not a read.**

### (d) A stale subject corrected instead of inherited

`cch-w31-bl-two-rows-invisible-to-every-ledger-instrument` named
`cch-w24-bl-word-break-alias-has-no-ruling` and
`cch-w24-bl-account-menu-lines-nowrap-clipped-at-every-width`. **Both now carry criteria** (0/5 each).
Someone paid the narrow half and nobody told the row.

Re-derived (published + live + `criteria_progress.total` absent-or-0, over 480 children), the set is
**ten**, not two and not the brief's three:

    cch-bl-protection-claim-paraphrase-escape
    task-ed706f4e1c616f89
    cch-w37-bl-require-primary-team-fn-names-still-lie
    cch-w39-bl-converge-the-two-authority-predicates-under-one-canonical-slug
    cch-w39-bl-mefault-must-be-exhaustible-or-no-retry-can-be-proven-to-recover
    cch-w39-bl-three-fact-stating-mecache-reads-remain-unowned
    cch-w39-bl-token-mint-403-carries-no-authority-evidence
    cch-w39-bl-me-serves-confirmed-and-the-console-never-reads-it
    cch-w39-bl-audit-the-other-three-packet-instruments-for-vacuous-exits
    cch-w39-bl-one-refusal-contract-for-no-team-across-gates-and-inline-emitters

**Seven of the ten are `cch-w39-bl-*` — filed by wave 39's own Decide, in the wave carrying this
correction.** The hole is being refilled faster than it is drained. The row's title, description and
criteria were rewritten and republished: criterion 1 now forbids adjudicating the list the row itself
names without re-deriving it, and a fourth criterion was added for the **inflow**, because draining
the stock is not the fix.

### (e) Two unproducible criteria rewritten

On `cch-w38-bl-adopt-canonical-authority-predicate` (0/6 before and after — no evidence at risk):

- **Criterion 0** demanded *"a grep shows a single definition"* across all of `app.js`. That is the
  entire deliverable of `cch-w31-bl-console-role-set-copied-five-times`, strictly wider than this row,
  and satisfiable at this row's size only by fabrication. It now requires the adopted reads named
  individually by `file:line`, the count of **remaining** copies **derived and recorded rather than
  asserted to be zero**, and a mutation proving the harness reds when an adopted site is reverted.
- **Criterion 4** required *narrowing* `cch-w36-bl-mecache-unknown-arms-remaining`, which is already
  `cancelled` — unsatisfiable as written. It now excludes that row entirely (with the unsound
  cancellation recorded in the criterion text), and closes
  `cch-w31-bl-console-role-set-copied-five-times` **only if that row's own three criteria are met**;
  otherwise the remaining copies are re-derived onto it and it **stays open**.

### (f) LAW 0, STATED SO IT CANNOT BE INFLATED

Denominator = **published** live rows (`open` + `in_progress`, `drafts.*` excluded), because the seal
predicate's roster is published-only.

- **Opening: 171.** (Snapshot A measured 168 published-live at 477 children, taken after the three
  closes below; +3 for those.)
- **Closes that COUNT — 4:** `cch-w38-s3`, `cch-w37-s3`, `cch-w37-s5`, and `cch-w36-s6` (whose cancel
  wave 38 decided, wrote, and never landed).
- **Closes that DO NOT COUNT — 5:** the five `drafts.*` cancellations. D190/D250 rule a draft discard
  buys **zero** row-shrink, and it is mechanically true here: snapshot A's 168 already **excluded** all
  seven live drafts, so removing them cannot move the number. **Do not quote this run as −9.**
- **Additions that must not be hidden — +2:** publishing the two twinless drafts **raises**
  published-live by 2. That is honest growth in the *visible* count with no change in real work; the
  obligations always existed, they were merely unfindable.
- **171 − 4 + 2 = 169.** Snapshot B measures **172**; the +3 is three rows filed by concurrent wave-39
  builders over the same window (children 477 → 480). Net attributable to this slice: **−2**.
- Three new backlog rows were filed by this slice and are counted in that +3's successor, not hidden:
  `cch-w39-bl-mecache-unknown-arms-cancelled-as-a-twin-that-never-existed`,
  `cch-w39-bl-spec-gate-flip-leaves-verify-red-on-workflow-prose`,
  `cch-w39-bl-publish-wall-refusals-name-a-details-list-they-do-not-send`. Each carries real
  acceptance criteria — filing a criteria-less row into the set described in (d) would have been
  self-refuting.
- **Live `drafts.*` rows remaining: 0.**

---

## Part 3 — D386's own citations are stale, and a reviewer following them lands on the wrong row

D386 tells the reader to cite D332 *with* `:1976`. Both pointers are wrong. Re-derive:

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md > /tmp/charter.md
    awk 'NR==604' /tmp/charter.md   # -> "| D316 | **NO CSSOM HOLDER IS SEATED THIS WAVE …"
    awk 'NR==620' /tmp/charter.md   # -> "| D332 | **`domain_status` GETS A THIRD STATE NAMED `unknown` …"
    awk 'NR==1976{print "[" $0 "]"}' /tmp/charter.md   # -> "[]"  (an EMPTY line)
    awk 'NR==2693' /tmp/charter.md # -> "**`:nxdomain` IS AN ANSWER, NOT A FAULT — decided at review, superseding the letter of D332.**"
    grep -n nxdomain /tmp/charter.md | head   # the supersession headline exists at :2693 and nowhere else

- D386 cites **"D332 (`:604`)"**. `:604` is **D316**. D332 is at **`:620`**.
- D386 cites **`:1976`** for the nxdomain supersession. `:1976` is **empty**. The ruling is at **`:2693`**.

This is corrected **here**, in a ledger row, and not in the charter's D386 text — a decision row is a
record of what was decided, and this row is where the pointer correction belongs. Anchor by symbol
(`grep -n '| D332 |'`) rather than by line: this charter is 5079 lines on `origin/main` and every
line number in it drifts on every wave.

**And read the charter from `origin/main`, never from the primary checkout.** D446's own finding,
re-confirmed by this run: the primary copy tops out ~32 D-rows behind and reads as entirely
plausible while doing so.
