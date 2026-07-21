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

- **D29 — The census may NEVER gate on `classifySafety`. It gets its own fail-closed screen, and
  the screen is an ALLOWLIST first.** Three layers, in order: (a) a HOST BOUND refusing any command
  naming `ssh`/`scp`/`rsync`, `157.180.90.121`, `178.105.92.191`, `guerrilla`, `barkpark.cloud` or
  `root@`; (b) an allowlist of command heads and sub-verbs that fails CLOSED on an unknown head;
  (c) the `WRITE_SHAPES` gaps patched as SECOND-layer defence, never as the gate. Measured reach:
  the allowlist admits **194 of 651 = 29.8%** of the frozen corpus, and that is the census's honest
  reach — a decay statistic over it may never be reported as covering "651 commands". Two judgement
  calls are ruled here rather than left to a builder: `git fetch` is REFUSED (it mutates `.git`
  refs in a checkout three live cycles share) and all 12 `npx` commands are REFUSED (npx installs
  and executes an arbitrary package). *Why: `classifySafety` marks 26 of 31 synthetic
  outage-capable commands SAFE — including `reboot`, `mix ecto.drop`, `kill -9`, `pkill`,
  `cp <anything> <repo path>` and `curl -o /opt/barkpark/deploy/site-deploy.sh` — and `runRerun`
  gates on it and then calls `spawnSync("/bin/sh", ["-c", cmd])`, so every false-safe is an
  execution. A patch was written, measured and made able to fail (22/22 danger refused, 0/7
  over-refusals, 0/12 cry-wolf, 0/18 existing `mustAllow` broken) — and it took FOUR correction
  rounds against the corpus, oscillating between false-safe and false-refusal each time, with the
  full corpus in hand and a harness running. `rerun.mjs:75` and `:121-131` already say it: "a
  denylist of mutating APIs cannot be complete… the verdict it supports is 'no write shape
  detected', never 'this command cannot write'." A second verifier, screening the corpus from the
  opposite direction to run the decay census, independently had to write the same second denylist
  and rejected 5 systemctl and 5 deploy-script commands `classifySafety` green-lit. Two
  investigations, opposite directions, same hole.*

- **D30 — The "cheap high-value" `L3_HEADS` head-token fix is CUT AS WORDED and REPLACED.** Adding
  `bp`, `gh` and `cd` to `L3_HEADS` was the Digest's cheapest recommendation; verification refuted
  it three independent ways and it may not ship in that form. What ships instead, in one slice:
  (a) the curl/wget/URL-sniff L1 check is UN-GATED from head-only matching so it fires anywhere in
  a compound; (b) a wrapper-strip path handles `cd X && …`, `for … do …` and env-assignment
  prefixes so the head token is found PAST the wrapper — adding no head to `L3_HEADS`; (c) `bp` and
  non-`api` `gh` route to **L2**, the level `gh api` already holds, because they are remote-API
  reads; (d) a PARSEABILITY FLOOR: a `rerun` string that is not a syntactically valid command
  cannot derive above L6. *Why: (1) `bp` reads `https://guerrilla.barkpark.cloud` and `gh` reads
  `api.github.com` — both live remote reads — so filing them at L3 "local checkout" is a two-level
  SKIP, this charter's own line 50 disease wearing the doctrine's uniform, and it would mislabel
  volatile remote state as checkout-stable, corrupting the decay axis. (2) `deriveLevel`'s L1
  curl/wget check is head-gated while `SSH_READ` is not, so adding `cd` makes
  `cd /opt/barkpark && curl https://guerrilla.barkpark.cloud/health` derive **L3** — it was L6,
  safe-by-demotion — a proven authority inflation on a command that provably reaches production,
  with ZERO tests covering any compound `&&` shape. (3) 13.3% of the frozen corpus's `rerun`
  strings are PROSE, not commands (`python3 confusion matrix (15 per PREDICTED class…)`,
  `grep/read <path> around lines 200-219`), and `deriveLevel` grades 33 of those 58 at L2/L3
  because it inspects a head token and never asks whether the string parses — so the head-token fix
  shipped ALONE would move prose INTO L3 and make the grammar's central promise weaker, not
  stronger. The parseability floor errs by DEMOTION, which D3 already establishes as the safe
  direction.*

- **D31 — `observed_at` gets a caller-supplied `now` bound, and the CLI sources `now` from the
  SHELL, never from agent-supplied JSON.** `admitRecipe(input, { now })` compares ISO strings and
  rejects a future `observed_at`; omitting `now` admits, so no existing caller breaks. The WRITE
  verb bakes `date -u +%Y-%m-%dT%H:%M:%SZ` into itself. `observed_at` MUST be Z-only at the write
  seam, with a named rejection for an offset form. *Why: a forged row — two commands never run,
  dated 2031 and 2087 — was ADMITTED, written to disk and folded back as authoritative, one at
  **L1** and one at **L2**, and the L2 one does not even execute (`fatal: path
  'tooling/grip/ledger/recipes.json' does not exist in 'origin/main'`). Every rejection class that
  fires is a SHAPE class; zero honesty classes exist. Typing an ssh-shaped string mints L1 for
  free. Of the three doors offered — prompt discipline, a `Date.now` bound, or nothing — the
  `Date.now` bound reds TWO tests, and the second red is the finding: a fixture hardcoded
  `2026-07-21T09:00:00Z` sits 8 hours in the future, so a clock in the module converts a
  deterministic suite into a wall-clock-dependent one, invisibly. The caller-supplied bound passes
  37/37, keeps the module clock-free, and rejects the forgery. Z-only is required because lexical
  ISO comparison is correct only for same-offset instants, and normalising offsets needs
  `Date.parse`, which re-trips the clock-free grep the fourth door exists to avoid.*

- **D32 — `subject` is MINTED from the `rerun` command's first normalised repo path token, with a
  `cmd:<head-token>` fallback; `quantity` is minted from the command's verb phrase. Neither is ever
  free-typed or derived from claim prose.** *Why: over this wave's own 104 real survey facts, a
  claim-derived subject produces **104 distinct keys out of 104** — a provably injective key, a
  `detectConflicts` that can never fire and a leads index in which nothing is ever a lead. Path-token
  minting gives 67% coverage, 22 distinct subjects, and **8 subjects shared by 2+ facts covering 56
  of 104** — a working index (`bp-epic-cycle.workflow.js` ×23, `ledger.mjs` ×14). `findRefs`/
  `classifyRef` are the WRONG tool and were measured as such: `REF_CANDIDATE` requires a literal
  `:digits` suffix and scores 0 of 104 on both claims and reruns. The fallback is what keeps the
  verb from ever reporting 100% REJECTED.*

- **D33 — The ledger fold's flag is RENAMED to `RIVAL-METHOD`. The adjudicator's `CONFLICT` stays
  library-only (D25 stands), and `tgw2-ledger-adjudicator-vocab`'s premise is FALSE.** *Why: a 2×2
  probe ran all four cells. `foldLedger` fires on ≥2 distinct rerun COMMAND STRINGS and has no
  value field to compare, so it fired CONFLICT on `wc -l /abs/path` vs `wc -l rel/path` — both
  verified to output `544`. `detectConflicts` fires on ≥2 distinct claim VALUES and never reads
  rerun, so it correctly returned 0 conflicts on that same pair and 2 on a genuine `544` vs `999`
  disagreement, which `foldLedger` is structurally incapable of seeing. The shapes are not
  identical by construction — they detect OPPOSITE things — so re-pointing the ledger's constant at
  `VERDICTS.CONFLICT` would import a name for a different concept, making one canonical string
  definitionally shared by two incompatible meanings. Under D32's path-grain key, `RIVAL-METHOD`
  will fire on those 8 corroboration groups on day one: that is the PRODUCT — "multiple checks
  exist, re-run and compare" — not a defect, and it must be documented as expected before the read
  path ships, or the first honest multi-recipe entry discredits the flag permanently.*

