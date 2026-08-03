# CCH wave 27 — the seal predicate FAILS OPEN on an empty roster (re-derivation recipe)

Measured 2026-08-02T19:19–19:22Z. Tree: git worktree detached at `origin/main`
`c2affd4458f491694f38773843df43b4f66507e0`. Resolved repo root passed explicitly with `--repo`.

## The finding

`clause (a)` has NO roster cardinality floor. `orphans = 0` is emitted for a roster of ZERO
children exactly as it would be for a genuinely-drained epic, and nothing downstream
distinguishes them: exit 0, `VERDICT: SEAL`, `mode=live`, `stubbed=0 waived=0`.
Clause (c) does NOT stop it — the gates are fetched by hardcoded `_id` independently of the
epic, so they resolve even when the roster is empty (the run even PRINTS
`parent=cloud-console-hardening-epic in-epic-roster=false` and acts on none of it).

The asymmetry is the tell: `seal-predicate.mjs:790` REFUSES an empty `KNOWN_DEFECTS`
register (`EMPTY-DEFECT-REGISTER` — "an unrun clause is not a passed clause"). The identical
vacuity guard for clause (a)'s population was never written.

## Reachability — a ONE-CHARACTER typo, live server, no stub

```
W=<worktree at origin/main>
node $W/cloud/priv/static/__preview__/seal-predicate.mjs \
  --epic cloud-console-hardening-epicc --successor cch-instruments-epic --repo $W
# rc=0
# roster: 0 children  {}
# VERDICT: SEAL
#   Sealed 0 children of cloud-console-hardening-epicc: 0 evidence-closed, 0 forwarded by name
# VERDICT-TOKEN: SEAL-PREDICATE SEAL a=PASS b=PASS c=PASS orphans=0 considering=0 \
#   successor=cch-instruments-epic epic=cloud-console-hardening-epicc mode=live stubbed=0 waived=0
```

Control, same tree, same server, 19 s later:

```
node $W/cloud/priv/static/__preview__/seal-predicate.mjs --successor cch-instruments-epic --repo $W
# rc=1
# roster: 343 children  {"done":189,"open":119,"cancelled":34,"considering":1}
# VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=PASS c=PASS orphans=117 ... mode=live
```

## Server-shaped variant (same hole, no typo)

Stub that RESOLVES `filter[_id]` lookups as live published tasks and returns `[]` for
`filter[parent_id]` — i.e. a server-side roster-filter regression, HTTP 200 throughout:

```
node scratch/stub4802.mjs &   # see the wave-27 verifier transcript for the 18-line stub
BP_SERVER=http://127.0.0.1:4802 BP_TOKEN=x node $W/cloud/priv/static/__preview__/seal-predicate.mjs \
  --successor cch-instruments-epic --repo $W
# rc=0 · roster: 0 children · VERDICT: SEAL · a=PASS b=PASS c=PASS orphans=0 mode=live
```

Related unarmed neighbour (same family, not yet reachable): `fetchRoster` hardcodes
`limit=500` against a roster of 343 — truncation would UNDER-count orphans silently.

## What does NOT fail open (measured, same session)

| Leg | rc | Token |
|---|---|---|
| Uniformly empty stub (`documents: []` for everything) | 1 | `REFUSED reason=UNRESOLVABLE-SUCCESSOR a=UNEVALUATED` |
| `BP_SERVER=https://example.invalid` | 2 | `INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN` (correct) |
| `env -u BP_TOKEN` | 1 | `NO-SEAL a=FAIL b=FAIL c=PASS orphans=117 mode=live` — the API serves this roster ANONYMOUSLY; an absent token is not an empty read |

So the assignment's three named legs are all fail-CLOSED. The hole is one hop over: the
roster read returning HTTP 200 with a short or empty array, from a typo or a server change.

## Remedy shape

A refusal, evaluated after the roster read and before any verdict, with its own code
(e.g. `EMPTY-ROSTER` / `ROSTER-FLOOR`): a live run whose epic roster is empty has not
measured the epic — it has measured a wrong address. TERMINAL already has the correct
precedent (`TERMINAL-CLAIM-REFUTED`, a post-condition read at `:860`), and clause (b)'s
`EMPTY-DEFECT-REGISTER` at `:790` is the same guard one clause over.
