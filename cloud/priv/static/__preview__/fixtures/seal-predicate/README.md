# seal-predicate fixtures

Committed ledger fixtures for `../../seal-predicate.mjs`, driven by
`../../seal-predicate.test.mjs`. Each one pins ONE measured behaviour of the
predicate so it is a test, not a manual run.

| fixture | pins |
|---|---|
| `sealable.json` | the happy path: a resolvable successor, zero residue, all three gates resolved — the only non-terminal fixture that may exit 0 |
| `zero-live-null-successor.json` | `successor: null` with ZERO live rows — the shape that used to exit 0 while printing "to null" |
| `no-successor-key.json` | the `successor` key absent entirely — the shape that used to print "to undefined" |
| `orphan-residue.json` | a resolvable successor AND one unforwarded live row — proves the refusals did not replace clause (a) |
| `self-successor.json` | R4: the successor IS the epic, with every live row in `forwarded` — the shape that measured `a=PASS` over 83 live rows before R4 existed |
| `terminal-clean.json` | TERMINAL accepted: live==0 AND considering==0, read from the roster |
| `terminal-empty-roster.json` | `terminal-clean.json` with `children` EMPTIED: the live-only empty-roster floor does not apply to a fixture, so this is the hermetic, history-free way to pin the `Sealed 0 children of …` fabrication the floor exists to prevent |
| `terminal-one-live-row.json` | TERMINAL refuted by one open row — the token is not the claim |
| `terminal-one-considering-row.json` | TERMINAL refuted by one `considering` row |
| `considering-residue.json` | a `considering` row is residue: counted into clause (a) and named, never silently exempt |
| `considering-forwarded.json` | the same `considering` row WITH a forwarding address — clause (a) passes and the row is still printed by name, so the wave-28 bucket split reads as a re-labelling of UNNAMED residue and not as a new red |
| `ladder-no-waiver.json` | the three-rung ladder unwaived — 2 measured HERE, 3 MEASURED-ELSEWHERE, 1 measured by nothing, which fails clause (b) by name |
| `diff-is-only-the-subject.json` | a commit whose patch is only its own subject line fails clause (b) — commits are verified by DIFF, never by `%s` |

Fixture keys the predicate reads: `children`, `successor` (an id, `null`, or the
literal `TERMINAL`), `tasks` (id → task document, for successor resolution),
`forwarded`, `gates`, `landed`, `defectCommits`, `diffs` (sha → `{paths, body}`,
standing in for `git show --format=`), and `unmeasuredWaivers` (rung-3 register
entries a fixture may waive, named one by one and printed in the verdict).

A waiver is FIXTURE-ONLY by construction — it can arrive only through `--ledger`,
so no live run can carry one — and any fixture green says so on its own line
(`FIXTURE-ONLY GREEN: n guard(s) STUBBED … n WAIVED`) and in the machine-readable
token (`mode=fixture stubbed=n waived=n`). A fixture run asserts nothing about the
live ledger: it is a mutation control, and the predicate labels it
`LEDGER FIXTURE — not live`.