- **D34 — The surface fence is PATHS, never a directory.** `tooling/grip/**`,
  `.claude/workflows/bp-truth-grip-charter.md`, `.claude/workflows/bp-epic-cycle.workflow.js`.
  Nothing else, and specifically no other charter under `.claude/workflows/`. *Why: that directory
  holds 80+ files including three actively-running epics' charters, and the hazard is live, not
  theoretical — open PR #5106 and an unpushed local commit both append to
  `bp-cloud-gui-remake-charter.md` at the same anchor line 1331, so whoever pushes second eats a
  conflict. A fence stated as a bare directory reads as permission to edit those.*

- **D35 — The Verify carve-out and Decide's commit ship in ONE slice, the carve-out is granted ONLY
  in the shared-checkout branch, and the stranded-file case is ruled: THE LOSS IS ACCEPTED.**
  A verify assignment that sets `needs_worktree` may not write ledger rows, and Digest's prompt
  says so. If Decide crashes or cuts zero slices, uncommitted rows are lost; no sweep is built, and
  a code comment states that this is a decision. *Why: amending "no repo edits" without extending
  Decide's explicit-path commit strands rows in a checkout other sessions share — Decide's prompt
  today commits exactly one file, the charter, "by explicit path only — never `git add -A`", and
  names no other path. There are TWO stranding paths, not the one the plan assumed: a
  `needs_worktree` verifier writes into its own throwaway worktree, which Decide never sees no
  matter how its commit is amended — so the carve-out must be scoped to the branch that shares
  Decide's checkout, or the ruling looks complete while staying silently lossy. No sweep is built
  because a sweep in a contended checkout is more dangerous than the loss, and a recipe is cheap to
  re-derive by construction — that is the entire point of the store. Silence here would have been
  the defect; this is the ruling.*

- **D36 — The wave's headline is THREE numbers, and the Digest's four are RETIRED.** Published:
  **100% PRESENT / 93.1% EXECUTABLE / 86.3% ANSWERING**, over **104** facts. Fill rate may never be
  published alone — it is the weakest of the three. *Why: the Digest reported 95 facts, 14.7%
  nominal L6, 13-of-14 bp-or-gh, and "exactly one genuine L6 ≈1.1%". Re-extracted programmatically
  from the 18 raw surveyor transcripts, every one of those four is wrong: **104** facts (the digest
  lost 9), nominal L6 **19/104 = 18.3%**, bp-or-gh **14/19 = 73.7%**, and TRUE L6 **0/104 = 0.0%**
  — there is not one unclassifiable command in the corpus. The cause is the finding: the digest
  levelled a hand-normalised PARAPHRASE of its own corpus. 27 of its 95 strings appear nowhere in
  the survey output, real paths were replaced with a literal `x` placeholder, and `cd <path> &&`
  prefixes were STRIPPED — which is exactly the wrapper `headToken` cannot see past, so the
  normalisation silently converted L6 rows into L3 rows. The digest measured its own typing. The
  predeclared prediction of ~85% L6 is REFUTED, and it was predeclared in a form that could not be
  retrofitted, which is the discipline working. The honest name stays long: "fill rate under the
  wave-2-shipped, already-rerun-tutored prompt" — four live instruction sites push on rerun and
  this wave added zero, so it is a clean read of the shipped prompt but NOT evidence about organic
  agent behaviour.*

- **D37 — D21's entropy statistic is RETIRED and may not be quoted again; D21's DECISION stands.**
  The figures struck: entropy 1.118 of 2.322 bits, `L1+L2 = 1.8%`, buckets `{L1:8, L2:27, L3:1047,
  L6:820}` summing to 1902. *Why: it is not re-derivable from anything committed. The extraction
  script that produced it is absent from `tooling/grip/` and from that path's entire history, and
  it cannot be reproduced by the shipped grammar because `deriveLevel` reads a `rerun` field alone
  while the 1,902-entry `evidence` array has no command field at all — applying the real
  `deriveLevel` to what those rows actually carry returns L6 for 1902 of 1902. That is an L6 claim
  by this epic's own grammar, sitting inside the epic's own trial-cutting rationale, and it gets
  the same treatment D23 gave the retired 676/24% figure. The QUALITATIVE finding survives — L1+L2
  near-zero, L3/L6 dominant — confirmed independently by two methods. The wave-2 corpus census
  (L1 33 / L2 31 / L3 336 / L6 252 over the 652 `proofs`) is a DIFFERENT corpus and remains valid;
  any census verb must name which corpus it read.*

- **D38 — The census verb must classify SILENCE-AS-ANSWER explicitly, and the answer-DRIFT rate is
  UNMEASURED and may not be quoted.** *Why: 7 of 104 facts have empty output as their CORRECT
  answer — 4 `rc=0`-with-no-stdout byte-identity proofs and 3 `grep`-`rc=1` absence proofs — so a
  naive `rc==0 && stdout` predicate scores all 7 as decayed and INVERTS three of them, on a clean
  corpus. The decay axis was insurance and it paid: over 406 screened commands, **59.4% still
  answer, 22.4% have genuinely decayed** (a FLOOR — the 245 excluded commands are systematically
  more decay-prone), and **13.3% were never executable commands at all**. The single most valuable
  specimen is an absence claim that has gone false: `git ls-tree -r origin/main | grep -i
  "internal/scaffy"` recorded "(empty output — no matches)" and today returns 58 files — a
  value-storing index would have got that wrong where a recipe-storing index gets it right, which
  is the strongest empirical argument for D26 anyone has produced. The drift rate is a different
  matter: the 154 mismatches measured are truncation-bound, not drift, because only the first 200
  chars of stdout were captured. It is a BOUND, not a rate, and it is filed as backlog rather than
  quoted.*

- **D39 — The write seam gets a safety gate BY INJECTION.** `admitRecipe` takes an optional `screen`
  predicate and rejects a command the census screen would refuse to run, under a named class. The
  ledger imports nothing from the screen module; the CLI wires them together. *Why: `admitRecipe`
  never calls any safety check, so `systemctl stop bp-crux-parent` and `rm -rf
  /opt/barkpark/releases` are both ADMITTED as recipes today — and a recipe is precisely a thing
  this epic exists to make agents re-run cheaply and often. The danger is not only that the census
  re-executes historical commands; it is that the store will happily persist an outage-capable one
  for someone else to re-run later. Injection rather than import keeps the two slices' files
  disjoint so they build in the same round.*

- **D40 — Merge is proven by CONTENT on `origin/main`, never by commit ancestry, and the ten
  done-but-open slices are closed on that basis.** *Why: all 7 distinct branch-tip SHAs cited by
  those tasks return `is-ancestor exit=1` against `origin/main` — squash-merge erased ancestry for
  every one — while each slice's characteristic exports are present verbatim on main. An
  ancestry check would have produced 10 false negatives; a content check produced 10 true
  positives. The urgency is not hygiene: all 10 currently surface in `bp task ready --all` with
  claims expired since 2026-07-20T13-16Z, so `bp task next` would hand a builder already-shipped
  work today. Note also that the verification recipe circulated for this check was itself broken —
  it read a `tasks`/`documents` key where the API returns `docs`, and omitted `--all` against a
  905-row pool, so run verbatim it printed an empty list and read as good news. A vacuous green.*

- **D41 — The wave-3 landing (four branches plus the D29–D40 charter commit) is a PRECONDITION,
  not progress, and it is landed by one PR before any wave-4 builder flies.** *Why: proven by dry
  run against three successive tips. All four branches merge clean in the order screen → level →
  ledger → verify-seam, and `a96aacce6` cherry-picks clean (rc=0, 208 insertions, one file) despite
  sitting on a local `main` diverged by three other epics — because it is the tip of that divergence
  and touches exactly one file. But the sharpest finding is the negative one: on the fully merged
  tree, `git ls-tree HEAD --name-only tooling/grip/ledger/` STILL returns only `README.md` and
  `node ledger.mjs --help` still prints `usage: node ledger.mjs [fold [dir] | --selftest]`. Round 0
  buys a correct record and zero rows. Budgeting it as progress toward "the ledger stops being
  empty" would under-plan the wave. It is landed as a PR from an isolated worktree — never as a
  commit to the shared checkout's local `main`, which is how D29–D40 went missing in the first
  place.*

