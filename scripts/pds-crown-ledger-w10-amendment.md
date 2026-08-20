<!-- doc-tier: human | canonical-for: pds-crown-ledger-amendment-w10 | budget: 3000tok -->

# The crown ledger amendment of wave 10 — criterion 10 off the wave-9 transcript

One edit, to one clause, in one criterion of `pds-w1-crown-proof`. This file is the
committed record of it: what the row said, what it says now, why the old wording made
the green branch unsatisfiable, and the proof that nothing else in the twelve-entry
array moved.

The wave-9 amendments live in `scripts/pds-crown-ledger-2026-07-20.md` and were not
touched by this write.

## The deadlock

Criterion 10 is the crown's merge gate. Its stored text said it is

> NOT to be stamped until rungs 3 and 4 are GREEN in **the wave-9 transcript**

That transcript is `scripts/pds-pull-proof.crown-transcript-w8.txt` — committed,
declared APPEND-ONLY by its own header at `:3`, and recording rungs 3 and 4 as **ABORT**
at `:322` and `:324`. Those two lines are permanent. The sentence therefore asserted a
condition about a fixed artefact that no future run can change.

There is no escape inside the harness. `scripts/pds-pull-proof.sh` contains **no output
redirection to any `.txt`** — every occurrence of the word "transcript" in it is prose
inside `say()` and error strings. Transcripts are hand-assembled per wave. So a wave-10
green necessarily lands in a *new* file, and a new file cannot make a sentence about the
wave-9 file true.

The one letter-of-the-law reading that would work — appending the wave-10 run into the
wave-9 file — produces a single transcript carrying **two run ids** for a reader to
stitch together. That is precisely the mosaic criterion 11 (the single-run attribution
fence) exists to forbid. It was considered and **REFUSED**.

The asymmetry that made this urgent rather than cosmetic: criterion 10 ends with
"if any rung fails, name it in the transcript and leave this criterion unmet", so the
defect **fails closed** on the refusal path. It blocks only the *green*. A climb that
fires green with this unfixed cannot be honestly stamped, and the post-deploy window is
spent for nothing.

## The edit

Exactly one substring, replaced once:

| | text |
|---|---|
| before | `rungs 3 and 4 are GREEN in the wave-9 transcript` |
| after | `rungs 3 and 4 are GREEN in the transcript of the wave that pays this criterion` |

In context, after:

> Therefore: this criterion is NOT to be stamped until rungs 3 and 4 are GREEN in the
> transcript of the wave that pays this criterion (rungs 3 and 4 read off the ONE full
> bundle, rungs 1/2/5/6 against a real booted target, every rung passing WITH its
> controls FIRING), and then only by the LEAD on an actual merge to main.

**What did not change.** The row keeps its merge-gating (`PR merged to main (LEAD closes
this criterion on merge)`), its `MERGE-GATED — DO NOT STAMP EARLY (PDS-D163)` warning,
the `cmux_hook.go:193-237` false-close rationale, the "only by the LEAD on an actual
merge to main" clause, and the fail-closed tail. The row stayed `met=false` with empty
evidence. No other criterion was edited. The bar did not move — a green transcript with
controls firing is still required, and the LEAD still stamps it, on a merge.

## The write discipline (PDS-D165)

`bp doc patch` on `acceptance_criteria` is **not** fenced by claim or epoch, and
`--set acceptance_criteria:=[...]` replaces the **whole array**. An actor writing from a
stale copy silently reverts every criterion they failed to carry forward. So the write
was driven by a script that:

1. read the live array immediately before writing (`bp task get pds-w1-crown-proof -o json`);
2. asserted `len == 12`, `met == 9`, and that the wave-9 clause was still present;
3. deep-copied the **live** array and applied a single `str.replace(OLD, NEW, 1)` to row 10;
4. asserted, **before sending**, that a per-row fingerprint `(criterion, met, evidence)`
   differed on row 10 alone, and that `before[10].replace(OLD, NEW, 1) == after[10]`;
5. patched, published, **re-read live**, and re-ran the same per-row diff server-side.

## The proof

Live read before — rev `9015bca22c77b7a94740698fbdab8ecd`; live read after patch+publish
— rev `38b2baef1faa09b1f8bf9fdfdb2ec064`.

```
BEFORE  len=12  met=9  progress={'met': 9, 'total': 12}
LOCAL DIFF ok: only row 10 text moved; met flags and evidence untouched
AFTER   len=12  met=9  progress={'met': 9, 'total': 12}
SERVER DIFF ok: rows 0-9 and 11 byte-identical; 6 and 11 still met=False evidence=''
PASS — criterion 10 re-worded, nothing else moved
```

Asserted after the round trip: `drift == [10]`; `criteria_progress` identical on both
sides; criteria **6**, **10** and **11** all still `met=false` with `evidence=""`; and
each of the three preserved phrases above present verbatim in the stored row.

Gate:

```
bp task get pds-w1-crown-proof -o json | python3 -c "import json,sys; d=json.load(sys.stdin)['doc']['content']['acceptance_criteria']; assert len(d)==12; assert sum(1 for c in d if c['met'])==9; assert 'wave-9 transcript' not in d[10]['criterion']; print('OK 12 criteria, 9 met, criterion 10 re-worded')"
→ OK 12 criteria, 9 met, criterion 10 re-worded
```

## What this does not give

The edit route is a whole-array replace with no epoch fence, so this record is evidence
of *one* write being clean, not a guarantee that the array cannot be clobbered later.
Any future actor touching `acceptance_criteria` on the crown task must repeat the
read-copy-diff-reread discipline above. The proof here is reproducible only against the
revs named — a subsequent write moves them.

Task: `pds-w10-crit10-deadlock-reword` (charter PDS-D196).
