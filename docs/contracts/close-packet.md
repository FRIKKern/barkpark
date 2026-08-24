<!-- doc-tier: agent | canonical-for: close-packet-convention | budget: 1100tok -->

# The close packet — where the receipt goes

The [claim-lifecycle contract](task-claim-lifecycle.md) says what the system will
*let* you write. This says what you *should* write, and it exists because the
mechanism has a seal most closers meet for the first time at the worst moment.

## The convention

**Write the receipt ONCE at row level** — the close `reason`, or
`disposition_reason` via the done→done stage edge — **never copied into
per-criterion `evidence`. Leave what you cannot prove `met:false` under
`criteria_override`: a visible override beats an invisible false-done.**

## Why — stamping is sealed at close

`bp task stamp` is **`in_progress` only**. On a closed row *both* halves refuse:

```
bp task stamp <id> <worker> <epoch> --criterion 0 --met  --evidence "…"  -> bp: not_in_progress:done
bp task stamp <id> <worker> <epoch> --criterion 0 --miss --note     "…"  -> bp: not_in_progress:done
```

The `--miss` half is the one that traps people: after close you cannot even record
an **honest failed attempt**. There is no sanctioned post-hoc move at all, so a
closer who discovers a gap reaches for a raw `/v1/data/mutate` and pastes one
evidence string across every criterion. That mechanism — not carelessness — is
what produced the misattached-proof population the close-packet audit measured
(`task-c285e15a70e5bb59`).

A guard that rejected *duplicate* evidence strings was considered and **rejected
there**: it would only produce N varied strings, defeating the detector while
leaving the criteria just as unproven.

## Where a row-level receipt can go

| When | Field | How |
|---|---|---|
| at close | `content.close_reason` | the `reason` positional on `bp task close` |
| after close | `content.disposition_reason` | `bp task stage <id> done --note "…"` |

The done→done stage is the **same-state adjudication edge**: it records a reason on
a finished row *in place*. Verified — `lifecycle_status` stays `done` and the close
attribution (`claim.closed_by`, `claim.closed_at`) is untouched. It does not
resurrect the row into `bp task ready`, which reopening to `open` would.

## What to do with what you could not prove

Leave it `met:false` and say why. `--set criteria_override="<why it is done anyway>"`
lands **on the record** as `close_override.criteria` (actor, unmet rows, reason) and
the unmet criteria **stay `met:false`** — an override never flips them. That is the
whole point: the row keeps saying what was not proven, next to a signed reason.

It is one of **three** honesty gates on a `done` close, each with its own override,
and **none of them discharges another**:

| Gate | Refusal | Override |
|---|---|---|
| unmet acceptance criteria | `409 criteria_unmet` | `criteria_override` |
| closing someone else's claim | `409 not_holder` | `holder_override` |
| a `gh-<num>` row whose reporter has heard nothing | `409 acknowledgement_unposted` | `ack_override` |

A blank reason is not an override for any of them. `cancelled` and `blocked` closes
are exempt from the criteria gate by name — abandoning acceptance criteria is what
cancelling means.

## The rule behind the rule

Per-criterion `evidence` answers *"what proves THIS criterion?"* A row-level receipt
answers *"what happened to this task?"* Copying the second into the first makes every
criterion look proven by the same artifact, which is indistinguishable from proof
nobody checked — and, unlike an override, it leaves no signature saying so.
