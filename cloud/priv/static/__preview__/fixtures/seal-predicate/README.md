# seal-predicate fixtures

Committed ledger fixtures for `../../seal-predicate.mjs`, driven by
`../../seal-predicate.test.mjs`. Each one pins ONE measured behaviour of the
predicate so it is a test, not a manual run.

| fixture | pins |
|---|---|
| `sealable.json` | the happy path: a resolvable successor, zero live rows, all gates resolved — the only fixture that may exit 0 |
| `zero-live-null-successor.json` | `successor: null` with ZERO live rows — the shape that used to exit 0 while printing "to null" |
| `no-successor-key.json` | the `successor` key absent entirely — the shape that used to print "to undefined" |
| `orphan-residue.json` | a resolvable successor AND one unforwarded live row — proves the refusals did not replace clause (a) |

Fixture keys the predicate reads: `children`, `successor`, `tasks` (id → task
document, for successor resolution), `forwarded`, `gates`, `landed`,
`defectCommits`. A fixture run asserts nothing about the live ledger — it is a
mutation control, and the predicate labels it `LEDGER FIXTURE — not live`.
