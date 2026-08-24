<!-- doc-tier: agent | canonical-for: close-packet-convention | budget: 1100tok -->

# The close packet — where the receipt goes

The [claim-lifecycle contract](task-claim-lifecycle.md) says what the system will
*let* you write. This says what you *should* write.

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

The `--miss` half traps people: after close you cannot even record an **honest failed
attempt**. With no sanctioned post-hoc move, a closer who finds a gap reaches for a
raw `/v1/data/mutate` and pastes one evidence string across every criterion. That
mechanism — not carelessness — produced the misattached-proof population the audit
measured (`task-c285e15a70e5bb59`), where a guard on *duplicate* evidence was
rejected: it would only produce N varied strings, defeating the detector while
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

## Fix it while you still can

**Stamp as you prove, not after.** While the row is `in_progress` and you hold the
claim, a re-stamp **overwrites** that criterion's evidence — measured, 711 bytes
replaced by 28, not appended. So a mis-filed criterion is fixable *there*; after
close it is not.

Criterion **text** is builder-immutable — corrections belong in evidence or an attempt
note, never a reword. People assume the record freezes at close, so they never fix
what they still could.

## What to do with what you could not prove

Leave it `met:false` and say why. `--set criteria_override="<why it is done anyway>"`
lands **on the record** as `close_override.criteria` (actor, unmet rows, reason) and
the unmet criteria **stay `met:false`** — an override never flips them. That is the
whole point: the row keeps saying what was not proven, next to a signed reason.

> **A convention you keep, not a gate that keeps it for you.** A `done` close over an
> unmet criterion is not always refused — one landed emitting `4/5 met — closed done
> with unmet criteria (advisory, no gate)`. So a row can sit `done`, unmet, with
> `close_override: null`: no actor, no reason. Un-setting a criterion in the close
> write is one route there (`task-c652c3ba8129c607`). Pass the override even when
> nothing stops you — a reader cannot tell an honest gap from a silent one.

It is one of **three** honesty gates on a `done` close, each with its own override,
and **none of them discharges another**:

| Gate | Refusal | Override |
|---|---|---|
| unmet acceptance criteria | `409 criteria_unmet` | `criteria_override` |
| closing someone else's claim | `409 not_holder` | `holder_override` |
| a `gh-<num>` row whose reporter has heard nothing | `409 acknowledgement_unposted` | `ack_override` |

A blank reason is not an override for any of them. `cancelled` and `blocked` closes
are exempt from the criteria gate — abandoning acceptance criteria is what cancelling
means.

## The rule behind the rule

Per-criterion `evidence` answers *"what proves THIS criterion?"*; a row-level receipt
answers *"what happened to this task?"* Copying the second into the first makes every
criterion look proven by one artifact — indistinguishable from proof nobody checked,
and, unlike an override, leaving no signature saying so.
