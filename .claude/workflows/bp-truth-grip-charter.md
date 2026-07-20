# Source-of-Truth Grip — epic charter

<!-- doc-tier: agent | canonical-for: source-of-truth-grip-epic | budget: 14000tok -->

## Vision

Every wrong value this session produced was a LEVEL-SKIP: reading at one authority level and
claiming at a higher one. `tooling/grip/` is the substrate that makes that structurally
impossible — one small, fast, LLM-free adjudicator standing between any produced fact and any
durable store, answering in the doctrine's own vocabulary with a nonzero exit and a named reason.

The load-bearing inversion: **authority level is DERIVED by a program from the shape of the
command that re-derives the fact, and can never be raised by what the author claims.** A
self-reported level is an L6 claim about an L1 fact — the laundering the doctrine exists to
prevent, wearing the doctrine's own uniform.

The ratified authority hierarchy (`/papers/survey-once-build-forever`):

| Level | What it is |
|---|---|
| L1 | running system — served bytes, live DB, box HEAD, a real click |
| L2 | `origin/main` |
| L3 | local checkout — a CLAIM about L2; has run 200+ commits stale and lied silently |
| L4 | generated artifacts — openapi.json, token layer, goldens |
| L5 | charters / docs / cards — a CLAIM about L2 |
| L6 | agent memory / the wish — a CLAIM about L5, drifts most |

The four rules the substrate enforces: **R1** a fact records the level it was read at and may
never be quoted above it. **R2** a fact records its DEPENDENCIES, not just its subject. **R3** no
fact is stored without a demonstration the method COULD have answered differently — rejection at
WRITE time, not review time. **R4** conflicting facts are BOTH stored and flagged, never resolved
by write order.

**The anti-goal, ratified and binding:** the ledger is NOT a substitute for verification, it is an
INDEX OF HOW TO VERIFY FAST. Facts are leads to re-check cheaply, never settled truth. Survey must
NOT spend fewer agents — same surveyor count, better questions. Spending less is how the
adversarial layer quietly dies.

**Order is load-bearing:** provenance schema FIRST, controls as a write-time gate SECOND,
verify-writes-back THIRD, survey-reads-leads LAST. If wave 1 ships only the gate and stores
NOTHING, it has succeeded. A corpus that earns trust from its first row beats a corpus with trust
bolted on afterward, which is worth nothing.

## Decisions

- **D1 — The grammar levels the COMMAND, never the prose.** A new structured `rerun` field holds
  one literal shell command; the `evidence` narrative is L6 by construction and can never raise a
  level. *Why: a prose-scanning extractor scored L1 and L2 precision at 0.67 against 60
  hand-labelled real strings and promoted the text "OPEN — requires a run against the deployed
  build" to L1 — the disease wearing the doctrine's uniform.*

- **D2 — Level is DERIVED from the command's head and shape, and the derived level is a CEILING.**
  L1 = `ssh <user>@<host>` or `curl <scheme>://<non-loopback-host>`; L2 = `git show <ref>:<path>`
  or `gh api`; L3 = local read, scoped grep, local test run, `node <script>`; L4 = a read of a
  known generated-artifact path; L6 = no command. *Why: the author's claim becomes a hypothesis
  the gate tests, which is the only arrangement where compliance is not required for correctness.*

- **D3 — No rerun command means DEMOTED to L6, never REJECTED.** *Why: the briefed grammar
  defaulted 67.7% of real honest evidence to L6 against a true rate near 13.7%; a gate that
  punishes honest work gets routed around within a wave, so the honest path must be the cheap one
  and the fix must take ten seconds.*

- **D4 — The gate RE-EXECUTES the literal command and requires the claimed observable to
  reproduce. Its verdict wording is "re-derived just now", never "verified read".** *Why: a
  syntactically perfect curl the author never ran passed both the grammar and re-execution — the
  gate certifies RE-DERIVABILITY, never authorship, and any wording implying otherwise is itself
  the level-skip.*

- **D5 — Reachability keys on the (http_code, exit_code) PAIR, and a probe that cannot run yields
  a third verdict UNAVAILABLE — never a pass, never a rejection.** *Why: 404+exit0 (wrong route)
  and 000+exit28 (host down) collapse into "non-200", letting a network outage forge a pass-shaped
  absence claim; and ssh is a laptop property — guerrilla answers, `89.167.28.206` denies with the
  same key, and CI has neither.*

- **D6 — An empty or failed read is NULL-READ, a distinct verdict, and may never become an
  admissible negative claim.** *Why: the "0-byte fixture" reading had no 0-byte artifact anywhere
  on disk across 993 worktrees or on origin/main — a read returned empty and an agent stored it as
  a fact.*

- **D7 — Only DISCRETE predicates are admissible.** A fact whose re-derivation yields a
  distribution must declare a predicate or be inadmissible. *Why: one L1 command returned a stable
  code=200 while t_total drifted 0.116 / 0.135 / 0.118 across three runs — R4 would fire forever
  on noise.*

- **D8 — Synchronous admission requires a FACT-SCOPED command AND a warm toolchain; corpus-wide
  and cold-Elixir commands are ASYNC-DEFERRED at their derived level.** *Why: `git show` is
  94-337ms and scoped grep 149ms, but a first targeted `mix test` in a fresh worktree costs 81.74s
  because Elixir compiles all 800 files — build warmth is a third input the "scope decides, not
  tool" rule missed.*

