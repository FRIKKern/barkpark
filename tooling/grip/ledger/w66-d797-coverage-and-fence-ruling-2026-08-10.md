# w66 verify — D797 coverage + fence ruling (re-derivation recipe)

STATUS OF THIS ROW: the assigned MUST-RUN could **not** be executed. `Bash` on this host is dead —
every invocation, including `true`, dies before the command runs with
`ENOSPC: no space left on device, open '/private/tmp/claude-501/-Volumes-SATECHI-github-barkpark/d10b01bb-c28b-4379-914a-ad1ad6677209/tasks/<rand>.output'`.
No `git`, no `grep`, no `bp`. Everything below was derived with `Read` only, against the
**working-tree** charter (L3), which is itself provably stale.

## The one fact that invalidates half the assignment

The primary checkout's charter ceiling is **D682**, newest roadmap section **Wave 57**
(`.claude/workflows/bp-cloud-console-hardening-charter.md:1017` = D681, `:1018` = D682,
`:1022` = "### Wave 57 … (build in flight)"; wave sections descend from there — `:1120`ish wave 56,
`:1138` wave 55). Surveyors read **D797 / wave 65** on `origin/main`.
**D772, D780, D781, D789, D791, D797 DO NOT EXIST in the only copy readable on this host.**
This is D682's own trap firing again, verbatim: *"The checkout's copy of THIS CHARTER is 566 lines
behind origin/main (local ceiling D602 vs D663), so authoring into it would have silently DELETED
D603-D663 in a docs-only PR."*

## Re-derivation recipe (run on a host with a working shell)

```bash
mkdir -p /tmp/w66
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md > /tmp/w66/charter.md
grep -n '^| D797\|^| D789\|^| D791\|^| D780\|^| D781\|^| D772\|^| D679\|^| D70 \|^| D191' /tmp/w66/charter.md
grep -n 'api/lib/barkpark/tasks' /tmp/w66/charter.md      # expect 4 hits, ALL exclusions
sed -n '120,270p' /tmp/w66/charter.md                     # the Surface fence block
grep -c '^| D[0-9]' /tmp/w66/charter.md                   # row count
grep -n '^| D[0-9]*' /tmp/w66/charter.md | tail -3        # the REAL D ceiling → ADD = ceiling+1
```

## What IS derivable from the stale copy (these four rows are line-stable vs the surveyor's origin/main read)

| line | text | force |
|---|---|---|
| `:125` | `**In fence:** `cloud/`, `api/lib/barkpark_web/live/`.` | `api/lib/barkpark/tasks/` is not in the bare fence |
| `:129` | wave-1 dispensation: "`api/lib/barkpark/tasks/` never calls `apply_mutations`" | exclusion, and the REASON the grant is safe |
| `:151` | wave-28 widening: "It does NOT touch `api/lib/barkpark/tasks/`" | exclusion |
| `:385` D70 | "that path is `barkpark` CORE, out of this epic's fence (`cloud/` + `web/live/`) and inside felix-pristine's active surface; do not touch it this wave" | exclusion + names the second epic |
| `:1015` D679 | "NOT cut as a slice this wave: it is out of fence in `api/lib/barkpark/tasks/**` and `internal/cli/**`, **needs a fresh ADD**" | exclusion + the epic's own instruction for how to get in |

D70 and D679 landing at exactly `:385` and `:1015` in the stale copy — the same line numbers the
origin/main surveyor reported — is the corroboration that this region of the charter has not moved
in eight waves.

## The doctrine that decides the ruling without needing D797 at all

A fence grant lives in the **Surface fence** block as a numbered ADD with a one-sentence subject and
an "and nothing else" clause. A Decisions-table row is not a grant. The charter says so itself:

- `:190` (D377): *"The Wave-2 dispensation is TWO FILES BY NAME for 'the gate ledger's own honesty' —
  a rationale for those two documents, not a topical licence over the gate layer."*
- `:188` (D377): the bare filename *"appears only in D-row prose at D89/D99/D100/D108/D110/D116/D119/D369"* —
  and D377 still had to mint a fresh ADD. **D-row prose is explicitly not a grant.**
- `:163-164` (D346): citing a wave-scoped/subject-scoped grant out of its scope *"would be a phantom
  wearing a number, the exact class wave 30 is named for."*
- `:196` (D377): *"An unnoticed omission is not a dispensation."*

## Code facts (working tree, api/ shows clean in `git status`)

- `api/lib/barkpark/tasks/close.ex:688` — `autostamp_merge_gate/6`, guard clause is
  `when is_map(landed) and map_size(landed) > 0 and is_list(criteria)`. No lead check. No PR check.
- `close.ex:664-666` — the comment states the authority model out loud: *"a non-empty `landed` digest
  rides the close (the LEAD merge close carries one; a builder pre-merge close does not …)"*.
  That is a CONVENTION used as an authority proxy.
- `close.ex:26-31` — *"NONE OF THIS IS AUTHORIZATION. `worker_id` arrives as a client-supplied body
  param … a caller who wants to close someone else's task can simply claim to be them."*
- `close.ex:741-748` — `compose_merge_gate_evidence/4` builds
  `"auto: lead-closed on merge by <worker> (epoch …) — landed <summary> at <ts>"` **entirely from
  caller-supplied bytes**. Nothing contacts GitHub. The ledger asserts a merge it never observed.
- `close.ex:455-468` — `unmet_after_autostamp/2` REJECTS every autostamped index from the unmet set,
  so the close returns `{:ok, nil}` and **mints no `close_override` record**. Silent by construction.
- `internal/apiclient/client_close_payload_test.go:96-131` — the whitelist pin is real
  (`assertExactKeys` on TaskCloseN / TaskCloseRevN). EXTEND with a third key-set, never loosen.
- **Bonus phantom, in-frame:** that same pin file cites `api/lib/barkpark/tasks/close.ex:344-370`
  at `:15` and again at `:91`. `autostamp_merge_gate/6` is at `:688`. A guard whose own citation is
  ~340 lines stale, inside the epic about citations that do not hold.
