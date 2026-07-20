<!-- doc-tier: human | canonical-for: pds-crown-ledger-amendment | budget: 6000tok -->

# The crown ledger amendment of 2026-07-20 — two defects, one write

`pds-w1-crown-proof` is the PDS crown task: **twelve** acceptance criteria, nine of them
already met from the wave-7 climb. This file is the committed record of the only two
edits made to its stored criterion WORDING during wave 9, why each was made, and what
guarantees the edit route does and does not give.

> **Count correction (2026-07-20, wave 10).** This header read "eleven acceptance
> criteria" until the amendment in [§ Criterion 11](#criterion-11--the-single-run-attribution-fence-added-after-this-record-was-written)
> at the foot of this file. A twelfth criterion — the SINGLE-RUN ATTRIBUTION FENCE — was
> added to the array *after* the body below was written, and nothing updated this record.
> **Everything from "What was wrong" down to "Standing note" describes the ELEVEN-entry
> array as it stood at the wave-9 amendment and is left unedited on purpose** — it is an
> accurate historical account of that write, and its `{"met": 9, "total": 11}` figures are
> correct *as of that moment*. The live array today is twelve. Read the foot of this file
> before repairing anything from the body.

## What was wrong

**Defect 1 — criterion 6's PDS-D153 parenthetical had its scope inverted (PDS-D161).**
The sentence conceding that the banner's "sentinelled in all eight guarded columns" is
one column short of literally true explained the shortfall as a single-row exception:
visibility "is a literal, hence a no-op on the already-private `ticket` row". Measured
on a live booted target the roster is the other way round. Four rows table-wide declare
public — `command`, `paper`, `tag`, `task` — and `tag` sits outside the guarded 34, so
within the 34 it is 3 public against 31 private. The literal `private` write is therefore
a no-op on roughly 31 of 34 rows, and the `visibility` column's entire capacity to move
under leg B rests on the 3 that are public. As worded, a reader would dismiss a
roster-wide hazard — already filed as `pds-bl-legb-visibility-false-red` — as one row.

**Defect 2 — criterion 10 was an unprotected 55-byte honour-system line (PDS-D163).**
It read, in full, "PR merged to main (LEAD closes this criterion on merge)", and no
`merge_gate` key existed anywhere in the document (20 criteria parsed across the ledger,
zero occurrences). With criteria 0-5 and 7-9 already met, criterion 6 plus criterion 10
completes 11/11 — and `cmux_hook.go:193-237` closes the task unconditionally on the next
Stop event once the count is full. Nobody has to type a close command. That is the
PDS-D138 false close, which has already fired once on this exact task, re-armed in a
shape that requires no human act at all. The fix is not a mechanism (there is no
`merge_gate` field to set) but the strongest thing the stored text can do: forbid the
stamp in the criterion's own wording, and name the two rungs that must be green first.

## What was NOT touched

Criterion 6's sentinel amendment (PDS-D160) was already landed before this wave's build
slice ran, and was deliberately left alone. Rewriting it would have clobbered live
citations to decisions that are still off-main. Exactly one contiguous clause inside it
changed; the assertion `old.replace(OLD_CLAUSE,'@@') == new.replace(NEW_CLAUSE,'@@')`
was checked before the write and holds, so no other byte in the 2244-character field
moved. Citation counts on the server-read text after the write are identical to before:
D130 x1, D145 x2, D146 x1, D153 x1, "LEG A" x1, "LEG B" x1.

No `met` flag and no `evidence` field moved anywhere in the document.
`criteria_progress` reads `{"met": 9, "total": 11}` on both sides, with criteria 6 and 10
still `met=false` and their evidence still empty. Criteria 0, 1, 2, 3, 4, 5, 7, 8 and 9
are byte-identical before and after in criterion text, met flag and evidence alike.

## Revisions

| point | rev |
|---|---|
| before (published, `updated_at` 2026-07-20T06:50:39.617105Z) | `cae584bc88ddfb31aaa2649a3912b827` |
| `bp doc patch` draft, 10:08:38Z | `3e4ea0e2c752b186d6d7194004730ae6` |
| `bp doc publish`, 10:08:39Z | `4df68c2164ac6f55c0a9a4b357cafe20` |
| settled published, verified 10:08:54Z | `e21b15d50824a097240638750af16f2d` |

`claim.worker` was `null` in the read taken immediately before the write and `null` in
the read taken after; `lifecycle_status` stayed `open` throughout.

## Criterion 6 — the changed clause

Before:

> (visibility is a literal, hence a no-op on the already-private `ticket` row)

After:

> (visibility is written as the literal 'private', hence a no-op on the ~31 of the 34
> guarded rows that are already private — only `command`, `paper` and `task` declare
> public inside the guarded 34, `tag` being the fourth public row table-wide but outside
> them, so that column's entire ability to move rests on those 3 rows)

Field length 2244 -> 2490 characters.

## Criterion 10 — before and after, verbatim

Before (55 bytes):

> PR merged to main (LEAD closes this criterion on merge)

After (914 characters), read back from the server:

> PR merged to main (LEAD closes this criterion on merge). MERGE-GATED — DO NOT STAMP EARLY (PDS-D163). Criteria 0-5 and 7-9 are already met from the wave-7 climb, so this criterion plus criterion 6 completes 11/11, and cmux_hook.go:193-237 then closes this task UNCONDITIONALLY on the next Stop event with nobody typing a close command — the PDS-D138 false close, which already fired once on this exact task, re-armed in a shape no human has to type. Therefore: this criterion is NOT to be stamped until rungs 3 and 4 are GREEN in the wave-9 transcript (rungs 3 and 4 read off the ONE full bundle, rungs 1/2/5/6 against a real booted target, every rung passing WITH its controls FIRING), and then only by the LEAD on an actual merge to main. A stamp taken before those two rungs are green in-transcript is a false close, not a completion; if any rung fails, name it in the transcript and leave this criterion unmet.

## Criterion 6, full stored text after the amendment

For the record, so a later reader can diff the field without a live server:

> Step 6 proves CONTENT-AND-PRESENCE convergence of the imported rows across a REAL reboot — explicitly NOT byte-identity of two independently produced bundles, which PDS-D30 rules impossible for :full and claims for the :dev profile only. After the SINGLE --merge pull of step 1 (step 6 ABORTs naming step 1 if no pull ran this run), the target carries a non-empty pull_provenance stamp for the pulled dataset. A DELIBERATE SENTINEL is then written into the eight guarded columns of the 34 non-{tag,metric} rows BEFORE the first reboot — without it the rung measures NOTHING IN EITHER DIRECTION, because step 0b pins the target to guerrilla's sha so Bootstrap's clobber writes byte-identical declarations and leg A would hold with the guard DELETED (the wave-8 finding, PDS-D145/D146). LEG A: the eight-column md5 digest — title, icon, visibility, owner_scoped, fields, cors_origins, desk_groups, list_preview, string_agg ORDER BY (dataset, name), that pair being the table's actual unique index, with rows=count(*) appended — is unchanged across a reboot with the stamp PRESENT, AND the PER-COLUMN comparison names ZERO changed columns, proving the drifted rows SURVIVE. LEG B: with PDS_STEP6_GUARD_DEMO=1 the stamp is cleared by SQL whose RETURNING value is ASSERTED to contain the dataset key, the target is booted a second time, and the PER-COLUMN comparison shows EVERY guarded column moved — a whole-table digest change alone is necessary and NOT sufficient (PDS-D130). The RETURNING sentinel count matches the server.log Bootstrap SKIP count, counted under the 'Plugins.Bootstrap: schema' prefix ALONE and never summed with TagRegistry's separate 'TagRegistry: core' line (PDS-D145). A pass carrying the 'guard-off control was DISABLED (PDS_STEP6_GUARD_DEMO=0)' note does NOT satisfy this criterion, and neither does a pass whose leg A ran without the sentinel. The transcript states that the target is left deliberately CLOBBERED by this control, and that steps 2 and 5 are sequenced before it for that reason. Per PDS-D153 the banner's 'sentinelled in all eight guarded columns' is one column short of literally true (visibility is written as the literal 'private', hence a no-op on the ~31 of the 34 guarded rows that are already private — only `command`, `paper` and `task` declare public inside the guarded 34, `tag` being the fourth public row table-wide but outside them, so that column's entire ability to move rests on those 3 rows) — do not quote it verbatim as proven fact.

## Standing note — this route is unfenced (PDS-D165)

Criterion wording can only be rewritten by `bp doc patch`; `bp task stamp` and
`bp task close` never touch stored text (`internal.ex:51`). `bp doc patch` is **not**
fenced by claim or epoch. It does not check who holds the task, it does not check an
epoch, and it does not fail on a concurrent write. `--set 'acceptance_criteria:=[...]'`
replaces the WHOLE array, so any actor who patches with a stale copy of the array
silently reverts every criterion they did not carry forward.

The practical consequences, all of which apply to **this** amendment as much as to the
defects it repaired:

- Both edits recorded here are **equally overwritable** by any concurrent actor, with no
  error raised on either side. Nothing in the system protects them. This file is the
  durable copy; the server's copy is not.
- The amendment was made while the task was unclaimed **by choice, not by enforcement** —
  the route would have accepted the write against a live claim just the same.
- `bp doc patch` is eventually consistent and the lag is invisible to every read
  perspective, published and drafts alike (PDS-D166), so a verification read must POLL.
  An immediate read-back reads stale and tempts a second write to the crown ledger.
  Measured this run: one write at 10:08:38Z, visible at 10:08:54Z on the first poll —
  the 20-30s staleness window PDS-D166 measured did not reproduce, plausibly because the
  explicit publish forced the projection. The poll loop was armed regardless and exactly
  one write was issued.
- Anyone repairing this document again should re-read the full array immediately before
  patching, change only the strings they intend to change, assert the untouched entries
  byte-identical, and record the revs here.

---

## Criterion 11 — the SINGLE-RUN ATTRIBUTION FENCE, added AFTER this record was written

