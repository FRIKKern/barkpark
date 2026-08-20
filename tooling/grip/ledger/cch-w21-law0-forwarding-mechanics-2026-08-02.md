# CCH wave 21 — Law 0 forwarding mechanics + partition reconciliation

Companion to `cch-w21-law0-residue-partition-2026-08-02.md` (written by a sibling
verifier at read `2026-08-01T23:46:21.344Z`). This file carries the four things that
file does not, each re-derivable by the command beside it. Independent read at
**2026-08-02T00:29:43.480Z**.

## 1. The denominator moved between two reads 43 minutes apart

```sh
BP_TOKEN=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])") \
  node cloud/priv/static/__preview__/seal-predicate.mjs \
  --epic cloud-console-hardening-epic --successor cch-instruments-epic 2>&1 | head -8
```

| read | roster | residue |
|---|---|---|
| 2026-08-01T23:46:21.344Z | 258 children `{in_progress:1, open:91, done:139, cancelled:26, considering:1}` | 93 |
| 2026-08-02T00:29:43.480Z | 258 children `{open:92, done:139, cancelled:26, considering:1}` | 93 |

Residue is stable at **93**; the `in_progress` row returned to `open` (a claim lapsed).
Law 0's cap for this wave is therefore **93**, and it is robust to the read instant.

`VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=FAIL c=PASS orphans=90 considering=1`
— note **b=FAIL**, not the `b=PASS` D134 recorded: `CCH-D5-rate-limiter-sees-every-user-as-one`
now reads rung 3 ("no test anywhere asserts that two clients behind the front door get
SEPARATE rate buckets"). Any wave-21 prose quoting `b=PASS` is quoting a stale run.

## 2. `forwarded under successor` can NEVER be non-zero — schema, not backlog

`seal-predicate.mjs:366-371` places a residue row in `fwd` only when it is in
`fetchRoster(EPIC)` **and** in `fetchRoster(SUCCESSOR)` (`:344`, `:351`). Both are
`filter[parent_id]` reads (`:231`) and a task carries ONE `parent_id`. Measured:

```
parent 258   succ 89   INTERSECTION 0
```

So a re-parent clears clause (a) by leaving `residue`, never by being credited as
`forwarded`. The line `forwarded under successor : 0` is a **structural constant**, not
a progress reading. A wave waiting for it to move is waiting for something the data
model cannot emit.

## 3. Law 0's filing half vs D83 — disjoint domains, identical end state

- **Law 0** (charter `:26-35`) governs rows that **do not exist yet**: create with
  `parent_id: cch-instruments-epic` AT CREATE TIME — "it is a create, never a re-parent".
- **D83** (`:250`) governs rows that **already exist under the parent**: forwarding is
  MEMBERSHIP IN THE SUCCESSOR'S ROSTER, so an existing row acquires a forwarding
  address only by RE-PARENTING.

Both demand `parent_id == cch-instruments-epic`. There is no tension: the only way to
manufacture one is to file an instrument row under the parent and then cite Law 0's
"never a re-parent" as licence to leave it there. That clause is scoped to create time
and licenses nothing after it.

## 4. The leak is 44, not D172's 14 — and the cheap forward is still blocked

My independent classification of the 90 orphans by body/surface reads
**44 instrument-class / 35 person-facing / 11 neither**. The sibling file reads
**43 / 34 / 13**. The whole delta is the operator rows: I count
`cloud-console-operator-audit-log` and `gr-backlog-operator-digest-send` as
person-facing console surface (both are `/operator` screens), the sibling counts them
as backend. **Either way the instrument-class bucket is 43-44 against D172's ruled
14** — the split has leaked for eight waves, not stalled.

The cheap 43-44-row forward is nevertheless UNAVAILABLE this wave:

```sh
git cat-file -e origin/main:.claude/workflows/bp-cloud-console-instruments-charter.md
# fatal: path ... does not exist in 'origin/main'   (rc 128)
```

D172 conditioned the re-parents on that charter reaching main; it has not, and #8500 is
refused by this wave's own charter. So the four-slice floor must be paid out of
**closes and cancels**, of which at least 17 exist with no engineering:
8 merged-but-open (`cch-w20-s3/-s6/-s7/-s8/-s9`, `cch-w19-s1/-s2/-s4`), 4 unclaimed
refiled twins (`cch-w19-s3/-s6/-s7/-s8`), and ≥5 older duplicate-family members
(`cch-w17-bl-band-a-shell-fold-cliff`, `task-9fcf92e7a02fa5b8`,
`cch-w14-bl-billing-chip-truncated-above-768`,
`cch-w18-bl-instance-card-url-ellipsised-on-phone`, `task-802585b77fc136b1`).

## 5. The ratchet, measured against a charter-recorded prior

Charter **D225** (wave 19 first claim): `231 children = 84 open · 1 considering · 128
done · 18 cancelled` → residue **85**. Today: 258 children, residue **93**.
**+8 residue and +27 children across two waves**, ~+4 residue per wave.

```sh
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -c 'D225'
```
