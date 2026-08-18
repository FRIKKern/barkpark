# wild-bulk-quality-sweep — ledger write-path contract (re-derivation)

doc-tier: grip-ledger | topic: wbqs-reconcile-write-path | derived: 2026-08-18

## What Decide/Lead will execute, and the exact verb contract

All 3 open survivors are `claim:None` (no epoch). Contract facts, each with its rerun:

1. **CLOSE requires an epoch — unclaimed rows cannot be closed directly.**
   `task close` positional args = `[doc_id, worker_id, observed_epoch(int, REQUIRED)]` plus
   optional `lifecycle_status` + `reason`. A `claim:None` row has no epoch to CAS, so the
   lead MUST mint one first: `bp task claim <id> <worker>` (or `task next`), read the
   returned epoch, then `bp task close <id> <worker> <epoch>`.
   - rerun: `bp capabilities -o json | python3 -c "import json,sys;d=json.load(sys.stdin);[print(c[1],c[5]) for c in d['commands'] if isinstance(c,list) and c[0]=='task' and c[1]=='close']"`

2. **CANCEL is a close variant, not a separate verb.** `close` carries optional
   `lifecycle_status` — pass `--lifecycle-status cancelled --reason "..."` to kill a row
   (→ cancelled); omit it for a normal done-close. Still epoch-fenced (claim first).
   - rerun: same as (1) — the `lifecycle_status` + `reason` optional args are in the close signature.

3. **PARK needs NO claim and NO epoch.** `task stage <doc_id> <state>` is the lifecycle
   verb; flags include `--disposition parked --note "..." --reopen-trigger "..."`.
   `--disposition parked` with no reopen-trigger (on the stage AND the row) is REFUSED
   before any write. NO `observed_epoch` in the signature — "thought is not contended work".
   Target state for a park can be the row's OWN current state (same→same adjudication edge),
   so a still-open row parks in place: `bp task stage <id> open --disposition parked --note "superseded by X" --reopen-trigger "..."`.
   - rerun: `bp capabilities -o json | python3 -c "import json,sys;d=json.load(sys.stdin);[print(c[1],c[5],c[6]) for c in d['commands'] if isinstance(c,list) and c[0]=='task' and c[1]=='stage']"`

4. **RE-PARENT: `task move <doc_id> [new_parent_id]` — zero flags, NO epoch fence.**
   Omitting new_parent_id moves to root. Emits task.reparented. Verify by re-reading parent_id.
   - rerun: `bp capabilities -o json | python3 -c "import json,sys;d=json.load(sys.stdin);[print(c[1],c[5],c[6]) for c in d['commands'] if isinstance(c,list) and c[0]=='task' and c[1]=='move']"`

5. **STAMP epoch index is 0-BASED** and `--met` also requires `--criterion-text "<exact wording>"`
   (409 criterion_text_required / criteria_mismatch otherwise). Holder-only, same epoch fence
   as close — so stamping the 5 epic cycle-criteria needs the epic row CLAIMED first.

## Charter path — outside both fences

- Convention confirmed: all ~60 charters are `.claude/workflows/bp-<epic>-charter.md` (bp- prefix).
  Target `bp-wild-bulk-quality-sweep-charter.md` does NOT yet exist (fresh write, no clobber).
  - rerun: `ls .claude/workflows/ | grep -iE 'charter' | head` ; `ls .claude/workflows/*wild-bulk-quality* 2>&1` (→ "no matches")
- `.claude/workflows/` matches neither the truth-grip-w14 fence (`tooling/grip/` + `api/`)
  nor the cloud-build fence (`cloud/`). Charter write is fence-clean.
- This ledger row itself lives under `tooling/grip/ledger/` — the verifier carve-out inside
  the truth-grip surface; a new file, never opening an existing one.
