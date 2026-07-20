<!-- doc-tier: human | canonical-for: pds-crown-fence-arithmetic | budget: 6000tok -->

# The attribution-fence arithmetic, pre-declared — 2026-07-20

This file is written **before** the wave-10 climb fires, deliberately. Every reading below is a
reading of text that already exists on the server; none of it depends on what the climb returns.
Pre-declaring costs nothing while the outcome is unknown and is worth a great deal afterwards,
when the incentive to read the fence loosely is at its highest.

Subject: **criterion 11 of `pds-w1-crown-proof`** — the SINGLE-RUN ATTRIBUTION FENCE. It was added
by the wave-9 ledger-fence work and says the crown may not close on a mosaic.

All census figures below come from one live read of `pds-w1-crown-proof` taken at the start of
this slice (`bp task get pds-w1-crown-proof -o json`), before anything in this wave was stamped.

---

## 1. Indices are ZERO-BASED, so "criteria 0-10" INCLUDES criterion 10

The fence's satisfaction clause (a) reads "re-prove criteria 0-10 from ONE serial climb". That
span is eleven criteria, not ten, and the eleventh of them is criterion 10 itself — the
merge-gated one.

Evidence that indices are zero-based:

- `.claude/workflows/bp-pds-charter.md:1212` — **PDS-D149**: "Criterion indices are ZERO-BASED,
  and the crown's substantive rung is index 6."
- `internal/cli/onramp_cmd.go:335` — "N is ZERO-BASED (first = 0)".
- `internal/cli/mcp_tasks.go:565` and `:586` — "criterion is the ZERO-BASED index into
  acceptance_criteria: the FIRST criterion is 0, the second is 1 — do NOT pass a 1-based number."

So the fence's own arithmetic is: 12 criteria total (indices 0-11); the fence is index 11; the
span it governs is indices 0-10 inclusive; criterion 10 is inside it.

### The live run-id census

Twelve criteria. Nine read `met=true`. **Exactly one evidence field names a run id at all.**

| idx | met | criterion bytes | evidence bytes | run id in evidence |
|---:|---|---:|---:|---|
| 0 | true | 245 | 597 | **`20260720T032558Z-28651`** |
| 1 | true | 169 | 568 | — |
| 2 | true | 242 | 454 | — |
| 3 | true | 138 | 455 | — |
| 4 | true | 254 | 552 | — |
| 5 | true | 852 | 501 | — |
| 6 | false | 2504 | 0 | — |
| 7 | true | 155 | 393 | — |
| 8 | true | 186 | 685 | — |
| 9 | true | 1106 | 1188 | — |
| 10 | false | 918 † | 0 | — |
| 11 | false | 1252 | 0 | — |

(Census method: regex `\d{8}T\d{6}Z-\d+` over each `evidence` string. Byte counts are UTF-8.)

> † **Criterion 10's text moved while this file was being written.** A re-read taken minutes after
> the census showed 918 → 948 bytes: a concurrent wave-10 actor replaced "in the wave-9 transcript"
> with "in the transcript of the wave that pays this criterion" (one edit, `REPLACE 'the wave-9
> transcript' -> 'the transcript of the wave that pays this criterion'`; `updated_at`
> 12:07:22.864095Z → 17:06:39.455248Z). The change is correct and welcome — it de-hardcodes wave 9
> — and **no `met` flag, no `evidence` field and no array length changed** (12 → 12, 9 met → 9 met).
> It is recorded here because it is a live instance of the hazard the crown ledger's Standing note
> (PDS-D165) describes: `bp doc patch` is unfenced by claim or epoch, replaces the WHOLE array, and
> raises no error on either side. Two actors edited this array today without either seeing the
> other. **Anyone re-stamping criterion 10 must re-read its text immediately before the stamp** —
> the `--criterion-text` guard compares byte-for-byte, so a text copied from this file, or from the
> crown ledger, or from any read older than a few minutes, may 409 as a mismatch.

The fence's own text asserts the same thing — "ONLY criterion 0 names a run at all
(20260720T032558Z-28651); criteria 1,2,3,4,5,7,8,9 carry evidence with NO run id" — and the live
read confirms it is still true today. **Consequence: all nine met criteria need re-anchoring.**
Eight of them name no run; criterion 0 names a run that is not the run this wave will produce.
There is no subset of the current ledger that already satisfies the fence.

