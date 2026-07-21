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

- **D19 — A workflow file may NEVER `import`, `require`, `eval`, or read the clock. This is
  permanent host design, not a gap, and NO capability task is filed against it.** *Why: the host
  evaluator, extracted verbatim from the compiled binary and reproduced locally, parses with acorn
  in module mode then compiles the body with `vm.Script` — a classic script, never a module — so
  static `import` dies at compile with "Cannot use import statement outside a module"; dynamic
  `import()` hits a hand-written `importModuleDynamically:()=>{throw sNe("import() is not available
  in workflow scripts.")}`; `require` is undefined; and `createContext(…,{codeGeneration:{strings:
  false,wasm:false}})` closes the smuggle-the-grammar-as-a-string workaround (`eval` and `new
  Function` both raise EvalError). A separate AST walk hard-refuses `Date.now`/`Math.random`/`new
  Date()` with "breaks resume". D17's probe is CLOSED: the answer is NO, in every direction.*

- **D20 — The in-workflow half is GRAMMAR-FREE by construction, and deliberately dumber than
  `record.mjs`.** It may check only that a fact's `rerun` is present and non-empty, and demote +
  annotate in place. *Why: D19 forecloses sharing the grammar by import, so the only way to avoid a
  sixth hand-copy — this epic's own defect class — is to put no grammar in the workflow at all. If
  the in-workflow half ever needs to AGREE with `record.mjs` on a judgment call, that is the design
  error, not a missing import.*

- **D21 — Aiming the verify fleet by authority deficit is CUT, not deferred.** *Why: measured over
  the frozen 1,902-entry corpus through the real `deriveLevel`, the deficit has CV 0.355, two
  random facts TIE 48.9% of the time, entropy is 1.118 of a possible 2.322 bits, and L1+L2 together
  are 1.8% — the signal is near-constant. And `FACT_ITEMS` has no `load_bearing` property at all, so
  (load-bearing × authority deficit) has ZERO of its two structured inputs. Shipping it would
  launder a near-constant into a ranking that looks measured and is not — the exact laundering this
  epic exists to abolish, reintroduced one layer up.*

- **D22 — The wave is launched by `scriptPath`, never by name, and the checkout is synced FIRST.**
  *Why: the host does NOT snapshot workflow file content — a file swapped ~50s after a session
  started delivered the NEW sentinel to the dispatched subagent — but the workflow NAME registry IS
  a session-start snapshot. This wave was launched by name from a checkout 20 commits behind, so it
  ran the pre-#4915 file and measured 0 `rerun` keys across 6,891 facts machine-wide. That 0% is an
  offer never made, not a behaviour. The discrimination experiment has still never run.*

- **D23 — "676 evidence strings, 24% quote a command" is RETIRED and may not be quoted again.**
  Re-derived on the frozen fixture (n=1,902): command-quoting **14.6%**, file:line **59.3%**,
  multi-sentence >200ch **22.4%**, bare `path:line` **3.4%**, `origin/main` **8.4%**. *Why: 676 came
  from a `bp task ls` pull capped by that CLI's own paging bug and produced four different values
  for one count. The enforcement-ambition cap SURVIVES and strengthens — 14.6% is lower than 24%.
  Also: `has_command_field` is a DEAD field, false on 1902/1902 because `FACT_ITEMS` has no
  `command` key; it is not a 0% command rate and must never be cited as one.*

- **D24 — The adjudicator COMPOSES `record.mjs`'s `admitFact`; it re-derives no rejection class. The
  verdict vocabulary is TEN names, not seven.** `FAILED`, `REACHABLE-WRONG-ROUTE` and
  `HOST-UNREACHABLE` pass through as first-class verdicts. *Why: `admitFact` already emits
  LEVEL-SKIP, PATHLESS-REF, INADMISSIBLE-CONTINUOUS, MISSING-SUBJECT, MISSING-CLAIM, BAD-DEPS,
  UNKNOWN-LEVEL and demote-to-L6 — a superset of what the adjudicator brief asked a builder to
  produce from `level.mjs` raw, and rejections ACCUMULATE rather than abort. And folding FAILED into
  REJECTED collapses "your fact is FALSE" into "your fact is MALFORMED" — the exact distinction
  `rerun.mjs` says its enum exists to prevent.*