- **D42 — Between the four artifacts and a charter commit, the charter commit is the one that
  cannot be deferred, because a decision nobody can read is a decision that does not exist.**
  *Why: observed directly mid-flight. After the four merges but BEFORE the cherry-pick, the charter
  held exactly 28 decision rows while the wave-log added by branch 4 cited D29, D31, D33, D35 and
  D39 — five references to decisions with no text anywhere on the branch. That is precisely the
  state a round 0 that only pushed branches would have left on main, and it is wave 1's
  charter-never-reached-main defect repeating one wave later. Every wave-3 and wave-4 brief was
  written against D29–D40; a fresh worktree saw D1–D28.*

- **D43 — `grip leads` ships REDUCED, on measured grounds: the substring filter is the feature, and
  the staleness band, the ranking, and the RIVAL-METHOD flag are all cut.** *Why: the predeclared
  hit rate came in at ~19% of 18 survey assignments (~13% over 27 incl. verify) — in-band at the
  top edge, so not the null result that would have cut the verb entirely. But three cuts are each
  carried by a number. (a) RIVAL-METHOD carries ZERO BITS: at the `(subject, quantity)` grain D33
  specifies, 282 of 297 pairs (94.9%) are singletons where it cannot fire, and it fires on 15 of 15
  where it can, with 0 corroboration cases — at subject grain, 41 of 41. It is either impossible or
  certain, never informative. D33's rename DECISION stands; what is cut is rendering it as a flag,
  replaced by the row count itself ("3 methods on this key — run all three and compare"), which
  delivers D33's product with no false authority. (b) The staleness BAND is a constant column on
  day one, because every row at ship is minted this wave; and no row in the 652-proof corpus carries
  any timestamp field, so it cannot even be backfilled. (c) "Ranked" has no rank signal at n≈100
  with all-fresh rows — a ranked list with no ranking is the laundering this epic exists to abolish.
  What survives is the rerun-substring filter, which narrows the busiest real bucket 2–8x
  (`internal/cli/` 31 rows → 8 on "vet", 14 on "test", 4 on "build") and is the measured answer to
  the granularity attack.*

- **D44 — The leads substring filter is CASE-INSENSITIVE, and the null state names the structural
  misses out loud.** *Why: a case-sensitive filter produces a FALSE honest-empty — measured:
  substring "completion" returns 0 rows over a bucket that contains
  `go test -run TestCompletionNounsCoverAllDispatchedBuiltins ./internal/cli/`. Against this epic's
  own bar ("honest empty is an answer"), an empty that lies is worse than no filter at all. The null
  state must say "no recipes for this subject — the ledger indexes repo PATHS; it cannot index bp
  task ids, and it cannot answer judgment questions", which converts two of the three measured
  structural miss classes from silent failures into diagnoses.*

- **D45 — `cmd:<head>` fallback subjects are excluded from the leads index.** *Why: the fallback
  exists so the WRITE verb never reports 100% REJECTED (D32) — that is a write-path concern and
  does not obligate the read path to index them. Measured, they are dumps, not subjects: `cmd:bp`
  is the single largest bucket in this wave's own corpus at 16 rows, and repo-wide `cmd:bp` is 55,
  `cmd:git` 42, `cmd:curl` 27. The first user query against a dumping ground discredits the
  feature.*

- **D46 — The honest scope of leads is intra-epic, and the charter says so rather than claiming
  repo-wide lookup.** *Why: within one wave's fence the mint clusters (51 distinct keys for 119
  facts; 16 subjects shared by 2+ covering 84 of 119) because a single wave is a monoculture.
  Repo-wide over the frozen 652-proof corpus it degenerates: 337 distinct subjects, 268 of them
  singletons. Leads beats grep only in a bucket-size band of roughly 3–20. The claim that survives
  measurement is "leads help THIS EPIC stop re-deriving its own housekeeping facts", not "leads
  help surveyors generally".*

- **D47 — The census OWNS the screen composition. `rerun.mjs`'s gate is NOT swapped, and
  `runRerun` is not on the census path at all.** *Why: this was the wave's genuinely undecided
  design, and two builders guessing differently IS the wave-3 cross-slice break repeating.
  Three findings settle it. (a) The ordering defect the direction alleged does not exist:
  `shell()` is DEFINED at rerun.mjs:335 and CALLED at :360, :450 and :492, all after the gate at
  :420 — a builder sent to fix the ordering would find nothing and might weaken the gate hunting
  for it. (b) There are THREE call sites, not two, so a slice that swaps the gate at :420 and stops
  leaves :360 reachable. (c) `probeHttp` at :360 is a fixed read-only curl, not a bypass. Census
  therefore calls `screenCommand` itself and executes only what passes, which keeps screen.mjs
  importing nothing from rerun.mjs (D29), keeps the files disjoint, and keeps the blast radius off
  the only gate currently running on main.*

- **D48 — `screen.mjs` admits an arbitrary file-overwrite primitive, and this wave closes it.**
  *Why: `screenCommand("sort input.txt -o api/lib/barkpark/application.ex")` returns `ok: true`,
  and the overwrite is real, not theoretical — `sort -o` turned a victim file's contents from
  "original content" into "PWNED" in a live probe. `uniq in out` and `tree -o` are the same shape.
  `sort`, `uniq` and `tree` are registered as bare `plainRule()` with no flag inspection and no
  WRITE_SHAPES backstop. This matters beyond its size: D29's own named danger is
  `cp /tmp/evil.js api/lib/barkpark/application.ex`, which screen.mjs closes BY NAME while leaving
  a byte-identical outcome open through `sort -o`. That is denylist thinking surviving inside the
  module whose entire thesis is that denylists cannot be complete, and it is invisible to the
  shipped suite precisely because DANGER_SET was written from the same head-list that has the gap.
  Honest bound: LATENT, not live — 0 of 240 admitted corpus rows use these shapes. But harvest.mjs
  regenerates the corpus from arbitrary other agents' transcripts, so today's fixture bounds
  nothing about tomorrow's input. The fix is a flag guard plus a WRITE_SHAPES backstop plus
  DANGER_SET entries so the suite can fail on them.*

