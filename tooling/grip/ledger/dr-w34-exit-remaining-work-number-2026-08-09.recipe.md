# RECIPE — the deploy-reliability epic's REMAINING-WORK number (exit artefact input)

Wave 34, verifier `exit-number-adjudication`, 2026-08-09 22:45–22:50Z.
This file stores **commands**, not values. Every number below is re-derived by running the
command beside it. A stored count is stale the moment a task closes.

Epic id: `task-fb4fb869490b4213`  ·  origin/main tip at authoring: `45e26115527c875f50769eb7df922b0f97842be8`

---

## R1 — the raw roster partition (one `bp` read, five numbers)

```sh
bp task get task-fb4fb869490b4213 -o json > /tmp/dr.json
jq -r '
  .children as $c
  | ($c | map(select(.lifecycle_status=="open" or .lifecycle_status=="in_progress"))) as $live
  | ($live | map(select((.criteria_progress.total // 0) == 0)))                                   as $zero
  | ($live | map(select((.criteria_progress.total // 0) > 0 and .criteria_progress.met == .criteria_progress.total))) as $full
  | ($live | map(select(.doc_id|startswith("drafts."))))                                          as $draft
  | "total_children=\($c|length)",
    "live=\($live|length)  (open=\($c|map(select(.lifecycle_status=="open"))|length) in_progress=\($c|map(select(.lifecycle_status=="in_progress"))|length))",
    "zero_criteria=\($zero|length)",
    "at_100pct=\($full|length)",
    "draft_shadows_live=\($draft|length)   \($draft|map(.doc_id)|join(", "))",
    "GENUINE_OPEN=\(($live|length)-($zero|length)-($full|length))"
' /tmp/dr.json
```

Reading taken twice, 140s apart (22:45:04Z / 22:47:24Z) — raw JSON **byte-identical**:
`total_children=319 live=172 zero_criteria=7 at_100pct=0 draft_shadows_live=1 GENUINE_OPEN=165`.

## R2 — the second instrument, and why it reads one lower

```sh
# a full-history clone parked at origin/main (the primary checkout is divergent — see R4)
node <repo>/cloud/priv/static/__preview__/seal-predicate.mjs \
     --epic task-fb4fb869490b4213 --successor TERMINAL
```
→ `REFUSED … TERMINAL claims this epic has no residue to forward, and the roster read refutes it:
**171 live row(s)** … and 0 considering row(s)`, `VERDICT-TOKEN: SEAL-PREDICATE REFUSED
reason=TERMINAL-CLAIM-REFUTED a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED`.

`171 = 172 − 1`: the predicate's roster fences out `drafts.*`. Re-derive the delta:

```sh
jq '[.children[]|select((.lifecycle_status=="open" or .lifecycle_status=="in_progress")
     and (.doc_id|startswith("drafts.")|not))]|length' /tmp/dr.json     # -> 171
```

**No orphan count is obtainable for this epic today.** Without `--successor` the predicate refuses
`NO-SUCCESSOR`; with `TERMINAL` it refuses `TERMINAL-CLAIM-REFUTED`. Clause (a) never evaluates, so
`orphans=` is never printed. Any quoted `orphans=170` has no live re-derivation.

## R3 — the draft shadow is NOT a duplicate (this is what refutes "164")

```sh
jq -r '[.children[].doc_id] | map(sub("^drafts\\.";"")) | group_by(.)
       | map(select(length>1)) | .[] | .[0]' /tmp/dr.json
```
→ six base ids, every one with a **cancelled** draft side, and **`dr-w26-hg-gyldendal-operator-packet-corrected`
is not among them**: the live draft has no published twin. Deducting it removes a real open human gate,
it does not remove a double count. Its unpublishability is itself a tracked defect —
`dr-w27-bl-gyldendal-packet-409s-on-the-dedup-wall` ("the corrected gyldendal operator packet cannot be
published"), so the row can legitimately live at `drafts.<id>` indefinitely.

## R4 — provenance fences that bit this reading (run BEFORE quoting anything)

```sh
git -C /Volumes/SATECHI/github/barkpark ls-files scripts/seal-run.sh | wc -l   # -> 0   (NOT in the primary checkout)
git -C /Volumes/SATECHI/github/barkpark cat-file -e origin/main:scripts/seal-run.sh && echo YES   # -> YES
git -C /Volumes/SATECHI/github/barkpark rev-list --left-right --count main...origin/main          # -> 49  828
df -h / | tail -1                                                                                  # -> 117Mi avail, 99%
```

Two independent reasons the sanctioned wrapper cannot be run where the owner stands:
1. `scripts/seal-run.sh` is on `origin/main` but absent from the primary checkout's index (divergent: 49 ahead / 828 behind).
2. The root volume is full. `bash scripts/seal-run.sh --repo <clone at origin/main> --epic task-fb4fb869490b4213`
   exits **7 — REFUSED, nothing was read**: `mktemp: mkstemp failed on /var/folders/…/T/seal-run.XXXXXX:
   No space left on device`, and `line 146: cannot create temp file for here document`. Exporting `TMPDIR`
   to a volume with 1.5Ti free does not move it. Exit 7 is correctly *not* a NO-SEAL — it is a fact about
   the host, and the host is the thing the exit artefact promises to run on.

## R5 — the local charter is stale; brief from origin

```sh
git -C <repo> show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | wc -l   # 11697
wc -l /Volumes/SATECHI/github/barkpark/.claude/workflows/bp-deploy-reliability-charter.md   # 11617
```
80 lines apart. Line-number citations taken against the working copy do not resolve on `origin/main`.

## R6 — the two instants, on origin/main only

```sh
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -n '21:13:50\|22:57:53'
```
Four hits for `21:13:50Z` (:6250, :10347, :10622, :11416) — always the **taxonomy/settle boundary**, the
`#9615` merge instant, always written with `Z`. Five hits for `22:57:53` (:2177, :2707, :3787, :10624, :11354) —
always a **data instant**: the single last-ever `already_running` row written `failed`, site `7c2025a5`, which is
also the 6/6 `BOX_BUSY_DEFERRED` abandonment. One row, one instant, three labels; `Z` present at :2707/:3787 and
absent at :2177/:10624/:11354. They are not two competing boundaries — :11416 already says so in words.
