<!-- doc-tier: human -->

# research-coverage

The programmatic guarantee that every file in the repository has been evaluated,
and that re-checking costs zero tokens until something actually changes.

```
node tooling/research-coverage/coverage.mjs scan      # report coverage, list stale + new
node tooling/research-coverage/coverage.mjs batches   # fan the stale + new set out to agents
node tooling/research-coverage/coverage.mjs record    # fold results/ into the ledger
node tooling/research-coverage/coverage.mjs prune     # drop deleted files from the ledger
node tooling/research-coverage/coverage.mjs seed      # one-time bootstrap
```

## Files

| File | Tracked | What it is |
|---|---|---|
| `research-ledger.jsonl` | **yes** | The canonical ledger. One line per file entry, sorted by path. |
| `research-ledger.json` | no | Derived pretty cache, rewritten from the canonical form on every write. |
| `coverage-report.json` | no | The last `scan`'s output, including the percentage. Four other tools read it. |
| `batches/`, `results/`, `batch-count.txt` | no | Per-run fan-out state. |
| `coverage.mjs`, `ledger-io.mjs`, `config.json` | yes | The tool. |

`ledger-io.mjs` is the only safe write path: a lockfile mutex, a re-read inside
the lock, a rev CAS, and an atomic tmp+rename. `serializeCanonical` there is the
committed form's serialiser.

## Decision record — the ledger is committed in a canonical form

**The defect.** `research-ledger.json` was gitignored, so it existed on one
laptop and nowhere else — not in git, not in CI, not on any other checkout. The
identical command at the identical commit reported a real figure there and a
flat zero on a clean worktree, because `loadLedger` found no file, returned an
empty default, and the classifier then honestly counted every file as
never-researched. That is not a coverage instrument; it is a machine-local cache
with a percentage printed on it.

**What was rejected.** Committing the pretty JSON as-is, and moving the ledger
into Barkpark with rev-fencing.

- *Commit the pretty JSON.* One line of `.gitignore`, but the file spends about
  nine lines on every entry and serialises in **object insertion order** rather
  than a fixed one. Both cost churn, measured below: 2.5x the changed lines on a
  single-file re-record, and a whole-file reflow whenever a write happens to
  hand the serialiser a different key order. Rejected on churn, not on size.
- *Move it into Barkpark with rev-fencing.* This would also close the
  concurrent-clobber defect — except that defect is already closed, by
  `withLedger`'s lock plus CAS plus atomic rename. So the bp route is a
  materially bigger build (a document type, a fetch on every `scan`, a network
  dependency in a command that must work offline and in CI, and a new failure
  mode where the ledger is unreachable rather than merely absent) for the same
  reproducibility the committed file already gives. Rejected as cost without a
  matching gain for this row.

**Chosen.** A committed canonical form, `research-ledger.jsonl`, with the pretty
JSON kept as a derived, gitignored cache. One line per file entry, sorted by
path; line 1 is a header carrying `meta` and any other top-level key. Key order
inside a line is fixed by the serialiser — the canonical fields in their
declared order, then any preserved unknown key sorted — so the form does not
depend on object insertion order and `serialize(parse(x))` is `x` byte for byte.

**Measured storage cost** (4,508 entries, the corpus as recorded):

| Form | Lines | Bytes |
|---|---|---|
| `research-ledger.json` (pretty, was gitignored) | 40,581 | 2,965,284 |
| `research-ledger.jsonl` (canonical, committed) | 4,509 | 2,694,756 |

9.0x fewer lines, and about 270 KB smaller. The bytes barely move because the
payload — each file's role, description, and what-breaks-if-wrong — is the
research itself, not formatting. **No field was dropped.** Nothing in an entry
is derived or cached: `hash` and `researchedAt` drive the staleness check, and
`score`, `role`, `description`, `whatBreaks` and `tier` are the agent-produced
research the ledger exists to hold. For the record, a hash-only variant
(`path`, `hash`, `researchedAt`) measures 4,509 lines and 557,193 bytes — a
2.1 MB saving bought by deleting the corpus, which is not a trade this row is
allowed to make.

**Measured churn.** A throwaway twenty-file repository, both forms tracked, both
already at their steady-state order, driven by the real `record` command.

Re-recording **one** file of twenty:

```
$ git diff --stat -- tooling/research-coverage/research-ledger.jsonl \
                     tooling/research-coverage/research-ledger.json
 tooling/research-coverage/research-ledger.json  | 10 +++++-----
 tooling/research-coverage/research-ledger.jsonl |  4 ++--
 2 files changed, 7 insertions(+), 7 deletions(-)
```

Re-recording **all twenty**:

```
 tooling/research-coverage/research-ledger.json  | 164 ++++++++++++------------
 tooling/research-coverage/research-ledger.jsonl |  42 +++---
 2 files changed, 103 insertions(+), 103 deletions(-)
```

Exactly two lines move on a single-file re-record of the canonical form: the
header, which carries `meta.rev` and `meta.updatedAt`, and the one entry whose
research changed. Churn is proportional to research activity, not to the number
of files in the repository. `test/canonical-form.test.mjs` asserts that the
*only* moved lines are those two, deriving the entry's index rather than
hardcoding it.

And the pretty form has a second, worse mode the canonical form cannot have. It
serialises in object insertion order, so a write that hands the serialiser a
different order reflows the whole file. The same one-file edit, from a base
written in results order instead of sorted order:

```
 tooling/research-coverage/research-ledger.json  | 88 ++++++++++++-------------
 tooling/research-coverage/research-ledger.jsonl |  4 +-
```

Eighty-eight lines for a one-file change. `serializeCanonical` sorts by path and
fixes the key order, so this shape is unreachable.

**The ledger is excluded from its own coverage.** `config.json` excludes
`research-ledger.jsonl` (and the pretty cache) from the enumerated file set.
Now that the canonical form is tracked it would otherwise be enumerated, and
every `record` changes its hash — so it would re-stale itself the instant it was
recorded and one entry would churn forever.

## No coverage number is a durable fact

The only durable fact about coverage in this repository is the command that
re-derives it:

```
node tooling/research-coverage/coverage.mjs scan
```

Nothing tracked here states a coverage figure, and
`test/canonical-form.test.mjs` pins that: it walks every tracked file under this
directory and refuses any percentage outside `coverage.mjs`'s own completion
message, which is a format string printed from a live computation rather than a
recorded number. `coverage-report.json` — which does hold the figure — stays
gitignored, and the tools that consume it (quality, cody, status) already treat
an absent report as *not applicable* rather than as a zero.

**An absent ledger refuses.** With no ledger on the machine, `scan` and
`batches` exit `3` naming `LEDGER_ABSENT` instead of reporting a flat zero that
carries the exact typography of a measurement. A present-but-empty ledger still
reports, because that is a real zero — the distinction is the point.
