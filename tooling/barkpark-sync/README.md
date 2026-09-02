<!-- doc-tier: human | canonical-for: barkpark-sync-pipeline | budget: 4000tok -->

# tooling/barkpark-sync

Publishes the codebase graph into a Barkpark dataset: one paper per code file,
the file's source as PortableDoc blocks, dependency and intention references as
content-graph edges.

    node tooling/barkpark-sync/generate.mjs                 # → nodes.json
    node tooling/barkpark-sync/push.mjs --dry-run           # gate + render, write nothing
    node tooling/barkpark-sync/push.mjs                     # publish to the `codebase` dataset
    node tooling/barkpark-sync/graph-view.mjs               # → codebase-graph.html

`push.mjs` flags: `--limit N`, `--host URL`, `--dataset NAME`, `--nodes PATH`,
`--dry-run`, `--no-content`. Connection resolution is the shared chain in
`tooling/lib/barkpark-env.mjs` (flags > `BARKPARK_*` env > `barkpark.json` >
localhost).

## The provenance gate

A published paper is durable and looks measured. Everything on it therefore has
to say which of two things it is:

- **MEASURED · re-runnable** — reach, tokens/loc, churn, the dependency counts,
  ownership, test and defect scores, git history, and the deterministic
  `prior`. A parser, the git log or the dep graph produces these, with no agent
  in the loop.
- **AGENT JUDGMENT (L6) · not measured** — the blended importance and its vote
  record, the consistency verdict, and the `role` / `description` / `why` /
  `whatBreaks` prose. An agent decided these.

`push.mjs` **exits 2** rather than publish a corpus it cannot label. The refusal
names the file and the reason (`missing-provenance`,
`unadjudicated-agent-prose:…`, `blended-without-agent-input`, …). The existing
`--dataset production` refusal is unchanged and exits 2 the same way. Both are
process exits: verify them un-piped, because a pipe eats node's exit code.

The discriminator is not new — `merge.mjs` has always computed
tier/prior/agentCrit/votes/agreement/confidence, `combine.mjs` has always
suffixed an unverified issue candidate with `?`, and the research ledger has
always stamped a tier on its prose. What was new was reading them:

    merge.mjs ──→ importance-chart.json ──┐
    combine.mjs → combined-report.json ───┼─→ generate.mjs → nodes.json → push.mjs
    research-ledger.json ─────────────────┘        (fields.provenance)      (gate)

`merge.mjs` now emits `importance-chart.json` alongside the CSV and HTML. The
blend itself is untouched; the chart simply stopped being spreadsheet-only.

### Two things that were wrong on the page

**`importance` was a prior.** `combined-report.json` rows carry
path/stack/reach/role/status/severity/detail/priority/hotspot/criticalUntested/
refactorWorth/defect/testScore — there is no `importance` key, so
`c.importance ?? s.prior` resolved to `s.prior` on every file while the body
still printed the word `importance`. `fields.importanceBasis` now states which
it is, and the body prints `prior N` unless the 45/55 blend actually happened.
`checkRendered` refuses a prior-based body that regains the word.

**`whatBreaks` was computed and never rendered.** It is now rendered, under the
judgment marker, rather than dropped from `nodes.json` — the defect was that a
judgment sat undisclosed, not that it existed, and `tooling/scope` and
`tooling/map/what-breaks.mjs` read the same field.

The document stamp carries the basis too: `goal_id` is
`imp:<blended|prior>:<score>`, so a census can tell the two apart without
opening a body. The `imp:` prefix is kept — it is the handle blast-radius
sweeps grep for.

## Tests

    node --test tooling/barkpark-sync/test/*.test.mjs

`provenance.test.mjs` proves the predicate over pure functions;
`push-gate.test.mjs` proves the predicate is **wired**, by spawning `push.mjs`
against a closed port and asserting the process exit. Delete the gate block from
`push.mjs` and the unlabelled specimen exits 0 instead of 2 — that is the
mutation the suite is built to catch.
