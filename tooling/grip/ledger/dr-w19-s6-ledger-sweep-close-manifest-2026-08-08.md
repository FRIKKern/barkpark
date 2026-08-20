# dr-w19-s6 — the ledger stops manufacturing false premises (2026-08-08)

Slice `dr-w19-s6-ledger-pays-its-debt`, worker
`epic-builder-the-epic-s-ledger-stops-manufacturing-fa`, branch
`loop-epic/the-epic-s-ledger-stops-manufacturing-fa-4`.

**This is BOOKKEEPING, not progress.** Not one line of product code changed. Rows that were
already finished stopped reading as unfinished. The number that matters is at the bottom:
how many rows still carry REAL remaining work.

---

## 0. The whole point

Wave 19 opened on the premise "a repair this epic already wrote and never ran". It had run
eighteen hours earlier. The belief survived because four separate open rows still carried the
repair as unrun, and because most partly-met rows sat at N-1/N with the merge gate as their
only unmet criterion — so a finished row and an unfinished row looked identical from the board.
A ledger that cannot tell those apart re-manufactures the undone belief into the next wave's
strategy. That is the defect this slice repairs, at the ledger rather than in code.

## 1. The list was RE-DERIVED, not consumed

Counts drift hourly. The brief's census (2026-08-08) said **334 children / 76 partial**. This
run measured **352 children / 76 partial** — different tree, same day. Nothing here was taken
from a frozen roster.

    bp task get task-fb4fb869490b4213 -o json > epic.json
    python3 -c "import json;d=json.load(open('epic.json'));ch=d['children'];\
    print(len(ch), sum(1 for c in ch if c.get('criteria_progress') \
    and 0<c['criteria_progress']['met']<c['criteria_progress']['total']))"

Then one `bp task get <row> -o json` per partial row (76 fresh fetches — the epic child list
carries only `criteria_progress`, not the criteria themselves).

## 2. The two method traps, both reproduced before being guarded

**Trap 1 — the vacuous green.** `gh` shells out to `git`. Run outside a repo it yields nothing
and prints the real cause only on stderr. Reproduced verbatim in this run, from the scratchpad
directory:

    $ gh pr list --search "head:loop-epic/the-doc-type-filter-reaches-the-five-liv-3" \
        --state all --json number,state
    (no rows)
    stderr: failed to run git: fatal: not a git repository (or any of the parent directories): .git

That shape marked 96 of 96 branches unmerged during wave 19 verification. Note one difference
from the brief: **this `gh` exits 1, not 0** — so an exit-code check alone would have caught it
here but not there. The guard therefore tests BOTH, and refuses on either.