- **D49 — The cross-slice wiring test asserts SUBSTRING CONTAINMENT of the screen's live output
  inside the ledger's live output, importing both real modules — never a shape assertion.** *Why:
  this is the wave's most decisive proof. A shape assertion would duplicate `screen.test.mjs`,
  which already goes 16–19 tests red on a naive mutation. The gap is the CONSISTENT refactor: a
  complete, self-consistent rename of `reason` → `why` (in `refuse()`, in the admit return, in
  `screenAll`'s own consumer at screen.mjs:806, and throughout `test/screen.test.mjs`) leaves
  `screen.test.mjs` 34/0, `ledger.test.mjs` 60/0 and `level.test.mjs` 71/0 — EVERY shipped suite
  100% green — while the ledger silently falls back to "the injected screen refused it". Wave 3's
  headline defect, reproduced on the merged tip, invisible to the entire shipped suite. Only a
  containment assertion catches it, and only a test importing both modules can express one. Note
  the trap: `test/ledger.test.mjs:826` is already TITLED "the injected-screen contract MEETS
  screen.mjs's real return shape" while line 836 states it uses a STAND-IN rather than importing
  screen.mjs — a builder may find that title and believe the work is done.*

- **D50 — Silence is classified by TOOL FAMILY first and exit code second; there is no flat
  predicate, and `git show`'s rc128 is discriminated by STDERR PATTERN.** *Why: a flat
  `rc==0 && stdout non-empty` misclassifies a byte-identity `git diff` (rc0+empty is the ANSWER)
  and a grep absence (rc1+empty is the ANSWER). The obvious repair — "rc1 means absence" — inverts
  polarity on `diff`, whose rc1 carried 7,357 bytes of real differences in the probe. And rc128
  cannot key decay: path-gone ("does not exist in"), ref-gone ("invalid object name") and wrong-cwd
  ("not a git repository") all exit 128, so a census run in a worktree that has not fetched
  `origin` would report the ENTIRE ledger as decayed — an outage forging a decay wave. REF-GONE
  and WRONG-CWD are environment faults and INADMISSIBLE, never decay. Scope: 246 of 652 corpus
  commands (37.7%) sit in an exit-code-ambiguous family, and 12 non-grep silent-PASS specimens —
  including a clean `go vet`, the canonical green — are discarded as NULL-READ today.*

- **D51 — Two live defects in `rerun.mjs` are fixed independently of whether the census ships.**
  *Why: (a) `diff a b` where b does not exist exits 2, reads nothing, and is ADMITTED as evidence
  that something is absent — a tool error laundered into an absence claim. `readIsNull`
  special-cases grep's exit 2 and nothing else, so grep is protected and every other tool is not.
  This is a false ADMISSION, strictly worse than the discards, because it manufactures a false
  claim rather than dropping a true one. (b) `git merge-base --is-ancestor` is refused
  UNSAFE-RERUN because the write-verb regex lists `merge` and `\b` matches inside `merge-base` —
  so the epic's own D40 merge-proof check and every stranded-branch ancestry check cannot be rerun
  by its own instrument. One-token fix (`merge(?!-base)`), but it sits inside the safety allowlist
  and must be ruled explicitly and paired with a protective test, or a builder "fixing safety" near
  WRITE_SHAPES is exactly the weakening this charter warns against.*

- **D52 — Three statistics are RETIRED, and each is replaced by one that can be re-run.** *Why:
  D21's precedent, applied to this epic's own favourite numbers. (a) "26 of 31 outage probes
  green-lit" is unrecoverable and lives in SHIPPED SOURCE (screen.mjs:21, screen.test.mjs:351), not
  merely in briefs — replaced by the re-runnable pair: 22/22 named outage probes admitted by
  `classifySafety` vs 0/22 by `screenCommand`, and 572/651 vs 240/651 over the frozen corpus. Safe
  to retire: no test asserts the number, the test asserts 14 SHAPE regexes. (b) The mint rule's
  "70 of 104 = 67%" is carried as a fact with NO RERUN — structurally identical to D21's retired
  entropy statistic — replaced by 90 of 119 = 75.6%, re-derivable from this wave's own journal.
  (c) The "7 of 104" silence figure cannot be re-derived as stated, because 0 of 652 corpus proofs
  have an empty `output_excerpt`: agents NARRATE silence rather than record it. Replaced by 38 of
  652 (5.8%) under the strict narration pattern.*

- **D53 — Prediction 1 is REFUTED, and the metric is named rather than the favourable reading
  quoted.** *Why: path-token mint yield over this wave's own 122 facts is 75.6% of rerun-bearing
  facts (73.8% of all) — above wave 3's 67% prior by 7–12 points, but not the predeclared ≥90%.
  The loose reading ("mints a subject at all", counting the `cmd:` fallback) is 97.5% and would
  satisfy the prediction, but D32's own prose shows the fallback was designed as a FLOOR, not as
  coverage. Quoting 97.5% without naming the metric would repeat exactly the 26-of-31 failure this
  wave is retiring. The honest headline is ~76%. Injectivity is confirmed on fresh data: the
  path key gives 51 distinct keys for 119 facts (it CLUSTERS), while the claim-derived control
  gives 119 for 119 — perfectly injective, a dead index. D32's central argument holds.*

- **D54 — The write verb mints its own `run_id` from a sanitized UTC bound, and the
  foreign-row staging hole is stated as a CEILING rather than patched.** *Why: `run_id` appears
  NOWHERE in the workflow JS (zero occurrences of run_id/randomUUID/crypto/Date.now), and
  `ledger.mjs` deliberately owns no minting policy — its BAD-RUN-ID message says run_id "is
  supplied by the caller because this module has no clock and no random source to invent one".
  Critically, a raw `date -u` string CANNOT be the run_id: colons violate the RUN_ID regex, so
  "bake date -u into the write path" does not work literally and must be sanitized. Landing the
  wave-3 branch does NOT close the Decide-staging hole: two simultaneous untracked rows appear as
  identical bare `??` and Decide's shipped instructions stage both. Since the workflow cannot
  supply a shared per-wave prefix, run_id-prefix filtering cannot be made reliable, and the honest
  claim is that explicit-path staging bounds the blast radius without eliminating it.*

- **D55 — `harvest.mjs` is READ and named, not absorbed: the safety enumeration is TWO exec
  primitives, one fact-driven and gated, one fixed and read-only.** *Why: three waves of "606
  lines unread" ended. It holds exactly one exec — `execFileSync("bash", ["-c", LIST_COMMAND])` at
  :78, where LIST_COMMAND is a module-level `find … -print0` constant with zero interpolation — and
  it has ZERO import sites anywhere in `tooling/grip`. It is invoked only by a human running
  `--harvest` by hand. It is also disqualified as a write-verb fact source BY CONSTRUCTION: no row
  in its corpus carries a `rerun` field ("100% of these strings are prose"), which is what killed
  the backfill rival on the merits. Naming it beats absorbing it: the claim "only one execution
  path exists" was false, and a charter that says so stays trustworthy.*

- **D56 — the fleet-as-factory is DEFERRED, not attempted; wave 5's volume comes from
  RE-EXECUTION BACKFILL.** *Why: the join blocker is worse than "the prompt never names
  `ledger.mjs`". At Verify time the shared checkout the D35 carve-out points at was 26 commits
  behind `origin/main` and had NO write verb — `node tooling/grip/ledger.mjs write /tmp/f.json`
  printed the old `[fold | --selftest]` usage and exited 2. A verifier that got past that needed
  NINE independent discovery steps (that a tool exists at all; the verb and its arity; that it must
  MATERIALISE `facts.json` itself, since the harness never writes one; that raw `{claim, evidence,
  rerun}` facts are not rows and `mint` is a required intermediate; that the third positional `dir`
  exists; that `screenCommand` returns `.ok`, not `.safe`). Then all-or-nothing killed the batch
  anyway: 9 refusals over 22 real foreign survey facts — 7 of them `sed -n 'N,Mp'` — discarded ALL
  22 rows, exit 1, nothing written. Two of those three failure modes sit outside this epic's
  surface fence. A wave that bets its headline on that seam mints zero rows.*

- **D57 — directory density does NOT cluster subjects; QUESTION density does. P4 is REFUTED
  BACKWARDS.** *Why: P4 predicted foreign singletons below 65%; deliberate directory-dense aim
  measured 92.3% (39 foreign subjects, 36 singletons) — WORSE than D46's 79.5% under scatter. The
  bucket histogram is `{1:36, 2:1, 3-20:2}`, with only 28.3% of rows in the band D46 identified as
  the only one where leads beats grep. The mechanism is that the mint's subject is the FILE PATH:
  ten questions about ten files in one directory mint ten singletons. The only clusters produced
  were the two files asked about REPEATEDLY (n=11, n=4), and the survey's unengineered facts
  clustered BETTER than the engineered ones — 22 facts to 9 subjects — because surveyors kept
  re-interrogating the same two artifacts. Every future aim instruction reads "many questions per
  FILE", never "many files per directory".*

- **D58 — the census is the MINTING INSTRUMENT: a corpus command becomes a ledger row only by
  ANSWERING on re-execution today.** *Why: the corpus's `proofs[]` carry `run` as a workflow id
  (`wf_009b2433-388`), never a timestamp, so a backfill cannot honestly derive `observed_at`, and
  stamping `now` on a weeks-old command is exactly the freshness claim this epic exists to forbid.
  Re-execution fixes it BY CONSTRUCTION — `observed_at` is true because the command was just run.
  This also settles D55's backfill disqualification precisely rather than reversing it: D55 killed
  the EVIDENCE half (1,902 prose entries, no `rerun` field, "100% of these strings are prose"). The
  PROOFS half is 652 entries carrying `.command`, which IS a rerun. Backfill is re-admitted on the
  proofs half ONLY, gated on answering, and a command that no longer answers is not stored at all.*

- **D59 — `leads` SHIPS, and P5 is RE-WORDED BEFORE it is quoted: an honest-empty rate is
  meaningless without a stated query granularity.** *Why: two independent measurements disagreed
  because P5 never named the variable that decides it. Over 20 router-vocabulary queries on the
  62-row store: 65.0% honest-empty → SHIP (threshold >70%). Over coarse queries on a 279-row store:
  5–40% → SHIP. Over 20 INDEPENDENTLY-derived exact file paths: 75.0% → CUT. The 75% is a
  STORE-COVERAGE reading, not a verb reading — 19 of its 20 query paths exist in the checkout, not
  one has a stored recipe in 279 rows, and applying the cut literally returns the same 166 subjects
  for the agent to eyeball, making an under-covered store HARDER to read, not easier. Where the
  filter does work it is decisive: `mix test` → 35 subjects, `api/lib` → 26, `internal/cli` → 12 —
  exactly D46's 3–20 band. P5 as re-worded and re-committed: measured at SUBSYSTEM granularity, and
  both readings published whenever it is quoted.*

- **D60 — RIVAL-METHOD is a FALSE-POSITIVE GENERATOR today, so fixing the mint is a PRECONDITION of
  the ledger census, not backlog.** *Why: `quantityPhrase` mints the command FLAG, not the
  property. `grep -c "needs_worktree" X` and `grep -c "isolation" X` both mint `grep:-c`, collide
  on one key, and the fold emits "N independent recipes re-derive Q … run all N today and compare
  what they answer NOW" — for commands answering different questions. Reproduced independently
  twice, and once in a stronger form: `git show <path> | wc -l` and `git show <path> | grep -c
  'needs_worktree'` both mint `git:show`, so a line count was flagged as a rival of a match count.
  Over the 652-command corpus, 449 distinct keys hold 652 rows: 58 keys collide, absorbing 261 rows
  (40%), and 41 of those 58 sit on a `cmd:<head>` fallback subject absorbing 222 rows (34%), where
  four unrelated trees were presented as four ways to derive one property. D45 hides `cmd:` from
  leads but NOT from the fold, and `census --ledger` consumes `rival_methods` directly — so
  measuring decay on the store before fixing the mint measures a signal the mint invented.*

- **D61 — the safety enumeration is THREE exec primitives, and the two sharpest holes sit UPSTREAM
  of every head rule.** *Why: D55's "TWO" is corrected on three counts. The primitives are
  `harvest.mjs:78` (`execFileSync`, fixed module constant, zero import sites), `rerun.mjs:360` —
  which is `spawnSync("/bin/sh", ["-c", cmd])`, NOT `execFileSync`, so a tranche grepping
  `execFileSync` MISSES the only primitive that takes caller data — and `ledger.mjs:849`
  (`execFileSync("date", ["-u", …])`, fixed argv, feeding every write's `observed_at`). Two new RCE
  primitives are live-proven below the allowlist: (a) DOUBLE-QUOTED COMMAND SUBSTITUTION EXECUTES —
  `maskQuotedSpans` blanks double-quoted spans identically to single-quoted ones, but `sh` DOES
  expand `$()` inside double quotes, and `censusOne('grep -n "$(id > /tmp/MARK)" .')` returns
  `screened:true, executed:true` with the marker written carrying live `id` output, on the census's
  own supposedly fail-closed path; (b) THE ENVIRONMENT-ASSIGNMENT STRIP IS A GENERAL RCE PRIMITIVE
  — `screenSegment` strips `VAR=value` prefixes and never screens the variable, so
  `GIT_EXTERNAL_DIFF=./evil.sh git diff HEAD~1` is ADMITTED and live-executes the script, with
  `GIT_PAGER=`, `PAGER=` and `NODE_OPTIONS=--require=` the same shape. Both are reachable before any
  head rule runs, which is why no amount of tightening a head rule reaches them.*

- **D62 — the node refusal STANDS (option a), documented as a REACH BOUND, never as a security
  invariant.** *Why: measured yield of the narrow `node --test <in-repo-path>` form over 651 real
  proof commands is ONE. 0.15%. The JS test evidence agents actually type is `npx vitest run`,
  `pnpm --filter @barkpark/react test`, `npm run typecheck` — 13 commands option (b) recovers NONE
  of — and 2 of the repo's 3 real `npm test` scripts carry `--import` or `--test-reporter=spec` and
  fail the narrow form anyway. The narrow form is also DEFEATED below its own grammar by D61(b): 7
  of 29 escapes were admitted and `NODE_OPTIONS=--require=./evil.cjs node --test ok.test.mjs`
  live-executed attacker JavaScript. Option (b) as literally filed on `tgw4-screen-refuses-node`
  (`node <path-under-the-repo>`) is straightforward RCE needing no escape at all. The honesty
  clause is mandatory: the screen ALREADY admits `mix test` and `go test`, which execute arbitrary
  repo code — this repo's own ExUnit files call `System.cmd("python3", ["-c", …])` — so "we refuse
  arbitrary code execution" is not a principle the screen holds, it is a rule applied to node and
  not to Elixir or Go. The refusal is a bound this epic CHOOSES; the cost (grip's own `node --test`
  recipes can never be stored) is paid knowingly and written into the README.*

- **D63 — the screen's two FALSE REFUSALS are fixed in the SAME slice as the tightenings, because a
  screen that only ever tightens gets routed around.** *Why: (a) the host bound runs on the RAW
  string before `maskQuotedSpans`, so a purely local `grep -c "ssh" docs/ops/PROD_OPS.md` is
  refused as "names ssh (remote execution)" — a PATTERN read as a TARGET — and the densest planned
  foreign targets are ops docs whose most quotable lines all contain `ssh`. (b) `sed -n 'N,Mp'`,
  read-only line citation, is refused on the head as a stream editor, and it is the single largest
  refusal class in real foreign output: 7 of 9 refusals over the survey's own facts. The kicker is
  that the harness's own `rerun` schema description gives `git show origin/main:path | sed -n
  40,60p` as its FIRST worked example — the instrument instructs its producers to write exactly
  what it refuses. Shipping the tightenings alone would raise the refusal rate on honest work in
  the same wave that multiplies stored commands.*

- **D64 — all-or-nothing writes STAY, and a PRE-SCREEN verb ships beside them.** *Why:
  all-or-nothing is correct — a file holding only the rows that happened to pass IS the silent-strip
  defect at file granularity — but it is currently UNLEARNABLE. Nine refusals discarded all 22 rows
  with exit 1 and nothing written, and there is no cheap way to find out first, so a verifier learns
  the rule by losing a whole batch. `ledger.mjs prescreen <facts.json>` reports per-row verdicts and
  writes nothing. Pinned in the same breath because a verifier got it exactly backwards in the
  field: `screenCommand` returns `.ok`, NOT `.safe` — reading `.safe` yields `undefined`, scores
  0/40, and the reason string still reads "admitted", so a careful agent pre-screening its batch
  concludes the precise opposite of the truth.*

- **D65 — the level-mention promotion is a CORRECTNESS fix, NOT a volume precondition, and it is a
  RULING because the suite ENFORCES the bug.** *Why: `SSH_READ`/`GIT_SHOW_REMOTE`/`GH_API` are
  tested against the raw unmasked segment at `level.mjs:472`/`:483`, unlike curl/wget which was
  deliberately head-gated with its own regression test, so `grep -rn "ssh root@…"
  docs/ops/PROD_OPS.md` derives L1 and `checkCeiling` — which accepts any claim at or below the
  derived ceiling — then accepts ANY claimed level. The strings are real: PROD_OPS.md carries them
  at :17, :36, :82. But measured exposure is 0 of 652 corpus commands and 1 of 103 wave reruns (and
  that one is a probe OF this bug), and the L1 half is already unreachable through the screened
  write path because the screen refuses `ssh` — only the L2 inflation is storable. Decisively,
  `level.test.mjs` test 131 ("the ssh forms the corpus actually uses are never demoted") ENFORCES
  the current behaviour, so any fix reds the suite BY DESIGN. That is a decision to reverse with a
  no-false-demotion bar, not a patch to slip into a volume wave — a first attempt at the fix
  false-demoted a genuine origin read through `diff <(git show origin/main:…)`, and only the
  corpus-distribution test caught it.*

- **D66 — `foldLedger`'s read path admits every defect the write path refuses, and hardening is
  round 2 because the only actor who could exploit it is the fleet D56 defers.** *Why: 6/6
  run-proven — a row carrying `value`, a screen-refused `rm -rf` rerun, a year-2099 `observed_at`
  and a false L1 all fold clean with `unreadable: []` and exit 0. `usableRow` checks exactly three
  things (subject, quantity, rerun non-empty); it consults no screen, no clock and no derivation,
  while `admitRecipe` does all four. One nuance cuts the epic's way and is WHY leads may ship over
  an unhardened store: `foldLedger`'s projection rebuilds each recipe from six NAMED fields, so
  `value` and every other unknown key is DROPPED before reaching `entries[]` — `leads`, as a filter
  over `entries[]`, structurally CANNOT hand back a value even from a forged file. The wish's
  central guarantee holds at the read layer; it is the STORE that is unguarded, silently. Hardening
  routes rejections into the existing `unreadable[]`, which already drives the fold CLI's exit
  code — a CI-usable tripwire for free.*

- **D67 — `census.mjs` is INVISIBLE TO GREP, and that is this epic's own disease inside its own
  instrument.** *Why: a literal NUL byte at `census.mjs:148` (offset 8398), written into a mask
  expression as a raw `0x00` instead of the `\0` escape, makes `file(1)` classify the file as
  binary. The Claude Code `grep` wrapper (ugrep with `-I`) therefore returns ZERO LINES AND EXIT 1
  while `/usr/bin/grep -anc screenCommand census.mjs` returns 7 — an agent grepping for census
  internals gets a clean empty result indistinguishable from genuine absence. This is the most
  likely explanation for "census-adjacent corners no surveyor reached"; one verifier nearly filed
  two false absences from it and caught itself, concluding at first that census does NOT call
  `screenCommand`, the exact opposite of the truth. One-character fix, zero behaviour change.
  **METHOD RULING: any negative anywhere in this epic that rests on the grep wrapper over
  `census.mjs` is VOID and must be re-derived with `/usr/bin/grep -a`.***

- **D68 — the census is NOT hermetic, and the fix is a broadened `ENV_FAULT` plus a NAMED reach,
  not `--offline`.** *Why: 38 of 240 admitted rows reach live services (bp=21, gh=15, curl=2), and
  the real outage stderr of those binaries — "connect: connection refused", "no such host", "error
  connecting to <host>" — matches NONE of the three `ENV_FAULT` regexes, so `bp`/`gh` fall through
  `QUERY-LISTER` to `RAN-AND-FAILED`, which is in the DECAYED set. One hiccup flips up to 36 rows
  to false DECAYED against a published 14.6% — a single-cause spike, not 36 independent decay
  events. `--offline` costs reach unconditionally (240→202 executed, 36.9%→31.0%) to dodge a
  failure mode the regex fixes surgically, so it ships opt-in at most. One residual is NAMED rather
  than glossed: `curl -s` — 27 of the corpus's 34 curl commands — SUPPRESSES its own
  connection-refused text, leaving empty stderr with exit 7, so no stderr regex can reach it; curl
  exit codes 6 and 7 are therefore treated as environment faults directly, by code, not by text.*

- **D69 — P2 FALSIFIES, and BOTH readings are published rather than the flattering one.** *Why:
  predicted 68–85% strict path-token yield. Real fleet output measured 62.5% (65 of 104 survey
  facts) — below the floor. The frozen corpus measures 48.8% (318/652), reproduced independently
  three times to the digit. Deliberately-AIMED facts measure 85–100%, above the ceiling. Yield is a
  function of AIM, not of the miner, and the honest forecast for unprompted fleet output is the
  62.5% figure. Two mint defects surfaced while measuring, neither previously filed: `pathToken`
  rejects Go's `./internal/cli/...` because the `..` traversal guard fires on the ellipsis
  (go-family yield 24.2%, the worst of any family, and `internal/cli` is a named dense target); and
  it returns null for EVERY single-segment top-level directory — `api/`, `js/`, `web/`, `docs/`,
  `deploy/`, `scaffy/` — so the repo's own subsystem names, precisely the coarse terms an agent
  types, can never become leads subjects.*

- **D70 — P3 is RE-WORDED BEFORE it is measured, because the naive reading overstates outward reach
  2.6x.** *Why: over the wave's 104 survey facts, the naive all-non-grip share is 61.5% (64/104),
  but the corrected leads-VISIBLE non-grip share — excluding `cmd:<head>` per D45 — is 24.0%
  (25/104). `cmd:bp` alone is the single largest bucket at 20 rows, D45's dumping ground appearing
  live in this wave's own output. Quoting the naive figure would have claimed 2.6x the outward
  reach the store actually has. P3 counts leads-visible subjects only, permanently.*

- **D71 — the zombie roster closes by CONTENT, and `lifecycle_status: done` is CONFIRMED sufficient
  to leave the ready pool.** *Why: measured rather than assumed. The ten tasks named in
  `tgw3-bl-close-ten-merged-slices` all carry `lifecycle_status: done` with `claim.closed_at` from
  `tgw4-decide`, and NONE of the ten appears in a fresh 968-document `bp task ready --all` — so
  `done` does remove a task from the pool, and that backlog task's own description ("all ten
  currently surface in ready --all") is itself now a stale truth inside the epic that hunts them.
  `tgw1-adjudicator` and `tgw1-acceptance-suite` are self-documenting zombies whose own briefs open
  "SUPERSEDED … must NOT be built from" — closed by content. `tgw1-workflow-gate-wiring` is NOT
  pure bookkeeping and is NOT closed: it has 17 children of which 10 are still open, including
  `tgw2-acceptance-suite` at 0/7, so closing it would orphan real work behind a closed parent.*

- **D72 — wave 4's Paper UNDERCOUNTS its own filed debt by seven tasks.** *Why: seven `tgw4-*` /
  `tgw-*` tasks are real, published, direct children of `truth-grip-epic`, inserted between
  03:02:36Z and 03:52:26Z — after the wave-4 charter landed (03:30Z) and before the wave-4 review
  commit (04:44Z) — and NONE of the seven appears anywhere in the 346KB wave-4 Paper. The Paper is
  not lying: its blocks were frozen before its own Decide-phase filing sweep ran. The effect on a
  reader is identical to lying, which is the point. From now on the wave-log entry is written AFTER
  the filing sweep, and the Paper's wave plan names every task id it filed.*

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

### Wave 3 — the CLI is the seam. Parent task `truth-grip-epic`. Paper `source-of-truth-grip-wave-3-2026-07-21`.

**The realisation that reframes the epic.** D19 permanently forbids the workflow JS from reading a
file, importing a module, running a command or reading a clock. Wave 2 correctly wired the only
thing the orchestrator CAN do — a grammar-free demote. But the orchestrator was never the right
consumer. Every phase of this loop dispatches an AGENT WITH A SHELL, and that premise was re-run at
Digest rather than assumed: D19's vm-sandbox scopes to the `.workflow.js` file, not to dispatched
agents; Verify's default dispatch carries no isolation key and runs in the shared checkout exactly
as Decide does; a probe write under `tooling/grip/ledger/` succeeded. Wave 1 shipped a substrate
nothing called; wave 2 made the one caller D19 permanently cripples call it; wave 3 hands it to the
caller that can actually do the work.

**Conceded openly:** everything the builders produce goes live NEXT wave, not this one. The
phase-agent choreography rehearsed inside this wave is a REHEARSAL and the debrief must label it as
one.

| # | Slice | Round | Size | Surface |
|---|---|---|---|---|
| 1 | `tgw3-census-screen` — the fail-closed allowlist screen, its own module, three layers (D29) | 1 | large | tooling/grip |
| 2 | `tgw3-level-compound-fix` — un-gate the remote checks, strip wrappers, bp/gh → L2, parseability floor (D30) | 1 | large | tooling/grip |
| 3 | `tgw3-ledger-honesty` — the injected `now` bound, Z-only, injected safety screen, `RIVAL-METHOD` (D31/D33/D39) | 1 | medium | tooling/grip |
| 4 | `tgw3-prompt-seam` — the Verify carve-out + Decide's ledger commit + the stranded-file ruling (D35) | 1 | medium | .claude/workflows |
| 5 | `tgw3-write-verb` — the WRITE CLI + the subject/quantity minting transformer (D32) | 2 | large | tooling/grip |
| 6 | `tgw3-census-verb` — the decay census, silence-as-answer, its honest 29.8% reach (D38) | 2 | large | tooling/grip |
| 7 | `tgw3-leads-verb` — the read path, one command, one screen, staleness called out, no answer ever shown | 3 | medium | tooling/grip |

Rounds 2 and 3 do NOT dispatch this run. `tgw3-write-verb` waits on 1 and 3 (it wires the screen
into the write seam and routes the renamed fold); `tgw3-census-verb` waits on 1; `tgw3-leads-verb`
waits on 5, because both edit `ledger.mjs`'s CLI routing.

Later waves, in the ratified order: **wave 4+** the server-side
`type:fact` backend, whose grammar must live in an Elixir `before_publish` hook because schema-v2's
cross-field `validations:` slot is parsed but inert.

### Wave 4 — the ledger stops being empty. Parent task `truth-grip-epic`. Paper `source-of-truth-grip-wave-4-2026-07-21`.

Round 0 landed before any builder flew: the four wave-3 branches plus the D29–D40 charter commit,
one PR, merged by CONTENT (D40/D41/D42).

| # | Slice | Round | Size | Surface |
|---|---|---|---|---|
| 1 | `tgw3-write-verb` — the WRITE CLI + the minting transformer + the first real rows (D32/D53/D54) | 1 | large | tooling/grip |
| 2 | `tgw3-census-verb` — the decay census, family-dispatch silence, census owns the screen (D47/D50) | 1 | large | tooling/grip |
| 3 | `tgw4-screen-overwrite-guard` — close `sort -o`/`uniq`/`tree -o`, retire the 26-of-31 prose (D48/D52) | 1 | medium | tooling/grip |
| 4 | `tgw4-wiring-and-acceptance` — the containment wiring test + the acceptance suite (D49) | 1 | large | tooling/grip |
| 5 | `tgw4-rerun-silence-fixes` — the `diff` rc2 false-admission + the merge-base false-unsafe (D51) | 1 | medium | tooling/grip |
| 6 | `tgw3-leads-verb` — the REDUCED read path: substring filter, no band, no rank, no flag (D43–D46) | 2 | medium | tooling/grip |

The three verb slices keep their wave-3 task ids rather than being re-filed under `tgw4-*`: they
were correctly filed and correctly dependency-blocked on branches that were not on main, and round
0 is exactly what lifts that block. Minting duplicate ids for work that already has a good task is
the zombie-task disease this wave is treating.

Round 2 does NOT dispatch this run. `tgw3-leads-verb` waits on 1 (it needs rows to read) and on 2
(its staleness column renders the census's verdict, and both edit `ledger.mjs`'s CLI routing).

### Wave 5 — the ledger becomes readable. Parent task `truth-grip-epic`. Paper `source-of-truth-grip-wave-5-2026-07-21`.

The direction that opened this wave was "the fleet is the factory, aimed outward". Verification
refuted its mechanism (D57) and its seam (D56), and replaced both. The store still leaves home —
53 of the 62 committed rows are foreign — but it leaves home in a Decide commit of rows a verifier
minted by hand, and the volume that makes `leads` worth typing comes from RE-EXECUTION BACKFILL
(D58), not from dispatched verifiers.

**Committed with this charter:** the two carve-out run files a wave-5 verifier wrote through the
real CLI under D35, staged by explicit path. The store goes 9 rows → 62, 7 subjects → 48, 100%
self-portrait → 85% foreign, with zero `value` fields, zero L1 rows and zero unreadable rows.
That is D35's Decide step executed for the first time, one wave after it shipped.

| # | Slice | Round | Size | Surface |
|---|---|---|---|---|
| 1 | `tgw5-screen-hardening` — two upstream RCE primitives, four write-flag holes, two false refusals | 1 | large | tooling/grip |
| 2 | `tgw5-leads-verb` — `grip leads` + `grip prescreen`, reduced per D43–D46 | 1 | medium | tooling/grip |
| 3 | `tgw5-mint-fixes` — the go-glob, the single-segment hole, and the quantity that fabricates rivals | 1 | medium | tooling/grip |
| 4 | `tgw5-census-ledger` — `census --ledger`, the NUL byte, the hermeticity caveat | 1 | medium | tooling/grip |
| 5 | `tgw5-probehttp-argv` — close the fact-derived-URL injection with argv, not a better gate | 1 | small | tooling/grip |
| 6 | `tgw5-write-path-docs` — the nine discovery steps, answered where a writer looks | 1 | small | tooling/grip |
| 7 | `tgw5-corpus-backfill` — the census mints; only commands that answer TODAY become rows | 2 | medium | tooling/grip |
| 8 | `tgw5-fold-hardening` — the read path stops admitting what the write path refuses | 2 | medium | tooling/grip |

Round 2 does NOT dispatch this run. `tgw5-corpus-backfill` waits on 1, 3 and 4: it re-executes
historical commands, so it must not dispatch beside an unhardened screen (D61); it writes rows, so
minting them with the colliding quantity would bake fabricated rivals into the store permanently
(D60); and it mints THROUGH the census classifier (D58). `tgw5-fold-hardening` waits on 2 — both
edit `ledger.mjs`, and leads owns the CLI dispatch chain this wave.

**The one thing this wave is for.** After round 1, an agent types
`node tooling/grip/ledger.mjs leads <substring>` and gets back RECIPES — command, derived level,
dependency paths — for questions somebody already answered cheaply. Never a value, and not by
promise: `RECIPE_FIELDS` has no `value` field, and `foldLedger`'s projection drops unknown keys
before they reach `entries[]` (D66), so the verb CANNOT hand back a stale truth even from a forged
file. After round 2 it reads a store roughly four times larger, every row of which re-derived an
answer on the day it was written.

**What this wave will NOT have proven, stated in advance.** The dispatched-verifier write path
remains unexercised end to end (D56) — the prompt and harness edits that would close it are outside
this epic's surface fence and are filed as `tgw5-bl-join-prompt-closure` for the lead. The level
mention-promotion still derives a false L1 from a grep of an ops doc (D65). And P5's SHIP verdict
rests on a 5-point margin at 62 rows, with 5 of 7 non-empty queries returning a SINGLE row — a
one-row lead is not measurably better than a grep, so P5 is re-measured after round 2 at the larger
row count before it is called settled.

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

### Wave 2026-07-21 (2) — round 1, the substrate gets a caller. Grade A.

Paper: `source-of-truth-grip-wave-4-2026-07-21`. Five round-1 slices built and
reviewed; `tgw3-leads-verb` deferred by design (sequenced-rounds law), not
stalled. All five carry `builder_model: opus` — three of them only after this
review patched the field on, see the ledger note below.

**THE LEDGER IS NO LONGER EMPTY.** Three waves said "the loop reads as closed
one wave before it is". It is closed now. `node tooling/grip/ledger.mjs write
<facts.json>` is shell-reachable, and on the merged tree
`git ls-tree HEAD --name-only tooling/grip/ledger/` returns a real run file
beside `README.md`. Nine rows fold to seven keys and RIVAL-METHOD fires once —
the clustering D32 predicted, delivered on the first write. Re-derived in review,
not taken on report.

**Landed** (final branches carry a reviewer `-r` commit where one was needed):

| Slice | Branch | What |
|---|---|---|
| `tgw3-write-verb` | `…ship-the-write-verb-and-the-minting-tran-0-r` | `mint.mjs` + the `write` verb: a fact→recipe TRANSFORMER, subject from the rerun's path token, `now` and `observed_at` from ONE `date -u` reading, all-or-nothing writes. 25 new tests. |
| `tgw3-census-verb` | `…ship-the-decay-census-so-the-epic-measur-1-r` | `census.mjs`: family-first silence classification over the frozen corpus. 85.4% of 178 decisive recipes still answer, 14.6% decayed, reach 240/651 printed as the honest bound. 40 tests. |
| `tgw4-screen-overwrite-guard` | `…close-the-arbitrary-file-overwrite-primi-2-r` | The `sort -o` / `uniq <in> <out>` / `tree -o` / `npm pack` / `curl -so<path>` overwrite primitive closed, DANGER_SET 23→29, NEVER_CRY_WOLF 4→10, census reach unchanged at 240. 39 tests. |
| `tgw4-wiring-and-acceptance` | `…prove-the-screen-to-ledger-contract-with-3-r` | `test/wiring.test.mjs` (substring containment through both real modules) + `acceptance.mjs` (the six ratified specimens through the real adjudicator). 15 + 3 tests. |
| `tgw4-rerun-silence-fixes` | `…stop-rerun-mjs-laundering-a-tool-error-i-4` | Family-dispatched silence in `rerun.mjs`, the `merge(?!-base)` carve-out, and a THIRD defect the builder found itself: git's global options let `git -C <path> push` classify SAFE. 55 tests. |

**D49's proof reproduced by the reviewer, exactly as claimed.** The consistent
rename `reason`→`why` across `screen.mjs` and its own suite leaves screen 34/0,
ledger 60/0 and level 71/0 — every shipped suite 100% green — while
`wiring.test.mjs` goes 3/3 red. That is the wave's most decisive artifact and it
behaves as advertised.

**The defect only the merge could see.** Each slice was green alone; the union of
all five went RED. `screen.test.mjs` froze `classifySafety`'s corpus admission at
`572`, a number belonging to `rerun.mjs` — a module that suite does not own — and
`tgw4-rerun-silence-fixes` legitimately moved it to 583 (the `merge-base`
carve-out re-admits 11 rows). Two correct fixes jointly producing a red, the
co-scoped-merge class again. The sharper half is the irony: that test's own
comment reads "ratios are asserted, not counts" with three frozen counts below
it — the retired-statistic disease committed inside the cure. Fixed on the
screen slice: the screen's own 240 stays pinned (it is what that suite owns), and
`classifySafety`'s figure is asserted as a MARGIN and printed, never frozen.
**A wave whose slices are individually green has not been reviewed until they
have been merged into one tree and gated together.**

**Other defects the review found and fixed.** The pattern held for a fourth wave
— the epic's own failure modes keep appearing inside the tooling built to
prevent them:

1. **A bound that silently unbound itself.** `census.mjs --limit` with a missing
   or non-numeric value parsed to `NaN`, failed the `isFinite` test and ran the
   ENTIRE 651-command corpus. The operator asked for a bounded run and got an
   unbounded one with no signal. Named rejection, exit 2.
2. **An underpowered pass wearing a full census's authority.** `--limit 12`
   admits 3 decisive rows, measures 0.0% decay and printed "CONSISTENT — below
   the 22.4% floor". Zero-admissible already had a NULL STATE; too-few-to-say did
   not. A 30-row floor now returns UNDERPOWERED and reports the measurement as an
   observation, never as consistent or contrary. Control pair tested both ways.
3. **The acceptance suite's escape hatch cost nothing.** "Each entry must be paid
   off by a filed task" was a COMMENT, and nothing read it — an entry with an
   empty `filed_as`, or one whose label did not actually diverge, silenced a real
   finding just as well as an honest declaration. The shape is now checked at
   module scope and FATAL on import, like PROBE-DRIFT. It still cannot prove the
   task exists (that needs the network, and the module is hermetic); it proves
   the declaration was written as a payoff rather than as a shrug.
4. **The write verb died as an unhandled rejection.** `main` became async when
   `write` landed and nothing caught it. A store whose CLI dies quietly is
   indistinguishable from one that wrote nothing on purpose. Named crash, exit 2.
5. **A test that made the suite flaky one run in three** — introduced by fix 3,
   caught by running the union gate eight times rather than once. The mutated
   module copy was written INTO `tooling/grip`, where another test in the same
   process enumerates every file in that directory. Moved out of the tree with
   its sibling imports rewritten to absolute URLs. Eight clean runs.

**Ledger audit.** All five slices left `lifecycle: in_progress` with the
merge-gated criterion honestly open — builders did not close what the lead
closes. Two fixes were needed. (a) `builder_model` was ABSENT from all three
`tgw4-*` tasks, against the wave's own hard model constraint; Decide filed the
tgw4 slices on a thinner schema than the tgw3 ones (no `gate`, `round`, `size`,
`surface` either). The Paper's wave plan states "Every slice runs on opus", so
the intent was recorded at L5 while the spine the gates read carried nothing.
Patched and re-published. (b) `tgw3-census-verb` criterion 5 (a clean `go vet`
classifies as an ANSWER) was PROVEN and left unstamped — the task's own now-line
said "12/13". Re-derived in review and stamped with evidence. No task outside
this wave was touched.

**What this wave did NOT prove.** The census is not hermetic: `bp` and `gh` are
allowlisted read heads, so a run reaches live services and an outage would
inflate the decay rate as RAN-AND-FAILED. 14.6% describes this box on this day
more tightly than the render says. The mint's ~76% path-token yield is still
INHERITED from the charter, not re-derived — the write verb has not yet been fed
a real survey report, only nine hand-authored facts. And `absenceEligible` is
enforced at exactly one seam: `adjudicate.mjs` maps on the verdict alone, so the
veto survives on `ruling.rerun` but is never promoted.

**What the next wave inherits.** Merge round 1 (five branches, verified merging
clean together into one tree: 382 tests, 381 pass, 0 fail, 1 skipped by design;
both selftests green; `acceptance.mjs` exit 0). Then `tgw3-leads-verb`, and only
once BOTH `tgw3-write-verb` and `tgw3-census-verb` are on `origin/main` — it
needs rows to read, it renders the census's verdict, and it edits the same
`ledger.mjs` CLI routing the write verb just claimed. It ships REDUCED per D43:
the substring filter is the feature; the band, the rank and the RIVAL-METHOD flag
are all cut.

The sharpest work after that is DOGFOODING what now exists rather than adding to
it: run a real survey report through `ledger.mjs write` and re-derive the mint
yield from something nobody hand-authored. Backlog filed this review:
`tgw4-absence-veto-stops-at-the-rerun-seam` and
`tgw4-census-run-is-not-hermetic`.
