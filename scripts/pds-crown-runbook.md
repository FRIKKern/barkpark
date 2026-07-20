<!-- doc-tier: human | canonical-for: pds-crown-proof-operating-procedure | budget: 6000tok -->

# PDS crown proof — operating runbook

How to run `scripts/pds-pull-proof.sh` end to end against the live guerrilla source
plane, and what to do with every colour it prints.

This runbook is written for the operator who fires the climb. It is deliberately
short on rationale and long on preconditions, because the expensive failures in
this proof are all environmental and all silent.

Companion artifacts:

- `scripts/pds-pull-proof.sh` — the instrument. **FROZEN** (see §6).
- `scripts/pds-scratch-target.sh` — boots/tears down the disposable local target.
- `scripts/pds-secret-scan.sh` — the value-based scanner, consumed by rung 4.
- `scripts/pds-pull-proof.crown-transcript.txt` — the append-only run record.

---

## 1. The one-paragraph shape

The harness climbs eleven rungs (`0a 0b 0c 1 2 3 4 5 6 7 8`) against two planes:
the **source** is live guerrilla (`157.180.90.121`), read-only; the **target** is a
disposable Barkpark booted on the operator's own host by `pds-scratch-target.sh`.
Nine rungs need only the cheap dev export (~7 s, ~53 MB). **Only rungs 3 and 4
consume the one budgeted full-fidelity export**, which is the firing control for
both of them. That export is the whole cost of the run and it is capped at a
single ATTEMPT — not a single success.

## 2. Preconditions, in the order they bite

### (a) One shared root, exported — not assigned

The harness pins `BARKPARK_HOME` and `PDS_SCRATCH_POINTER` per-invocation from a
`date+$$` run tag, while `pds-scratch-target.sh` mktemps its own root when they
are unset. Two unpinned invocations therefore allocate two *different* roots and
every target-reading rung aborts `env:scratch-target-not-booted` — which looks
exactly like an honest environmental blocker and is not one.

Pin them yourself, to one short root, in the shell that runs *both* commands:

```sh
export BARKPARK_HOME=/private/tmp/pds-w7
export PDS_SCRATCH_POINTER=/private/tmp/pds-w7.last
```

Use `/private/tmp/...`, not `/tmp/...`, on macOS. The pointer's write path
canonicalises with `cd -P` while its read path returns `BARKPARK_HOME` verbatim,
so a `/tmp` root can never string-match its own realpathed pointer and teardown
leaves it dangling. Naming the canonical path sidesteps the mismatch without
touching a frozen script.

### (b) `PDS_CONTROL_PG` must be EXPORTED

```sh
export PDS_CONTROL_PG=postgres     # or a fuller maintenance conninfo
```

Rung 4 gates its own instrument control on `[ -n "${PDS_CONTROL_PG:-}" ]`. Unset,
the rung prints `instrument control: NOT RUN` **and still reaches a terminal
PASS** — a clean scan whose scanner was never shown able to fire. A shell
assignment that is not exported does not survive into the harness and produces
exactly that vacuous green. The value needs a local Postgres the caller may
`CREATE DATABASE` on; the control builds and drops its own throwaway fixture and
spends zero guerrilla export.

### (c) `PDS_AMMO_FILE` must be UNSET

```sh
unset PDS_AMMO_FILE
```

`resolve_ammo()` short-circuits on it *before* reaching for the source DB, so any
ambient value silently replaces the live webhook secrets with whatever it names.
A stale or partial real ammo file is the dangerous shape: it passes all three of
rung 4's legs while measuring almost nothing.

### (d) Leave the two demo switches alone

`PDS_STEP5_FAILDEMO` and `PDS_STEP6_GUARD_DEMO` both default to `1`. They are what
make rungs 5 and 6 mutation-proven rather than passively green. A run that
disables either says so in its own PASS line and does not satisfy the criteria.

### (e) Sweep the box before firing — the sampler aims by PID

The RSS sampler selects its target with `pgrep -f beam.smp | head -1`. `-f`
matches the **full command line**, so any process whose arguments merely contain
that string matches, and `head -1` takes the **lowest PID** — which is not the
BEAM whenever a longer-lived matcher exists. The observed failure mode is a
transcript that reports `beam.smp RSS peaked at 1 MB` as the run's own measured
peak, on the single unrepeatable attempt.

