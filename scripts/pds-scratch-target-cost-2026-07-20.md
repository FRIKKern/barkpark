<!-- doc-tier: human | canonical-for: pds-scratch-target-cost-and-repull-diagnosis | budget: 8000tok -->

# The scratch target really costs 20 seconds, and the re-pull 500 is not what we said it was

**Measured 2026-07-20, wave 10 (PDS epic).** Three documented facts about
`scripts/pds-scratch-target.sh` and the re-pull blocker were wrong. All three were wrong in the
same direction: they made re-arming a target look expensive and made the failure look mis-diagnosed.
This is the correction, with the evidence, and with the one recipe that makes the corrections
*useful* rather than pedantic — how to hold a pre-booted spare.

> **Provenance, stated plainly.** The timings and the pull-then-pull experiment below were measured
> on a real host during the wave-10 instrumented climb; this record transcribes them and adds the
> source-level citations. It does not re-run them. Anyone re-measuring should re-state the
> `api/_build` state they measured under (see §1) — a figure without that label is not a figure.

---

## 1. The cost — two regimes, one switch

Old text, at `scripts/pds-scratch-target.sh:32` and again in the runtime warning at `:255`:

> `>10 min cold, ~90s warm` / `Warm runs take ~90s.`

The warm number was wrong by roughly 4.5x. Measured warm:

| operation | measured | `api/_build` state |
|---|---|---|
| first `up` of a session | **32.742s** | populated (290 MB, 71 deps) |
| later `up` in the same session | **9.830s** | populated, deps already resolved |
| `teardown` | **8.068s** | populated |
| `teardown` + `up` (one full cycle) | **20.240s** | populated |

**Every row above is WARM-PATH.** They were produced with `api/_build` populated at 290 MB across
71 deps. Do not quote any of them for a fresh worktree.

The ~20s gap between the session's first `up` (32.7s) and every later one (9.8s) is **`mix deps.get`
doing full resolution, not compilation** — the script fetches deps itself before booting (TRAP 1,
`pds-scratch-target.sh`), and on the first invocation of a session that resolution is a real cost.
It is paid once per session, not once per boot.

**What makes the cold path cold is exactly one thing: an empty `api/_build`.** `_build` is
per-checkout and is never shared between checkouts, so a fresh worktree is *always* cold, and a cold
tree pays two full compiles (`ensure_secrets` runs `MIX_ENV=dev`, the server boots `MIX_ENV=prod`).
`>10 minutes` is honest there. Tell the regimes apart before budgeting anything:

```bash
[ -n "$(ls -A api/_build 2>/dev/null)" ] && echo warm || echo COLD
```

Both `:32` and the `:255` warning now carry the measured figures and name the trigger, so a reader
can place themselves in a regime instead of guessing.

### Why this matters

At `~90s` a scratch target is a thing you boot deliberately and hoard. At **20.24s a full
teardown-and-respawn cycle**, re-arming is cheap enough to do casually between attempts — which is
the whole operating posture of the crown climb. The wrong number was arguing against re-arming.

---

## 2. The re-pull 500 — it does NOT fire on a plain second `--merge` pull

The blocker `pds-bl-repull-into-populated-target-500` has been widely restated as *"a second
`--merge` pull into a populated target 500s."*

It does not. The clean experiment that the blocker task itself names as never-run — **fresh target,
pull, pull, with no rung 6 in between** — was run this wave, and **both pulls PASSED**:

- second import: **exit 0, ~13s, 13323 rows**
- PDS-D9 adoption correctly did **not** re-fire on the second pass

The `25P02 in_failed_sql_transaction` at `api/lib/barkpark/tenancy/workspace_bundle.ex:233`
reproduces **deterministically only behind rung 6's clobbered state** (`--only 1,6` twice — first
try). So the narrowed diagnosis is:

> **The trigger is rung 6's clobbered state, not plain re-import into a populated target.**

That answers the open question the blocker task poses about itself. `pds-bl-repull-into-populated-target-500`
has been updated with this narrowing and the evidence above.

### Why `:233` is the frame you see, and why it hides the real error

`workspace_bundle.ex:233` is `set_replication_role!("DEFAULT")` sitting inside an **`after` block**.
By the time it runs, the surrounding transaction has already failed; the cleanup statement then
raises `25P02 in_failed_sql_transaction` and *that* is what surfaces. The frame is a **mask, not a
cause** — and because the `after` block is on the shared `import_bundle/2` path, it is reachable
from both modes. Any future fix should surface the original error rather than the cleanup's.

---

## 3. The mode contradiction — recorded, not resolved