---

## 2. Wave 9's run id can NEVER pay criteria 3 and 4 — so criterion 6 must be RE-EARNED

The tempting cheap path is to re-anchor the nine met criteria to the wave-9 run id and stamp
criterion 6 from it. That path is arithmetically closed, and the closure is in wave 9's own
transcript.

`scripts/pds-pull-proof.crown-transcript-w8.txt:322` (rung 3), verbatim:

```
  3     ABORT    env:full-export-unavailable — cond_b FAILED (1249 MB vs floor
```

`scripts/pds-pull-proof.crown-transcript-w8.txt:324` (rung 4), verbatim:

```
  4     ABORT    env:full-export-unavailable — cond_b FAILED (1224 MB vs floor
```

Both rungs aborted because the **full** export never materialised (a ~1.2 GB body against a
2200 MB floor). Now read what criteria 3 and 4 actually demand:

- **Criterion 3** (verbatim): "The ticket-deny leg is proven by a BYTE-SCAN with a firing control
  on the full bundle and zero on the dev bundle — never by a count diff". The control must fire
  **on the full bundle**.
- **Criterion 4** (verbatim): "…while the 8-webhook positive control FIRES on the full-fidelity
  bundle with exit 1 — same binary, same run-time-derived ammo…". Again, **on the full bundle**.

A run whose full export never happened cannot produce either firing control. Wave 9's transcript
says so itself at :324 — "the positive control off the full bundle could not be taken, so the rung
is honestly ABORT rather than a clean-without-a-firing-control PASS."

**Therefore: the wave-9 run id can never pay criteria 3 and 4, and a single run id that pays
criteria 0-10 must be a run in which the full export succeeded. Criterion 6 must be re-earned
under that same run.** The memory physics (the post-deploy window is what makes the full export
reachable at all) and the fence arithmetic point at the identical conclusion: one fresh serial
climb, full bundle real, rungs 3, 4 and 6 all green in it.

---

## 3. The fence's two verbs disagree about criterion 10 — resolved here, in advance

The fence contains two clauses that impose different obligations on the same criterion:

- The **requirement** clause: "Every one of criteria 0-10 must **cite** ONE IDENTICAL RUN_ID".
  *Cite* is satisfiable for a merge event — you can write a run id into criterion 10's evidence.
- Satisfaction option **(a)**: "**re-prove** criteria 0-10 from ONE serial climb and stamp each
  with that run's id in the evidence". *Re-prove from a climb* is **not** satisfiable for
  criterion 10, because no climb produces a merge to main. Read literally, option (a) is
  impossible for criterion 10 — which would make the fence unsatisfiable by construction.

That contradiction must not be discovered during the close, when whoever finds it is also the
person who benefits from resolving it loosely. Resolving it now:

**SAFE CONSTRUCTION — criterion 10's evidence carries the PR number and the merge sha (the actual
proof of the merge event) PLUS the climb's run id, explicitly LABELLED as attribution rather than
proof.** Shape:

> PR #NNNN merged to main, sha `<merge-sha>`, mergedAt `<ts>`. Run attribution (not proof of this
> criterion): `<RUN_ID>` — the serial climb that paid criteria 0-9. A merge is not produced by a
> climb; the run id is recorded here to satisfy the fence's single-run citation requirement.

