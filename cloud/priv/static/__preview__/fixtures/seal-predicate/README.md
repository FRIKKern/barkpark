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
| `filing-act-reparent.json` | wave 26: 69 OPEN rows reparented under an already-`done` sibling. Nothing is finished and the epic's DIRECT roster is one done row, so the one-level reader printed `VERDICT: SEAL a=PASS orphans=0` — a gauge emptied by a filing act |
| `forward-to-grandchild.json` | wave 26, the same blindness the other way: a row correctly forwarded to a GRANDCHILD of the successor read as an orphan — a false FAIL beside the false PASS |
| `census-departure.json` | wave 26: a `priorCensus` row that LEFT the counted population and still resolves to `open` — a FILING EVENT, named and blocking |
| `census-departure-transitioned.json` | the same departure with ONE field changed (`done`): a row that left by being finished is not a filing event. The pair is the anti-filing arm's mutation proof |
| `reparent-to-successor.json` | wave 36: a census row RE-PARENTED out of the epic and onto the successor's wave — legally placed, so it is under the successor and NOWHERE in `children`. The pre-fix file could never count it (`forwarded` is the successor's subtree, the classify loop walked the epic's, and R4/R6 keep those disjoint), so it printed `forwarded under successor : 0` and charged a correct forwarding as a filing event. This is the arm that reds if the forwarded bucket is unreachable |
| `paced-forwarding.json` | wave 36: THREE departures — two re-homed onto the successor's wave, one simply gone. Pre-fix all three read as `FILING EVENT(S) : 3`, so charter D93's paced forwarding was indistinguishable from a swept population. The committed file prints the two under `RE-HOMED UNDER` with `→` and the one under `FILING EVENT(S)` with `✗` |

Fixture keys the predicate reads: `children`, `successor` (an id, `null`, or the
literal `TERMINAL`), `tasks` (id → task document, for successor resolution),
`forwarded`, `gates`, `landed`, `defectCommits`, `diffs` (sha → `{paths, body}`,
standing in for `git show --format=`), and `unmeasuredWaivers` (rung-3 register
entries a fixture may waive, named one by one and printed in the verdict).

`reparent-to-successor.json` and `paced-forwarding.json` differ from
`forward-to-grandchild.json` in a way that matters: that fixture reaches `fwd > 0` only
by putting one `_id` in BOTH the epic's `children` and the successor's `subtrees` — a row
with two parents, which `parent_id` cannot produce. The wave-36 pair places the re-homed
row under the successor ONLY, which is what a real `bp task move` leaves behind, and
scores it through the prior census.

Wave 26 adds three, all optional so every fixture above reads identically:
`subtrees` (parent id → rows, which is how a fixture describes a TREE — `children`
stays the epic's DIRECT roster and `forwarded` the successor's, and both are the
seed the walk descends from), `priorCensus` (id → `lifecycle_status` at capture
time, arming the anti-filing arm), and `departed` (id → task document, for a row
the census names that is no longer in the population).

`census/<epic>.json` is not a fixture — it is the COMMITTED PRIOR CENSUS, the
register the anti-filing arm reads on a LIVE run for that epic. It records only
rows that were NOT `done`/`cancelled` at capture, because only those can produce a
filing event. It is a measurement: re-capture it, never hand-edit it — an id
deleted from it is exactly the act the arm exists to catch. It is deliberately NOT
loaded on the fixture path (a fixture is a synthetic world; measuring it against
the live epic's census would name every real row as a departure), and a fixture
that wants the arm carries its own `priorCensus`.

A waiver is FIXTURE-ONLY by construction — it can arrive only through `--ledger`,
so no live run can carry one — and any fixture green says so on its own line
(`FIXTURE-ONLY GREEN: n guard(s) STUBBED … n WAIVED`) and in the machine-readable
token (`mode=fixture stubbed=n waived=n`). A fixture run asserts nothing about the
live ledger: it is a mutation control, and the predicate labels it
`LEDGER FIXTURE — not live`.