This is a harness bug (`pds-bl-harness-pgrep-wrong-process`). Its remedy is
**environmental**, and therefore legal under the freeze: the defect only fires
when a lower-PID matcher exists.

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'echo "head-1: $(pgrep -f beam.smp | head -1)"; echo "pgrep-o: $(pgrep -o beam.smp)"'
```

Fire only when the two are **equal**. Assert the equality immediately *before* and
immediately *after* the attempt and record both readings in the transcript.

Corollaries the operator owns:

- Your own diagnostic shells match too. Use single-shot reads; never leave a
  process alive on the box whose command line contains the literal.
- A matcher belonging to another session is **waited out, not killed**. Attribute
  it in the transcript.
- If equality cannot be established, do not fire. A figure you cannot vouch for
  is worse than no figure.

### (f) Gate (b) is check-and-go, never a pounce

`MemAvailable >= 2200 MB` is precondition (b) of the full export. It clears the
floor roughly 87% of the time on a warm BEAM. **Polling is free**: a closed gate
returns *before* the attempt counter increments, so a refused window costs zero
budget. If it is closed, wait ~10 minutes and run again.

Do **not** wait for or request a deploy. The restart curve is a memory *trough*
first (both t+15 s and t+20 s readings sit far below the floor; sustained
clearance resumes only around t+200 s), a deploy breaks precondition (a) by moving
the served sha out from under the pin taken at rung 0a, and a manufactured restart
costs live content-API downtime and retracts the banner's "nothing is written to
the source" claim.

Read the gate immediately before launching, and record the reading either way.

## 3. The invocation

One `--all`, never split:

```sh
export BARKPARK_HOME=/private/tmp/pds-w7 PDS_SCRATCH_POINTER=/private/tmp/pds-w7.last
export PDS_CONTROL_PG=postgres
unset PDS_AMMO_FILE

./scripts/pds-scratch-target.sh up --verify     # cold: >10 min, two Elixir compiles
./scripts/pds-pull-proof.sh --all
./scripts/pds-scratch-target.sh teardown
```

`--only 3,4` is forbidden and a split climb is worse than a partial one.
Rung 6's guard-off control deliberately **clobbers** the target, and its
terminality is enforced only by `canonical_order()` plus rung 4's
"was a bundle imported *this run*" guard — both of which are per-invocation. Run
the cheap rungs now and 3/4 later against the same target and rung 4 scans
step-6 wreckage and prints CLEAN off contaminated state.

Severability still holds *within* one run: `run_steps` is an unconditional loop
with no short-circuit, so an aborted 3/4 still lets 5/6/7/8 execute.

Do not kill a running export. The attempt counter is written *before* the request
fires, so a killed run burns the attempt anyway and gets nothing for it.

## 4. Reading the output

Two strings must appear literally in a run whose rung 4 means anything:

```
instrument control: PASSED
8 webhook secret(s) pulled read-only from the source DB this run
```

The wording `N value(s) from PDS_AMMO_FILE` anywhere is a failed run — precondition
(c) leaked. `instrument control: NOT RUN` anywhere is a failed run — precondition
(b) leaked.

Quote the harness's RSS line **verbatim** and then annotate its scope. The sampler
measures RSS only, at 1 Hz, so its peak is a **lower bound** whose value depends on
sampling phase: six measurement methods agree to within 0.5% at the same instant,
but the same PID was observed going 1,024,468 kB → 216,852 kB in 55 s while its
`VmSwap` rose 51,624 → 874,760 kB. The stable invariant is `RSS + VmSwap`, not RSS.
Sample `VmSwap` out-of-band alongside and say so. Never extrapolate one leg's
multiplier onto another — a paired measurement of the cheap leg gives a confidence
interval that spans zero.

## 5. Sorting a red — the bucket rule

Every red sorts into exactly one bucket **before** anything is touched:

| Bucket | What it is | What you do |
|---|---|---|
| **HARNESS BUG** | The instrument measured the wrong thing | File it. If a correction is ever authored, the corrected assertion must be *shown still failing* on the pre-fix condition. Under the freeze (§6) it is filed, not fixed. |
| **ENGINE FAIL** | The data plane genuinely misbehaved | File it. Do **not** fix it in this wave. |

A FAIL in the transcript is the *interesting* outcome. It is never downgraded,
never re-run until green, never explained away. The most dangerous act available
to the operator is editing the harness until a red disappears, because that
converts an engine failure into a confident-wrong transcript at exactly the moment
it is most tempting.

## 6. The freeze

From attempt 1 onward, `pds-pull-proof.sh`, `pds-secret-scan.sh` and
`pds-scratch-target.sh` are **frozen**. Prove it at gate time:

```sh
git diff --stat origin/main -- scripts/pds-pull-proof.sh \
  scripts/pds-secret-scan.sh scripts/pds-scratch-target.sh   # MUST be empty
```

Also forbidden: lowering `PDS_FULL_EXPORT_MIN_MEM_MB` (an env var rather than a
harness edit, which makes it the most tempting and most dishonest lever available,
and it endangers the live content API); a manufactured restart; and deleting any
earlier attempt's reds from the append-only transcript.

## 7. The closing rule

The crown-proof task closes **only** if rungs 3 and 4 pass with their controls
FIRING off the one full bundle, and rungs 1/2/5/6 pass against a real booted
target. A severable headroom abort of 3/4 is an honest designed outcome and does
**not** close it. Now that the gate is known to be open most of the time, the
temptation is no longer "lower the floor" — it is "call a lucky partial the crown
proof". Refuse that too.