This satisfies the requirement clause literally (criterion 10 cites the same run id as every
other), satisfies the spirit of option (a) (the merged work *is* the climb's work), and costs
nothing — it is one extra sentence. It also does not lie: the label states plainly that the run id
is not what proves the merge. **A reading that quietly drops the run id from criterion 10 is not
acceptable**, because the fence's stated purpose is that *every* criterion in 0-10 be traceable to
one run.

---

## 4. The two stamp hazards, both already proven live

Both of these have bitten this epic. They are recorded here so the climb's lead does not
rediscover them at the worst moment.

### Hazard A — criterion 6's stored text contains literal BACKTICKS

`--met` is refused without `--criterion-text`, and the text must match the stored row byte for
byte (`409 criterion_text_required` / `409 criteria_mismatch` — see `internal/cli/mcp_tasks.go:565`).
A quoting census over all twelve stored criteria:

| idx | contains backtick | contains `'` | contains em dash |
|---:|---|---|---|
| 0 | no | no | no |
| 1-4 | no | no | 1,3,4 yes |
| 5 | no | **yes** | yes |
| **6** | **YES** | **yes** | yes |
| 7-8 | no | no | 8 yes |
| 9 | no | no | yes |
| 10 | no | no | yes |
| 11 | no | **yes** | yes |

Criterion 6 contains `` `command` ``, `` `paper` ``, `` `task` ``, `` `tag` `` and
`` `pull_provenance` ``. Inside a double-quoted shell argument those backticks are **command
substitution** — the shell executes them and substitutes the (empty) output, so the text that
reaches the server is silently *not* the stored text, and the stamp 409s with a mismatch that
looks like an index error. Criteria 5, 6 and 11 additionally carry single quotes, so single-quoting
the whole argument is not a general escape either.

**Rule: never type a criterion's text inline. Fetch it to a file and pass it by substitution.**

```bash
bp task get pds-w1-crown-proof -o json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["doc"]["content"]["acceptance_criteria"][6]["criterion"], end="")' \
  > /tmp/c6.txt
bp task stamp pds-w1-crown-proof <worker> <epoch> --criterion 6 \
  --criterion-text "$(cat /tmp/c6.txt)" --met --evidence "<terse>"
```

(`"$(cat f)"` is safe: command substitution of `cat` yields the bytes literally; the backticks
inside them are never re-scanned by the shell.)

### Hazard B — the ~9-11 KB query-string ceiling

`--evidence` and `--criterion-text` are **not** sent in the request body. They ride the URL query
string. The transport is manifest-driven:

- `internal/cli/run.go:557-614` — `applyQuery` adds every manifest-declared string flag to
  `url.Values` and appends `"?" + q.Encode()`.
- `internal/cli/run.go:771-781` — `commandFlagBelongsInBody` returns `true` **only** for
  `cmd.ID == "cycle.open"`. `task stamp` is not that command, so *every* one of its string flags
  is a query parameter.

Past roughly 9-11 KB combined, the request dies as an opaque HTTP/2 stream reset that reads like a
network blip rather than a size limit — the failure mode gives you no hint of its cause.

The criterion texts alone already consume a large share of that budget, and URL-encoding inflates
them further (percent-encoding of spaces, em dashes and punctuation):

| idx | characters | UTF-8 bytes | **URL-encoded bytes** |
|---:|---:|---:|---:|
| 5 | 846 | 852 | **1190** |
| 6 | 2490 | 2504 | **3478** |
| 9 | 1098 | 1106 | **1514** |

Criterion 6's text is ~3.5 KB on the wire before a single byte of evidence is added — a third of
the ceiling, spent on the mandatory guard.

**Rule: keep every evidence string TERSE — a run id plus a one-line transcript pointer
(`RUN_ID … see crown-transcript-w10.txt:NNN`), never a pasted block.** The transcript is the
durable artifact; the evidence field is an index into it.

---

## 5. The order (the close is the dangerous act)

1. LEAD claims the crown (`pds-w1-crown-proof`).
2. LEAD re-stamps criteria 0-9 with the fresh climb's run id.
3. Merge to main.
4. LEAD stamps criterion 10 with the §3 construction (PR + sha + labelled run id).
5. **Criterion 11 is DEFERRED — stamped last, deliberately and separately.**

Step 5 is not ceremony. `hookStopClose` closes the task when every criterion reads met, with
nobody typing a close command (`cmux_hook.go:193-252`; charter `PDS-D189` at
`.claude/workflows/bp-pds-charter.md:1530`). The met-flip on criterion 11 is therefore the act
that removes the last automatic brake. It must be the last thing that happens, taken knowingly, by
the lead, after the run ids have been read and compared.

The fence itself says the same: "The LEAD verifies the run ids are identical before this is marked
met — it is never stamped by a builder alongside the rung it just ran."

## 6. Refusal remains a first-class outcome

The fence names two honest endings, not one: (a) re-prove from one serial climb, or (b) "explicitly
REFUSE the crown, naming the rung that failed." Wave 9 took (b) on `cond_b`. If the full export is
not reachable in this window either, (b) again — in writing, naming the rung — is the correct
result and not a failure of this wave. A mosaic is the only outcome the fence forbids.