**Trap 2 — punctuation and prefix.** Branch names scraped from prose carry a sentence-final
period, and `head:` is a PREFIX match whose merged PR usually lives on `<branch>-r` (the
reviewer's rebase branch). Reproduced:

    $ gh pr list --search "head:loop-epic/the-doc-type-filter-reaches-the-five-liv-3." --state all --json number
    []
    $ gh pr list --search "head:loop-epic/the-doc-type-filter-reaches-the-five-liv-3"  --state all --json number,headRefName,state
    [{"headRefName":"loop-epic/the-doc-type-filter-reaches-the-five-liv-3","number":10082,"state":"MERGED"}]

## 3. The scripts

`classify.py` — per-row unmet criteria, merge-gate detection, branch extraction with the
punctuation strip:

```python
MERGE_GATE = re.compile(
    r"merge[- ]gated|pull request .*merged|\bPR\b[^.]{0,80}\bmerged\b|"
    r"merged (?:to|into) main|the lead closes|lead-close|closes on merge|"
    r"branch .*is merged|is merged (?:to|into) (?:origin/)?main|"
    r"lead has reviewed|merged into `?main`?", re.I)
BRANCH = re.compile(r"loop-epic/[A-Za-z0-9._/-]*")

def branches(blob):
    out = set()
    for b in BRANCH.findall(blob):
        b = b.rstrip(".,;:)]}'\"")          # TRAP 2a
        b = re.sub(r"\.+$", "", b)
        if len(b) > len("loop-epic/"):
            out.add(b)
    return out
```

`prove_merge.py` — GUARD 1 is an assertion that can fail, not a comment:

```python
probe = sh(["gh","pr","list","--search","head:loop-epic/","--state","all",
            "--limit","5","--json","number"])
probe_rows = json.loads(probe.stdout or "[]")
if probe.returncode != 0 or not probe_rows:
    sys.exit("GUARD 1 TRIPPED: gh returned %d rows rc=%d stderr=%s -- refusing to "
             "interpret empty results as 'not merged'" % (...))
```

and GUARD 2 is prefix matching plus a real ancestry check per hit:

```python
for pr in cache[b]:
    if not pr["headRefName"].startswith(b):      # TRAP 2b — never ==
        continue
    if pr["state"] != "MERGED" or not pr.get("mergeCommit"):
        continue
    sha = pr["mergeCommit"]["oid"]
    anc = sh(["git","merge-base","--is-ancestor", sha, "origin/main"]).returncode
```

`manifest.py` — the closable set, with every exclusion pinned as data so it is auditable:

```python
PULLOUT      = {"dr-terminal-record-prune-tie-order"}       # (a) unbuilt code, not a gate
HUMAN_REVIEW = re.compile(r"independent second review", re.I) # (d) found by this run
CONSOLE_RED  = {"dr-w6-s1-land-the-stack"}                  # (e) found by this run
```

## 4. The merge proof

    rows probed: 76 | merged PRs matched: 68 | ancestor-of-origin/main: 68
    PHANTOM merges (merged but NOT on main): []

Every row closed below carries a merge commit for which
`git merge-base --is-ancestor <sha> origin/main` exited **0**. Zero phantoms.

## 5. Required contexts — what merge actually proves, stated honestly

Most of these gates read "with all four required contexts green **on the merge commit**". That
literal wording is **not satisfiable by post-merge check-runs**, and pretending otherwise would
be its own false premise. Measured across the 52 merge shas:

| Required context | success | ABSENT | failure |
|---|---|---|---|
| Elixir gate | 19 | 33 | 0 |
| PR references an active task | 0 | 52 | 0 |
| Cloud gate | 24 | 28 | 0 |
| Console gate | 23 | 28 | **1** |

`PR references an active task` is PR-scoped and never re-runs on a merge commit, so **0 of 52**
shas carry all four green post-merge. What licenses the closes is the branch itself:

    $ gh api repos/FRIKKern/barkpark/branches/main/protection \
        --jq '{enforce_admins:.enforce_admins.enabled, contexts:.required_status_checks.contexts}'
    {"enforce_admins":true,
     "contexts":["Elixir gate","PR references an active task","Cloud gate","Console gate"]}

`main` is protected with `enforce_admins`, so a commit's presence on `main` IS the proof those
four were green on the PR head. Every close says exactly that, and claims nothing more.

## 6. What was NOT closed, and why

**(a) `dr-terminal-record-prune-tie-order` — pulled out.** Its one unmet criterion is
"A test pins it: terminal records stamped the SAME second are pruned deterministically, and the
test FAILS if the tie-break is collapsed (mutation-proved)". That is **unbuilt code**, not a
merge gate. The classifier found it independently — it was the only one of 61 single-unmet rows
whose criterion failed the merge-gate test. Closing it would flip an unwritten test to met: the
exact fake-done class this epic already reopened eleven rows for.

**(d) Two rows bundle a MANUAL HUMAN REVIEW inside the merge gate** — not in the brief, found
by reading the gate texts instead of trusting the label:

- `dr-w3-s5-door-refuses-box-at-capacity` — "…AFTER an independent second review of the
  door-vs-unit race (a manual lead step this wave arranged, not discovered)."
- `dr-w5-s1-ladder-reaches-triage` — "…AFTER the independent second review of the ladder
  ordering and bucket boundary…"

Both PRs merged and are on `main`, but merge evidence does not prove a human read anything.
Closing them would fabricate a review. **Held for the lead.**

**(e) `dr-w6-s1-land-the-stack` — the brief said close it; this run says do not.** Its gate
demands "#9888 merges to main with all four required contexts green". All four of its PRs are
merged and on main:

| PR | merge commit | merged | ancestor of origin/main |
|---|---|---|---|
| #9888 | `dfa5e4dac8fa9fd9644ad8cbe2dce0c4eefe66a4` | 2026-08-07T00:50:57Z | exit 0 |
| #9887 | `c2eecb66d085cc8bf210a41054ea1a05af784866` | 2026-08-07T06:13:52Z | exit 0 |
| #9889 | `f4194c51f3294b0880cd11ce83a8f4894c02c99f` | 2026-08-07T00:35:41Z | exit 0 |
| #9890 | `93b07bc265bce07d388bab170b7e8fce32864dc0` | 2026-08-07T00:15:03Z | exit 0 |

But #9888's own merge commit carries a RED required context:

    $ gh api repos/FRIKKern/barkpark/commits/dfa5e4dac8fa9fd9644ad8cbe2dce0c4eefe66a4/check-runs \
        --paginate --jq '.check_runs[]|select(.name|test("Console gate|Elixir gate|Cloud gate|active task"))|[.name,.conclusion,.completed_at]|@tsv'
    Console gate    failure   2026-08-07T00:53:01Z
    Cloud gate      success   2026-08-07T00:52:58Z

Stamping "all four green" over a recorded `failure` is the same sin at a new address, so the row
is **held and flagged**. That the Console gate went red on a commit that IS on `main` is a
separate, real finding, filed as its own row.

**(c) Fifteen rows carry MORE than one unmet criterion** (the brief said twelve — drift). None
closed. Listed with their remaining work in the task's criterion-3 evidence. Three of them
returned **zero** merged PRs from branch-string search — `dr-w2-s1-recorder-build-id-keyed-log`,
`dr-w2-s6-engine-one-extractor-health-slow-vs-broken` and (not in the brief)
`dr-w8-s1-ledger-names-cause-and-denominator`. Their claimed links to #9727/#9733 rest on PR
**body text**, which is materially weaker than the branch + merge-commit + ancestry chain behind
every close here. They stay open on their own merits; the LINK wants a human eye.

**Five rows have a single merge gate but no merged PR at all** —
`dr-bl-w6-site-deploy-apply-unset-costs-16pct-of-failures` (no branch anywhere in the row),
`dr-w10-s1-verdict-reads-the-deploy-rate`, `dr-w15-s2-graph-code-split-and-agency`,
`dr-w18-s1-census-reader-reaches-the-team-door`, `dr-w8-s6-raw-capture-stops-leaking`. Genuinely
unlanded, correctly open.

## 7. The repair duplicates, collapsed

`dr-w9-s4-webhook-doctype-filter-reaches-live-rows` is the row that actually RAN the reconciler
(worker `epic-builder-the-doc-type-filter-reaches-the-five-liv`, 2026-08-07T03:48:50Z, PR #10082
merged 04:09:13Z, merge commit `8ae30b34bfc858184f6f1702a2dce57843903987`). Three rows were
carrying that same repair as outstanding:

- **`dr-w1-s4-webhook-doctype-filter` — CLOSED 8/8.** Criterion 2 stamped from dr-w9-s4's live
  BEFORE(`types=[]`)/AFTER(`types=[paper]`) run, carrying its honest caveat forward verbatim (the
  first buggy dry run wrote 4 of 5 rows; `9121449d` was reset and re-repaired by the fixed
  binary — which is why the five `updated_at` split 03:43:23–24Z ×4 and 03:46:27.036Z ×1).
  Criterion 3 stamped with the rate pair **381.8/hr → 23.2/hr, 93.9% cut**, 18h symmetric windows
  either side of 2026-08-07 03:46:11Z, corroborated at a second denominator by dr-w9-s4's
  **77.0 → 5.3 per hour per endpoint (93.1%)**. Criterion 7 stamped with PR #9616,
  `602feb889364d3b15269cf42b1bd7662cb1d7fe7`, ancestor of origin/main.
  *Honest limit, recorded on the row itself:* the 381.8/23.2 pair is this wave's verified pin,
  cited and not re-measured here; the 93.1% corroboration IS re-readable off stored evidence.
- **`dr-w1-s4-followup-repair-live-webhook-types` — CANCELLED**, not done: it shipped nothing,
  dr-w9-s4 did. Disposition names dr-w9-s4, its worker, and #10082's merge commit.
- **`dr-w11-bl-webhook-types-leak-unexplained` — SUPERSEDED and closed** citing charter **D207**,
  which rules the 03:46:11Z stop to be the filter repair's own five `updated_at` stamps. Its
  title asserted the stop was unexplained; that assertion is what kept re-opening the hunt.

Re-read 2026-08-08, `bp webhook ls -d production`: all five `site-autodeploy-*` rows carry
`types: ["paper"]`.

## 8. Guards that fired — three refusals worth keeping

The sweep took three tries, and every refusal was correct:

1. Flipping the criterion inside the close body → *"that would be the closer grading its own
   homework."* Split into stamp-then-close.
2. Stamping a `MERGE-GATED` criterion as a builder → refused client-side: *"that row is the
   lead's to close (a builder flipping it fabricates a done before the PR exists)."* This slice
   is the lead-authorised gate close, so it passes `--merge-gated` **explicitly**, and every
   evidence string on every closed row says so.
3. A claimed row refuses a foreign claim (`not_ready`) — one row was in flight and skipped.

A ledger whose write path can refuse a bad write is the thing this epic keeps asking of its
reporting. Five more rows were lost to server rate limiting mid-sweep and retried with backoff;
all five then closed.

**Filed from this sweep:** `dr-bl-w19-console-gate-red-on-a-merged-main-commit` — a required
context recorded `failure` on a commit that is on `main`, and nothing reported it. That is this
epic's subject appearing inside its own bookkeeping.

## 9. Measured before and after

Gate command, run before any write and again after the last one:

    bp task get task-fb4fb869490b4213 -o json | python3 -c "import json,sys;d=json.load(sys.stdin);\
    ch=d['children'];print(len(ch), sum(1 for c in ch if c.get('criteria_progress') \
    and 0<c['criteria_progress']['met']<c['criteria_progress']['total']))"

| | children | partial | open | in_progress | done | cancelled |
|---|---|---|---|---|---|---|
| BEFORE | 352 | **76** | 330 | 5 | 13 | 4 |
| AFTER | 353 | **29** | 274 | 8 | 66 | 5 |

The fall is 47 against a 52-row manifest, and the difference is accounted for rather than waved
at: **76 − 52 (closed here, every one verified no longer partial) + 5 new partial rows created by
wave-19 siblings running concurrently** (`dr-w19-s1`, `dr-w19-s2`, `dr-w19-s3`, `dr-w19-s4`, and
this row itself) **= 29.** Exact, no residue. `done` moved 13 → 66 (+53: the 52 manifest rows plus
`dr-w11-bl`, which was 0/1 and so never counted as partial); `cancelled` 4 → 5.

One row in the manifest could not be closed: `dr-w2-s4-scrub-knows-our-own-token` is held by a
live foreign claim (`not_ready`). Correct behaviour; left alone.

## 10. The count that matters

**282 rows still carry real remaining work** — 274 open plus 8 in progress. Of those, **247 sit
at 0-of-N criteria met** (untouched), 29 are partially met, and **6 have no criteria defined at
all** and therefore cannot be graded.

The epic now reads 66 of 353 done — **18.7% finished, 79.9% not**. Before this sweep it read
3.7% finished. That 15-point jump is entirely paperwork. Nothing shipped today because of it. Its
only real value is that the next wave's strategy will be built on a board that distinguishes a
done thing from an undone one — which is exactly what wave 19 did not have when it opened on a
repair that had already run.