Appended 2026-07-20 (wave 10). **Why this section exists:** before it, the fence lived in the
live task array and *nowhere else* — no charter decision, no ledger entry, no verdict file.
A grep for "attribution fence" / "MOSAIC" across `.claude/workflows/bp-pds-charter.md` and
`scripts/pds-crown-*.md` returned only `PDS-D179`, which is about a *different* mosaic question
and explicitly "must never be cited as if it says 'mosaic forbidden'". Meanwhile this file
declares itself the crown's durable recovery source — "This file is the durable copy; the
server's copy is not" — while describing an ELEVEN-entry array.

That combination is a silent-deletion trap. The documented repair procedure at the foot of this
file is to "re-read the full array immediately before patching, change only the strings they
intend to change, assert the untouched entries byte-identical". Anyone who instead reconstructs
the array from *this record* — its designated purpose — rebuilds eleven entries and drops the
fence. `bp doc patch --set 'acceptance_criteria:=[...]'` replaces the WHOLE array and raises no
error on a shortened one, and the fence's own job is to block an automatic close, so its removal
would surface as the crown closing *more* easily, not as a failure. Neither side reports
anything. Hence: the text goes here, verbatim.

### Verbatim stored text, index 11 (1252 UTF-8 bytes)

> SINGLE-RUN ATTRIBUTION FENCE (added by the wave-9 ledger-fence slice, pds-w9-crown-ledger-fence). The crown may not close on a MOSAIC. Every one of criteria 0-10 must cite ONE IDENTICAL RUN_ID, and that run must be the run whose full bundle actually existed. As of the fence being added, 9 of 11 read met but ONLY criterion 0 names a run at all (20260720T032558Z-28651); criteria 1,2,3,4,5,7,8,9 carry evidence with NO run id, so they cannot be attributed to any climb. A fresh climb produces a fresh RUN_ID, so stamping criterion 6 from it would pay the crown with a run that proved none of the other nine. THIS CRITERION EXISTS PARTLY TO BLOCK THE AUTO-CLOSE: the cmux Stop hook closes the task when every criterion reads met, with nobody typing a close command — so an 11-of-11 mosaic would close the crown silently. With this 12th criterion present, that cannot happen by default. TO SATISFY: either (a) re-prove criteria 0-10 from ONE serial climb and stamp each with that run's id in the evidence, or (b) explicitly REFUSE the crown, naming the rung that failed. Both are honest outcomes; a mosaic is not. The LEAD verifies the run ids are identical before this is marked met — it is never stamped by a builder alongside the rung it just ran.

### Provenance correction

The fence's text credits itself to the wave-9 ledger-fence slice: "added by the wave-9
ledger-fence slice, `pds-w9-crown-ledger-fence`". **That attribution is not supported by that
slice's own record.** `pds-w9-crown-ledger-fence` (lifecycle `done`, 7 criteria) closed with AC-4
evidence reading, verbatim:

> criteria_progress before {'met':9,'total':11} -> after {'met':9,'total':11}. Per-criterion diff of met/evidence across all 11 rows: NONE changed (programmatic comparison of before vs after JSON). Criterion 6 after: met=False, evidence length 0. Criterion 10 after: met=False, evidence length 0. Criteria 0,1,2,3,4,5,7,8,9 byte-identical in criterion text AND met AND evidence. Key sets identical per row; array length 11 -> 11.

"array length 11 -> 11" is that slice proving it added no criterion. Its scope was the two
WORDING repairs recorded in the body above, and its evidence asserts the array length was
unchanged. So the fence was added by some *later* write that left no record of itself anywhere —
the mis-citation is recorded here rather than corrected in the stored text, because rewriting the
live criterion to fix a credit line would mean another unfenced whole-array patch (see the
Standing note) for no functional gain. **Treat "added by the wave-9 ledger-fence slice" as
unverified.** The fence's *content* is unaffected; only its authorship line is wrong.

### If you are repairing the crown array from this file

**Criterion 10's stored text has also moved since the body above was written.** The "After (914
characters)" quotation in [§ Criterion 10](#criterion-10--before-and-after-verbatim) is the wave-9
state and is now stale: a concurrent wave-10 patch on 2026-07-20 at 17:06:39Z took it to 948 UTF-8
bytes, replacing "in the wave-9 transcript" with "in the transcript of the wave that pays this
criterion" (verified against the live array at review time: 948 bytes, `wave-9 transcript` absent).
That edit changed no `met` flag, no `evidence` field and no array length. It is left
uncorrected above for the same reason as the rest of the body — it is an accurate record of the
wave-9 write — but **do not copy criterion 10's text out of this file to pass as
`--criterion-text`**; re-read it from the server immediately before any stamp.

The live array is **twelve** entries, indices 0-11 (zero-based, PDS-D149). Index 11 is the text
quoted above. Its `met` flag was `false` at the time of this writing, with empty evidence. Do not
patch an eleven-entry array over it. The pre-declared reading of what this criterion requires —
the run-id census, why wave 9's run id can never pay criteria 3 and 4, the cite-vs-re-prove
contradiction in the fence's own two verbs, and the two stamp hazards — is at
`scripts/pds-crown-fence-arithmetic-2026-07-20.md`.