Two places in the record pin the 500 to `mode=clean`. The reproduced trace names the **merge** path.
Both citations, verbatim in substance:

**Citation A — charter `PDS-D73`** (`.claude/workflows/bp-pds-charter.md`):

> `clean` is the DEFAULT mode and is ungated, and a clean import into a populated target answers an
> opaque 500 whose true cause is a `25P02 in_failed_sql_transaction` at `workspace_bundle.ex:233`.

**Citation B — inline comment at `scripts/pds-pull-proof.sh:919-921`:**

> `Without --merge the CLI sends mode=clean, and clean against a POPULATED target answers an opaque`
> `HTTP 500 whose real cause is 25P02 in_failed_sql_transaction at workspace_bundle.ex:233.`

**Against them:** the reproduced trace names `merge_import/2` —
`api/lib/barkpark_web/controllers/workspace_controller.ex:308` (`defp merge_import(conn, bundle)`),
reached from `:267`, which is *inside* the `:allow_bundle_import` opt-in gate. That is the
`--merge` branch. It cannot be `mode=clean`.

The structural reading that makes both observations survivable: `:233` is in the shared
`import_bundle/2` `after` cleanup (§2), reachable from **either** branch — `clean_import/2` and
`merge_import/2` both funnel through it. So "the 500 is a clean-mode failure" is very likely an
over-narrowing of a mode-agnostic cleanup fault, and the merge-mode trace is the counterexample.

**This is recorded as a contradiction, not resolved.** Resolving it means editing
`scripts/pds-pull-proof.sh` and amending `PDS-D73`, and `pds-pull-proof.sh` is **FROZEN**
(PDS-D100 / PDS-D154, blob `e219e97ccf7f33797c86a2b84d998d599b6bda31`). A comment fix is still an
edit, and the freeze does not carve out comments. The file was **not** touched by this work:

```
$ git diff --stat origin/main -- scripts/pds-pull-proof.sh
(empty)
```

---

## 4. The spare-target recipe — hold one pre-booted, pay ~0

Two scratch targets coexist cleanly. Proven live on 2026-07-20:

- disjoint HTTP ports **:22940** and **:30540**
- disjoint Postgres ports **:41596** and **:20104**
- the host dev server on **:4000 untouched across both teardowns**

That works because `free_port()` (`pds-scratch-target.sh`, TRAP 7) probes each candidate with `lsof`
before binding and explicitly refuses `4000`, `5432`, and `5433`. Isolation is per-instance by
construction: `$BARKPARK_HOME`, `$BARKPARK_PG_PORT`, `$PORT`, `$BARKPARK_MEDIA_DIR`.

**The one requirement: pin BOTH `BARKPARK_HOME` and `PDS_SCRATCH_POINTER`.**

```bash
# the spare, kept warm alongside the live target
PDS_SCRATCH_POINTER=/tmp/pds-scratch-spare.last \
BARKPARK_HOME=/tmp/pds-spare \
  scripts/pds-scratch-target.sh up

# ...and every later verb for the spare must carry the SAME pointer
PDS_SCRATCH_POINTER=/tmp/pds-scratch-spare.last scripts/pds-scratch-target.sh env
PDS_SCRATCH_POINTER=/tmp/pds-scratch-spare.last scripts/pds-scratch-target.sh teardown
```

Pinning only one is the trap. `up` writes the pointer file **unconditionally**
(`printf '%s\n' "$home" >"$POINTER_FILE"`, `pds-scratch-target.sh:335` — it was `:307`/`:304`
before this record's header edits shifted it; grep the string, not the number) and the pointer is **one
global path** (`/tmp/pds-scratch-target.last` by default). So booting a second target on the default
pointer silently repoints `verify` / `env` / `teardown` at the new root and **strands the first
target's Postgres** — the leak the teardown assertions exist to catch, arriving through the front
door.

**The payoff.** With a spare already booted, a failed attempt does not cost a 20.24s cycle — it
costs a pointer swap. The miss cost goes from 20s to ~0, and the 20s teardown-and-respawn happens
off the critical path while the next attempt is already running.

---

## What this record does and does not claim

- It **does** claim the four warm timings, each labelled with the `api/_build` state that produced
  them, and it names the empty-`_build` trigger for the cold regime.
- It **does** claim the fresh-target pull-then-pull passed twice (exit 0, 13s, 13323 rows) and that
  the 25P02 reproduces behind rung 6's state.
- It **does not** claim the mode contradiction is resolved. It is recorded with both citations and a
  structural hypothesis (`:233` is a mode-agnostic `after`-block mask). Resolving it needs a thaw.
- It **does not** claim a cold-path measurement. `>10 minutes` is inherited, not re-measured.