- **D9 — A path-less line reference is REJECTED.** *Why: `notifications.ex:389-397` sent a
  verifier to `api/lib` and returned empty; the real file was
  `cloud/lib/barkpark_cloud/notifications.ex`.*

- **D10 — NOTHING is stored durably this wave. `tooling/research-coverage` is NOT joined, and is
  BLOCKED as a wave-2 target until its ledger is reproducible.** *Why: the same command at the
  same commit reports 50.1% in the main checkout and 0% in a clean worktree because
  `research-ledger.json` is gitignored; `record()` strips unknown fields (proven by mutation) and
  two writers staggered inside an ~11s window silently lose one's entire contribution (proven).*

- **D11 — `tooling/doc-truth` is reused for METHODOLOGY and its path/lineref verifier only, with
  NO authority.** *Why: it self-declares "a LEAD GENERATOR, not an authority" at
  `verify-docs.mjs:14`, its `verifyCommand` "confirmed" four guaranteed-to-fail commands because
  curl/git/mix resolve on PATH, and its only root is `git rev-parse --show-toplevel` — it tops out
  at L3 and has no level concept.*

- **D12 — The adversarial fixture is SIX ratified specimens, each LABELLED with the rule that
  catches it; unratified specimens are labelled UNCAUGHT.** *Why: the ratified table has six rows,
  not seven, and 420px-vs-340px is a unit/identity confusion at one level that R1 structurally
  cannot catch — labelling the gap honestly is the anti-vacuity discipline.*

- **D13 — The evidence corpus is snapshotted INTO `tooling/grip/fixtures/` with its harvest
  command stored beside it.** *Why: 29,959 real evidence strings live only under `~/.claude`,
  outside the repo, unbacked-up and prunable — an unfrozen quarry evaporates.*

- **D14 — The schema change is a `rerun` field ON `facts[]`, not a second array; SURVEY_SCHEMA
  gets it too.** *Why: `proofs[]` already carries command+output 7,623 times but its `claim` joins
  a `fact.claim` only 0.3% of the time — two parallel arrays with no key — and SURVEY_SCHEMA has
  no command carrier at all, so survey is where the gate is blind.*

- **D15 — The never-fewer-agents floor is a JS `throw`, not schema `minItems`.** *Why: the throw
  path is certain and precedented at `bp-epic-cycle.workflow.js:27`; whether the host validator
  honors `minItems` is unproven and cannot be proven without running a wave.*

- **D16 — `bp search "<terms>"` is corrected to `bp search query "<terms>"` at both root
  sources.** *Why: the bare form exits 2 with a usage error, and at least five prior waves
  independently rediscovered it and silently lost prior-art coverage that reads exactly like a
  real absence.*

- **D17 — The gate ships as an importable ESM module plus a CLI; the workflow seam is a later
  round whose FIRST obligation is probing whether workflow files may `import`.** *Why: all three
  workflow files have zero fs/exec/require, so in-JS adjudication is the only enforcement
  available today — but no workflow uses `import`, so that capability is unproven, and `main` has
  no branch protection or rulesets, which makes a CI-only grip job advisory theatre.*

- **D18 — Every gate carries an inline `--selftest` and a THIRD outcome class for a control that
  did not fire.** *Why: seven scripts in this repo already prove guards by plant-and-rescan
  mutation, and `pds-secret-scan.sh`'s exit-3 "CONTROL DID NOT BEHAVE AS A CONTROL" is exactly the
  DEMOTED idea in miniature — a non-firing control must never be absorbed into a normal pass.*

## Roadmap

Ordered. Round = dispatch round; a slice never dispatches beside an unmerged dependency.

| # | Slice | Round | Size | Surface |
|---|---|---|---|---|
| 1 | `tgw1-level-grammar` — the fact record + pure level-derivation over the `rerun` command | 1 | medium | tooling/grip |
| 2 | `tgw1-fixture-quarry` — harvest + freeze the evidence corpus and the six ratified specimens | 1 | medium | tooling/grip |
| 3 | `tgw1-rerun-executor` — re-execution, (code,exit) reachability, UNAVAILABLE, NULL-READ, scope/warmth classifier | 1 | medium | tooling/grip |
| 4 | `tgw1-workflow-provenance-seam` — `rerun` on both schemas, the `bp search query` fix, the fan-out floor | 1 | small | .claude/workflows |
| 5 | `tgw1-adjudicator` — the verdict engine composing grammar + executor, conflict keyed on (subject, quantity) | 2 | large | tooling/grip |
| 6 | `tgw1-acceptance-suite` — fail-before / pass-after / never-cry-wolf / catches-a-plant, every rejection class firing | 3 | large | tooling/grip |
| 7 | `tgw1-workflow-gate-wiring` — probe the import seam, run the gate over every returned fact | 3 | medium | .claude/workflows |

Later waves, in the ratified order: **wave 2** verify-writes-back (blocked on D10 — the
research-coverage ledger must become reproducible first); **wave 3** survey-reads-leads; **wave
4+** the server-side `type:fact` backend, whose grammar must live in an Elixir `before_publish`
hook because schema-v2's cross-field `validations:` slot is parsed but inert.

## Wave log

<!-- one entry per wave: date, slices shipped, grade, what the next wave inherits -->