- **D25 — R4 CONFLICT ships as a directly unit-tested API and is NOT claimed live.** *Why: no live
  schema carries `subject` or `quantity` at all (0 occurrences in SURVEY_SCHEMA/VERIFY_SCHEMA/
  FACT_ITEMS), so nothing upstream can populate an R4 key this wave. Measured collision rates on the
  real corpus are vacuous at every honest grain — 0.05% on exact claim, 2.4% on full `path:line`
  (and all 37 colliding groups are CORROBORATION between compatible facts, not rival values) —
  while coarsening to basename jumps to 61% by conflating exactly what unbuilt R2 must separate. The
  only R4 specimen in the fixture is self-declared synthetic. A CONFLICT state that structurally
  cannot fire, shipped as live, reads green forever.*

- **D26 — D10 is AMENDED. Durable storage IS permitted from this wave, as ONE immutable file per
  run, folded at read time.** `tooling/grip/ledger/<run>-<key>.json`; the row is `(subject,
  quantity, rerun, derived_level, deps[], observed_at)` with **no value field**, and `observed_at`
  means "when this recipe last ran", never "when this was true". `observed_at` is supplied by the
  writer — the workflow has no clock (D19). *Why: the anti-goal becomes a property of the schema
  rather than a discipline, because a ledger containing no truth cannot be mistaken for settled
  truth. One-file-per-run makes D10's lost-write class impossible rather than managed: add/add
  merges clean across concurrent worktrees (proven), and `tooling/grip/ledger/` is NOT gitignored
  (unlike `tooling/research-coverage/research-ledger.json`, which is — D10's trap, confirmed live).
  `tooling/research-coverage` stays OUT of scope and its own reproducibility block stands.*

- **D27 — Verify WRITES the ledger rows; Decide COMMITS them.** *Why: the JS orchestrator genuinely
  cannot persist (zero fs/exec/require in all three workflow files, D17), but the verify PHASE can —
  its "no repo edits" line is a prompt sentence inside this wave's own surface fence, not a missing
  capability. The Decide agent already writes AND commits a file by explicit path in the shared main
  checkout, in-loop, with no worktree isolation — an in-loop committed write is precedented, not
  speculative. So "verify-writes-back" is honest and needs no renaming: written and committed one
  phase apart, in the same wave, never one build-cycle stale. The carve-out is narrow: write ONLY to
  `tooling/grip/ledger/`, never commit, never touch anything else.*

- **D28 — The fan-out floor throws have NEVER fired in a real run, and the charter says so.**
  *Why: swept 659 workflow journals and every `wf_*.json` run record on this machine — zero
  incidents, and every bp-epic-cycle run (including four dispatched AFTER the floor commit merged)
  carries a byte-identical 54,073-char pre-floor script snapshot. Both throws were proven under a
  builder-authored simulation, never in the loop. "The throw is the only enforcement that genuinely
  fires" is an intent, not an observation, until a wave observes one.*

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

Wave 1 landed rows 1-4. Rows 5-7 are superseded by the wave-2 plan below: `tgw1-adjudicator` is
rebuilt as `tgw2-adjudicator` under D24 (compose, don't re-derive), `tgw1-acceptance-suite` becomes
`tgw2-acceptance-suite`, and `tgw1-workflow-gate-wiring` is promoted to the wave-2 PARENT with its
build work split into `tgw2-inloop-gate` (round 1) and `tgw2-verify-writes-back` (round 2).

### Wave 2 — verify-writes-back. Parent task `tgw1-workflow-gate-wiring`.

**The wave-2 blocker is LIFTED by D26, not ignored.** D10's research-coverage clause stands
untouched; the recipe ledger simply never joins that store.

| # | Slice | Round | Size | Surface |
|---|---|---|---|---|
| 1 | `tgw2-grip-quote-safety` — quote-aware `classifySafety` + CWD-hardened, tightened `rerun.test.mjs` | 1 | medium | tooling/grip |
| 2 | `tgw2-adjudicator` — the verdict engine COMPOSING `admitFact` (D24), ten verdicts, CONFLICT unit-only (D25) | 1 | large | tooling/grip |
| 3 | `tgw2-recipe-ledger` — one immutable file per run, no value field, folded at read time (D26) | 1 | medium | tooling/grip |
| 4 | `tgw2-inloop-gate` — the grammar-free in-workflow demotion+annotation at the one interception seam (D19/D20) | 1 | medium | .claude/workflows |
| 5 | `tgw2-l4-artifact-census` — `GENERATED_ARTIFACT_PATTERNS` derived by running the emitters, not guessed | 1 | medium | tooling/grip |
| 6 | `tgw2-wild-bulk-fanout-floor` — port the D15 throws to `wild-bulk-cycle`, and settle `minItems` empirically (D28) | 1 | small | .claude/workflows |
| 7 | `tgw2-acceptance-suite` — fail-before / pass-after / never-cry-wolf, every verdict class proven able to fail | 2 | large | tooling/grip |
| 8 | `tgw2-verify-writes-back` — the narrow verify-writes / Decide-commits carve-out (D27) | 2 | medium | .claude/workflows |

Later waves, in the ratified order: **wave 3** survey-reads-leads; **wave 4+** the server-side
`type:fact` backend, whose grammar must live in an Elixir `before_publish` hook because schema-v2's
cross-field `validations:` slot is parsed but inert.

## Wave log

<!-- one entry per wave: date, slices shipped, grade, what the next wave inherits -->

### Wave 2026-07-20 — round 1, the substrate. Grade A−.

Paper: `source-of-truth-grip-wave-2026-07-20`. Four round-1 slices built and
reviewed; rounds 2-3 deferred by design (sequenced-rounds law), not stalled.

**Landed** (final branches carry a reviewer `-r` commit):

| Slice | Branch | What |
|---|---|---|
| `tgw1-level-grammar` | `…derive-the-authority-level-from-the-reru-0-r` | `level.mjs` + `record.mjs`: level derived from the `rerun` command alone, claim as ceiling, LEVEL-SKIP / PATHLESS-REF / INADMISSIBLE-CONTINUOUS. 34 tests. |
| `tgw1-fixture-quarry` | `…freeze-the-evidence-corpus-and-the-six-r-1-r` | Frozen evidence corpus (1,902 evidence / 652 proofs, deterministic sample) + the six ratified specimens and two labelled negative controls. 19 checks, 19 controls proven able to fail. |
| `tgw1-rerun-executor` | `…re-execute-a-rerun-command-and-report-a--2-r` | `rerun.mjs`: actually executes, `(code, exit)` reachability, UNAVAILABLE / NULL-READ / ASYNC-DEFERRED / UNSAFE-RERUN. 30 tests. |
| `tgw1-workflow-provenance-seam` | `…give-both-workflow-schemas-a-rerun-field-3-r` | `rerun` on `facts[]` in both cycles, the `bp search query` fix (D16), JS fan-out floors (D15), plus a module-scope schema self-check. |

**Charter landed with this wave.** The charter was authored at `448eee5f9` and
never reached `origin/main`; three of four builders reported they could not read
D1-D18 and worked from their task briefs. It rides the `tgw1-level-grammar-r`
branch. Merge that branch and the dangling pointer closes.

**Defects the review found and fixed** — all three were the epic's own failure
mode committed inside the tooling built to prevent it:

1. **False promotion to L1.** `curl http://[::1]:4000/…` derived L1. The URL host
   extractor stopped at the first colon and captured a bare `[`, which failed
   the loopback test. `LOOPBACK_HOST` already listed `::1` — the intent was
   there, nothing exercised it. A ceiling set too high is a level-skip.
2. **The probe's authority laundered onto the command's.** The executor's HTTP
   branch ruled on the bounded reachability probe and DISCARDED the literal
   command's exit, so `curl <live 200 host> | grep -c ABSENT_NEEDLE` returned
   verdict OK with `admits.pass: true`. The probe now governs reachability only;
   the literal exit governs the verdict. Mutation-proven (29 pass → 28/1 fail).
3. **A frozen `rerun` that could never run.** Specimen 3 carried an unfilled
   `<charter>` placeholder — a template posing as a command — and its `>` tripped
   the write-redirect guard, so the executor refused it UNSAFE-RERUN before
   execution. Found by running the fixture's commands through the other two
   slices; that cross-slice check is worth repeating every wave.

Also closed: vacuous `rerun: "n/a — …"` prose on unratified specimens (now
`null` + `no_rerun_reason`, so absence is typed as absence); the synthetic
no-lag side now declares itself synthetic; the one unproven control (the 4 MB
size bound) is now plantable; the workflow schema contract is a module-scope
throw instead of a throwaway probe, mutation-proven twice.

**What the next wave inherits.** Merge round 1, then dispatch by dependency:
`tgw1-adjudicator` (round 2) once grammar + executor are in; then
`tgw1-acceptance-suite` and `tgw1-workflow-gate-wiring` (round 3) once the
adjudicator merges. The adjudicator is where the wave's honest gaps become
visible and must be closed rather than inherited: the six `caught_by` labels are
HYPOTHESES the acceptance suite has to test, `GENERATED_ARTIFACT_PATTERNS` is
still a guess (`tgw-bl-l4-artifact-inventory`), `KNOWN_WRITERS` has one
hand-seeded entry (`tgw1-writer-census`), and specimen 4 remains honestly
UNCAUGHT — R1 structurally cannot catch it, so R2 dependency recording is the
real next capability (`tgw-bl-r2-dependency-enrichment-substrate`).

D10 still holds: nothing is stored durably, and `tooling/research-coverage`
stays blocked until its ledger is reproducible.

### Wave 2026-07-20 (2) — round 1, verify-writes-back. Grade A−.

Paper: `source-of-truth-grip-wave-2-2026-07-20`. Six round-1 slices built and
reviewed; the two round-2 slices deferred by design (sequenced-rounds law), not
stalled. Every slice ran `builder_model: opus` — the wave's hard model
constraint, verified on all six task documents.

**Landed** (final branches carry a reviewer `-r` commit):

| Slice | Branch | What |
|---|---|---|
| `tgw2-adjudicator` | `…ship-the-verdict-engine-by-composing-adm-0-r` | `adjudicate.mjs` + `cli.mjs`: the verdict engine as a COMPOSITION of `admitFact`, ten frozen names, CONFLICT unit-tested and stated NOT live. 32 tests. |
| `tgw2-inloop-gate` | `…run-a-grammar-free-demotion-gate-over-ev-1-r` | `gateFactProvenance` in `bp-epic-cycle.workflow.js` — one grammar-free interception per resolve, DEMOTE-never-drop. 17 tests under a host-shaped vm. |
| `tgw2-recipe-ledger` | `…store-re-derivation-recipes-never-values-2-r` | `ledger.mjs`: rows with NO value field, `wx` content-addressed immutable writes, conflict observed at fold time. 37 tests, 7 selftest controls. |
| `tgw2-grip-quote-safety` | `…make-classifysafety-quote-aware-so-hones-3-r` | Quote-aware `classifySafety` + interpreter carve-out; suite made invocation-agnostic; vacuous test 21 tightened. 38 tests. |
| `tgw2-l4-artifact-census` | `…derive-generated-artifact-patterns-by-ru-4-r` | `GENERATED_ARTIFACT_PATTERNS` derived from an actual emitter census; marker-splice boundary ruled in a comment. 45 tests. |
| `tgw2-wild-bulk-fanout-floor` | `…give-wild-bulk-cycle-the-same-never-fewe-5-r` | Four named fan-out floors + two survival guards in `wild-bulk-cycle`; minItems settled by reading the host. 10 tests (added in review). |

**The wave's thesis, delivered.** Wave 1 shipped a substrate nothing called.
Wave 2 makes the loop USE it: facts returned by the survey and verify fleets now
pass a demotion gate in-loop, and the durable store exists with a schema that
cannot hold an answer. All six branches merge clean with every gate green.

**Defects the review found and fixed** — the pattern from wave 1 held: the
epic's own failure modes kept appearing inside the tooling built to prevent them.

1. **The ten-name vocabulary leaked through Object.prototype.** `EXECUTION_MAP`
   is an object literal, so a bare index resolved inherited keys — an executor
   returning `toString` / `constructor` / `__proto__` produced a ruling whose
   verdict was a function or `{}`. The guard written to keep the vocabulary
   closed was the one place it failed open. Own-property lookup + non-string
   guard; mutation-proven.
2. **The demotion never reached Decide.** The gate annotated the resolved survey
   objects and Digest saw it, but the Decide projection was
   `{key, findings, relevant_files}` — no `facts[]` at all, and
   `relevant_files` is not even a SURVEY_SCHEMA property. So the phase that
   FILES THE NEXT WAVE'S SLICES was blind to which facts cannot be re-derived.
   The wiring read as done while half-connected.
3. **One rotten row took down the whole ledger fold.** `admitRecipe` gates the
   WRITE path; nothing re-admits the READ path. A non-string subject threw out
   of `recipeKey` and cost every well-formed row in every other file, while null
   rows and subject-less rows silently merged into one bogus empty-key entry.
   Reported at row grain now — never skipped, never fatal.
4. **The quote-safety fix opened four live bypasses.** `su -c`, `watch`,
   `elixir -e` and `iex -e` each rated `rm -rf /tmp/y` SAFE once quoted — all
   commands the executor would then have run. Closed on SHAPE, not a longer name
   denylist: an unknown head handed a quoted argument through
   `-c`/`-e`/`--eval`/`--command`/`--exec` is assumed to execute it, with a
   small allowlist of data-flag heads. That inverts the error direction for the
   unbounded set, which is the point — a wrong allowlist entry costs a false
   refusal, a wrong denylist costs a false permission.
5. **The fan-out floors had no test at all.** The slice's gate was `node
   --check` — a syntax check that cannot tell a floor of 3 from a floor of 0.
   That is the slice's own thesis failing one level up: the anti-goal was prose,
   prose does not run, so it became a throw, and the throw was checked by
   something that does not run it either. Harness committed
   (`tooling/grip/test/fanout-floors.test.mjs`), mutation-proven three ways.
   Also hardened: `"abc".length` is 3 and satisfied `DOMAIN_FLOOR`.

**The number wave 2 was missing, now measured.** The quote-safety builder said
the never-cry-wolf rate was unknown. Over the 651 distinct frozen-corpus
commands, refusal went **84 → 79: five false refusals recovered, zero newly
refused.** Strictly better, no new cry-wolf. The L4 census was likewise
re-verified independently: the corpus re-derives an identical L1 33 / L2 31 /
L3 336 / L6 252, so no historical command was silently re-levelled.

**Honest gaps carried forward, not papered over.** L4 is still 0 across the
frozen corpus — the corpus predates the emitters appearing in rerun commands, so
only `level.test.mjs` can regression-test L4 today. CONFLICT remains unwired and
unproven in the field in both the adjudicator and the ledger. The ledger is
empty: nothing writes a row from a real verify phase yet, which is exactly what
`tgw2-verify-writes-back` is for. And D28 still holds — no fan-out floor in
either workflow has ever fired in a real run; all of it is harness evidence.

**What the next wave inherits.** Merge round 1 (six branches, all green), then
dispatch by dependency: `tgw2-acceptance-suite` once `tgw2-adjudicator` is in,
and `tgw2-verify-writes-back` once BOTH `tgw2-recipe-ledger` and
`tgw2-inloop-gate` are in. `tgw2-verify-writes-back` is the one that makes the
wave title fully honest — until a verifier actually writes a row, the store is a
schema with no contents. Backlog worth taking after that:
`tgw2-fold-reread-derived-level` (the fold trusts a stored derivation, which is
a stored value by another name), `tgw2-l4-grip-corpus-selfref` (safe to apply
once this wave's L3 citations have merged), and `tgw-bl-wild-bulk-roster-floor`
(a fifth, still-unguarded fan-out).

### Wave 2026-07-21 — round 1, survey-reads-leads. Grade A−.

Paper: `source-of-truth-grip-wave-3-2026-07-21`. Four round-1 slices built and
reviewed; the three round-2/3 slices deferred by design (sequenced-rounds law),
not stalled. Every slice carries `builder_model: opus` — the wave's hard model
constraint, verified on all four task documents.

**Landed** (every final branch carries a reviewer `-r` commit):

| Slice | Branch | What |
|---|---|---|
| `tgw3-census-screen` | `…ship-a-fail-closed-allowlist-screen-so-t-0-r` | `screen.mjs`: the three-layer fail-closed screen (host bound → head/sub-verb allowlist → write shapes), importing nothing from `rerun.mjs` (D29). 34 tests, three named sets, measured reach 240/651 = 36.9%. |
| `tgw3-level-compound-fix` | `…close-the-compound-walk-level-skip-and-t-1-r` | `level.mjs` walks compound segments instead of sniffing a head, `bp`/non-`api` `gh` → L2, plus a parseability floor. L6 38.7% → 22.4% over the frozen 651. 71 tests. |
| `tgw3-ledger-honesty` | `…make-a-forged-ledger-row-rejectable-the--2-r` | `admitRecipe(input, {now, screen})`: the injected future bound, Z-only instants, the injected safety screen, `CONFLICT` → `RIVAL-METHOD` (D31/D33/D39). 60 tests, 16 selftest controls. |
| `tgw3-prompt-seam` | `…let-verify-write-ledger-rows-and-decide--3-r` | D27/D35 in `bp-epic-cycle.workflow.js`: Verify's narrow ledger carve-out, DENIED on the worktree branch, Decide staging rows by explicit path, the stranded-file loss ruled in a code comment. 28 source-reading tests. |

**The reach number is HIGHER than D29's and that is the honest read.** D29
records 194/651 = 29.8%; the shipped screen admits 240/651 = 36.9%, because it
screens `cd X && <read>` and pipelines SEGMENT BY SEGMENT rather than refusing
them whole. The builder reported what it measured instead of steering to the
estimate. The two figures have not been proven to measure the same thing — the
29.8% methodology was not reproduced — so **D29's 29.8% should be read as
superseded by 36.9% for the shipped module, and neither number may be quoted as
"coverage of 651 commands"** (the module's own `--census` says so in prose).

**Defects the review found and fixed.** The wave-1 and wave-2 pattern held for a
third time: the epic's own failure modes keep appearing inside the tooling built
to prevent them.

1. **D29's own named danger walked through both layers of the screen.** `curl -o
   /opt/barkpark/deploy/site-deploy.sh` is refused; `curl -so /opt/barkpark/
   deploy/site-deploy.sh` was **ADMITTED**. Short flags cluster, and both layer
   (b) and layer (c) compared `-o` as an exact token. Six more of the same class
   went with it: `curl -sO`, `gh repo clone`, `gh release download`,
   `bp --server=<remote>` (walking straight past the loopback bound),
   `journalctl --vacuum-size`, and `date -s` (a census able to move the system
   clock the ledger's own now-bound compares against). The screen's error
   direction was right; its *parser* was not.
   **The instrument lesson is the real one:** the DANGER SET carried only the
   unclustered spelling, so the measurement built to catch exactly this class
   could not see it. A named set measures the spellings it contains and nothing
   else. All seven now live in `DANGER_SET`, so the selftest carries them — and
   the fixes cost the census **zero** reach (240/651 before and after, pinned by
   a test), which is the check that separates a real fix from cry-wolf.
2. **`gh` was a denylist inside the allowlist module.** `ghRule` carried only
   `GH_WRITE_VERBS`, so any unlisted noun sailed through — the exact shape the
   module's own header argues cannot be complete. Now a noun allowlist with
   per-noun read sub-verbs, with the denylist kept behind it. Corpus reach
   preserved exactly: the 23 `gh` rows use only `api`, `pr`, `issue`, `run`.
3. **The two slices that must meet did not meet.** `ledger.mjs`'s injected
   screen contract read `verdict.message`; `screen.mjs` returns `{ok, reason}`.
   Built in the same round with disjoint file sets, both correct alone, and
   nothing in either suite ever put them in a room together — so every refusal
   printed the generic fallback and **discarded the screen's diagnosis**, in the
   precise place `REFUSED_HEADS` authors a per-head explanation so the log would
   not be a shrug. Verified by wiring the real `screenCommand` in. Both keys are
   accepted now, and a cross-slice test pins the seam.
4. **The prose floor floored a good command.** `find . \( -name a -o -name b \)`
   went L3 → L6: a backslash-escaped paren read as a prose aside because
   `-name` is not a plausible command head. **Zero occurrences in the 651-command
   corpus**, so the before/after distribution was bit-identical with the bug
   present and with it fixed — the same blindness that hid the builder's own
   `sort < in.txt > out.txt` cry-wolf. *A corpus distribution is a LOWER BOUND on
   cry-wolf, never a proof of its absence.* Both controls mutation-proven.
5. **An async screen read as an over-aggressive screen.** A Promise is neither
   `true` nor `{ok:true}`, so the tolerant contract failed it closed under
   `REFUSED-COMMAND` — right verdict, wrong diagnosis, and it would have sent
   whoever wires the CLI next round hunting the wrong bug. Now `SCREEN-NOT-SYNC`.
6. **The copies-that-must-agree question, closed.** The builder flagged that a
   second workflow file might still carry the pre-carve-out verifier prompt and
   did not check. It does not — `bp-epic-cycle.workflow.js` is the only carrier
   — and that is now a test rather than an observation someone made once.

**What the wave did NOT prove, and must not be read as proving.** No dispatched
verifier has yet written a ledger row and no Decide has yet committed one: the
seam is prompt text plus tests that the words are in the shipped file, which is
the ceiling of any prompt slice. **The ledger is still empty.** The loop reads as
closed one wave before it is.

**What the next wave inherits.** Merge round 1 (four branches, all green, all
merging clean together — verified by merging all four onto `origin/main` in one
tree: 272 tests pass, both selftests green, the workflow parses). Then dispatch
strictly by dependency: `tgw3-write-verb` and `tgw3-census-verb` once
`tgw3-census-screen` and `tgw3-ledger-honesty` are in, then `tgw3-leads-verb`
once `tgw3-write-verb` is in. `tgw3-write-verb` is the slice that converts this
wave's opt-in bounds into real seams — until it lands, `admitRecipe`'s `now`
bound is a mechanism nobody passes, and a forger who omits `now` is admitted
exactly as before.

Backlog worth taking after that: `tgw-bl-screen-wire-into-rerun` (nothing calls
the screen yet — a proven capability protecting nothing),
`tgw3-decide-stages-foreign-rows` (Decide cannot tell this run's rows from a
concurrent session's), `tgw3-bl-segment-relevance` (strongest-segment-wins
over-permits when the authoritative segment is not the fact's source — the
sharpest residual in the level grammar), and `tgw3-bl-ssh-bare-host-alias` (a
bare `ssh <alias>` derives L6; pre-existing, and widening `SSH_READ` is a
promotion rule change that needs a decision, not a review fix).
