# Epic charter — CI gate integrity, wave 2: the layer BENEATH the guards

Epic task: `ci-gate-script-integrity-audit`
Wave Paper: `ci-gate-wiring-spec-generator-wave-2026-08-19`
Wave referent: `ci-gate-script-integrity-audit-wave-2-log`
Audited against origin/main `bf499f54b63135b8ae078305b83f2b5b2c078877`.
(The strategy phase pinned `122fd0df81`; the tree moved during the wave and every number below was re-derived at `bf499f54b6`.)

## Vision

Wave 1 of this epic hardened guard SCRIPTS — ten unknown-arg refusals, a studio-link-lint selftest, docs-anchors, doc-budgets. Its own ranking put two things FIRST by blast radius and then covered neither: `.github/workflows/doc-gates.yml` (the WIRING that decides whether a guard runs at all) and `scripts/required-checks-generate.sh` (the GENERATOR that decides what may block a merge). A guard can be perfectly written and still vacuous as a gate if the wiring never invokes it on the PR that breaks it — and a generator that silently emits a wrong spec is worse, because every downstream verifier then agrees, correctly, against the wrong answer.

Wave 2 audits that layer. Two of the wish's premises and two of the strategy's did not survive first contact, and each refutation improved the wave rather than shrinking it:

- **doc-gates cannot block a merge at all.** Main's required set is exactly four contexts — Cloud gate, Console gate, Elixir gate, PR references an active task. `Doc budgets + anchors` is filed S4 PATHS-FILTERED among 25 exclusion rows, and 21 of its steps are named "(blocking)". Every wiring gap inside doc-gates is therefore a POST-MERGE DETECTION gap, not a merge hole. That re-pricing holds and it re-ranks the whole wave.
- **The spec generator is NOT unharnessed.** `scripts/required-checks.test.sh` is 3,437 lines / 31 sections / ~28 generator drives / 7 disarm mutations, wired twice in `required-checks-drift.yml`. Bolting a second `--selftest` onto `generate.sh` beside it would manufacture the mirrored-truth defect this repo has already paid for four times. The work is to find what the existing suite does NOT mutate and extend THAT file.
- **`required-checks-verify.sh` already carries an 18-probe mutation `--selftest`.** The crown appends probes, it does not build a harness.
- **The advisory-posture census numbers were all wrong** — wish 24, strategy 18, truth 15 YAML keys in 11 workflows; console-harness scored third-highest on a substring scan while all five of its hits BAN the construct. Zero of the 15 are silently-demoted blocking guards. The defect is in the CLASSIFIER, not the postures.

The crown is a class this repo's own doctrine names and nothing enforces. `required-checks-verify.sh`'s advisory-prose clause reds when a workflow calls a REQUIRED context advisory. The INVERSE — a workflow asserting blocking authority the spec DENIES — is enforced by nothing: the file contains ZERO references to `.exclusions` across all 872 lines. `docs/ops/merge-gates.md` already carries a bullet headed "A NAME THAT SAYS (blocking) AND HAS NO MERGE AUTHORITY AT ALL". The disease is named; the mechanism does not exist.

Fence: `.github/workflows/**` + `scripts/**` + fixture dirs ONLY. Findings in gate-critical scripts outside it (`api/scripts/sobelow-*.sh`, `js/scripts/check-no-node-imports.sh`, `deploy/cp-deploy_test.sh`, `tooling/task-obsession/reland_check.py`) are FILED with the planted violation, never fixed here. `.github/required-checks.json` is a SPEC file and the branch-protection PUT is a human gate (`cch-w37-bl-register-spec-gate-human-gate`) — this wave does not take it, even though the active token would let it.

## Decisions

**D1 — The inverse blocking-authority clause derives its subject set as the COMPLEMENT (`.checks` + transitive `needs:`-closure), never as an `.exclusions` join.** *Why:* measured at structural evidence the join reds 3 and the complement reds 4 — the extra is `connectors.yml`'s `shim-confinement`, whose job-adjacent comment asserts "BLOCKING — no continue-on-error" and which has NO ledger row, so a join can never reach it; and all 13 S3 rows sit inside the needs-closure (13/13), so the complement excludes transitively-blocking names by construction with no hand list to rot.

**D2 — The clause uses STRUCTURAL evidence only — job `name:` token, own step names, the contiguous comment block immediately above the job key — never a substring search for the context name.** *Why:* mirroring the existing forward clause's name-anchored 200-char window MISSES all three known specimens (doc-gates' claim sits 316 lines above its own job name) and collides on generic job keys, reddening `changes`, `build` and `control-plane` on ordinary prose.

**D3 — File-header prose is reported UNRESOLVED against a committed baseline, never red.** *Why:* of its 11 hits at least five fire on prose that DENIES blocking authority ("but NEVER blocks the merge", "can never be a merge gate") — reddening a correction is the fastest way to get a guard disabled.

**D4 — The clause and the doc-gates honest step-renaming CO-MERGE in one PR.** *Why:* proven by mutation, not by reading — planting one disclaimer into the real `.github/workflows/` took `required-checks.test.sh --hermetic` from `177 passed, 0 failed` to `173 passed, 4 failed`; the hermetic suite scans the REAL tree, and 23 live `name:` values carry `(blocking)`.

**D5 — `go-format.yml` and `security.yml` get an ANNOTATION (`# spec-authority: advisory-ok — <reason>`), not a rename.** *Why:* their `(blocking)` token is inside the JOB name, which IS the rendered context name and IS a committed exclusion row — renaming would silently invalidate the ledger.

**D6 — "Disarm the clause, watch its own `--selftest` red" is VACUOUS and is forbidden as a proof method.** *Why:* `required-checks-verify.sh:709` `probe()` re-execs the COMMITTED path, never `$0`; a copy with `PROSE_DISCLAIMERS` set to `ZZZNEVERMATCHZZZ` still printed `SELFTEST OK`. The working template is the §6(d) idiom — mutant copy inside `scripts/`, invoked DIRECTLY with `--spec/--readback/--runs/--sha/--workflows`, armed rc=1 / disarmed rc=0 on the identical fixture.

**D7 — The generator's parser is widened at the JOB level only; step-level `continue-on-error` REFUSES LOUDLY instead of silently classifying.** *Why:* the naive fix ("any indentation, any non-false value") would mark `js-tests.yml`'s `test` job advisory — it mixes 3 advisory steps with genuinely blocking ones — and EXCLUDING a real gate loses protection rather than adding it.

**D8 — The `^on:` byte anchor is fixed at ALL THREE sites in one PR.** *Why:* it also lives in `scripts/absent-context-census.test.sh` (443, 465) and `scripts/check-deployyml-filters.sh` (128); a one-file fix would leave two parsers disagreeing about the same workflow — the mirrored-truth defect again.

**D9 — All new suite clauses land in `scripts/required-checks.test.sh` in ONE round-2 slice, decoupled from the fixes they guard.** *Why:* a guard co-merged with its fix cannot red on the fail-before state (Standing Law 0), and one owner for that 3,437-line file removes the wave's worst collision.

**D10 — `cchi-w57-blocking-shaped-name-census-guard` stays FILED, not claimed.** *Why:* `.github/required-checks.json` itself routes the count to that task; Standing Law 0 sends free-standing gates to `cch-instruments-epic`; and this wave's own fixes move the census, so a guard merged beside them is born green. It inherits this wave's defended definition instead — 51 under a subtraction ledger of eight buckets, against 59 under the published w56 recipe, against 3 under a literal reading.

**D11 — The registration trigger is EXECUTED up to, and stops at, the human gate.** *Why:* both halves fire today — `Required-check spec gate` is `completed/success` on main HEAD, and a fresh `--require-new-context` sweep reports `evaluated 21, skipped 39, casualties: 0` with all eight non-green heads already CONFLICTING. The active token carries repo admin and the PUT would succeed; `cch-w37` makes it an explicit owner sign-off and `cch-w36` was cancelled precisely for inviting a builder to mutate live protection.

**D12 — The honesty chain is PUBLISHED, not footnoted.** *Why:* the crown lands in a file whose CI homes are `Required-check spec gate` (S7 EXCLUDED) and `Required-check spec drift (advisory)` (S2, continue-on-error), so its red does not yet stop a merge. A tripwire that names its own authority ceiling is strictly better than one that lets a reader assume it has teeth.

## Roadmap

Round 1 (dependency-free, builds this wave):

| Slice | Task | Surface | Size | Model |
|---|---|---|---|---|
| Inverse blocking-authority clause + honest doc-gates step names (CROWN) | `cgsiw-s1-inverse-blocking-clause` | `scripts/required-checks-verify.sh`, `doc-gates.yml`, `go-format.yml`, `security.yml`, `connectors.yml` | large | fable |
| Generator parser: quoted `"on":`, non-literal continue-on-error, `.yaml` glob, both-lists refusal | `cgsiw-s2-generator-parser-forms` | `scripts/required-checks-generate.sh`, `absent-context-census.test.sh`, `check-deployyml-filters.sh` | large | fable |
| Wire two orphan selftests + a push↔pull_request paths-parity tripwire | `cgsiw-s3-wire-orphans-and-paths-parity` | `.github/workflows/shell-harnesses.yml`, `scripts/doc-gates-paths-parity-check.sh` (new) | medium | opus |

Round 2 (dispatched by the lead after its dependencies MERGE):

| Slice | Task | After | Surface | Size | Model |
|---|---|---|---|---|---|
| Mutation clauses for every fix this wave ships | `cgsiw-s4-suite-mutation-clauses` | s1, s2 | `scripts/required-checks.test.sh` | large | fable |
| The three proven doc-gates paths-filter gaps | `cgsiw-s5-doc-gates-paths-gaps` | s1 | `.github/workflows/doc-gates.yml` | medium | opus |

Filed, not built this wave: the doc-gates requirable-aggregator packet (human-gated), the branch-protection PUT (`cch-w37`, human gate), the blocking-shaped census guard (`cchi-w57`), the `Dispatch (compose-smoke paths)` exclusion row (spec file, out of fence), and the out-of-fence guard findings — `deploy/cp-deploy_test.sh` (green on a live re-pin to `localhost:4100`), `tooling/task-obsession/reland_check.py` (62 assertions bind none of its fetch-verdict branch), `api/scripts/sobelow-fresh-finding-guard.sh` (`--selftest` never invoked), `js/scripts/check-no-node-imports.sh` (five surviving plants).

## Wave log

(empty — the lead appends one line per wave on merge)

### Wave 2026-08-19 — gate wiring + spec generator (`ci-gate-script-integrity-audit`)

Round 1 built three slices; all three green on the reviewer's re-run and pushed with PRs open. Grade **A-**.

| Slice | Task | Final branch | Verdict |
|---|---|---|---|
| Inverse blocking-authority clause + honest doc-gates step names (crown) | `cgsiw-s1-inverse-blocking-clause` | `loop-epic/inverse-blocking-authority-clause-honest-0-r` | `blocking_authority_check()` ships with a complement-derived subject set (93 of 112 jobs denied), three structural evidence classes, a reason-bearing escape hatch checked in both directions, and probes 19–23. Fail-before arm re-run by the reviewer against origin/main's four workflows reds exactly the predicted 4. |
| Four legal YAML spellings make the spec generator emit a wrong spec at exit 0 | `cgsiw-s2-generator-parser-forms` | `loop-epic/four-legal-yaml-spellings-make-the-spec--1-r` | Quoted `"on":` trigger key, continue-on-error by VALUE, the both-lists refusal's missing mirror (`--expect-demoted`), and the `*.yaml` glob — fixed at all four byte-anchor sites plus the two sibling scripts. `.github/required-checks.json` untouched. |
| Wire two orphan selftests + the push↔pull_request paths-parity tripwire | `cgsiw-s3-wire-orphans-and-paths-parity` | `loop-epic/wire-two-orphan-selftests-and-build-the--2-r` | `cloud-static-gz-guard.sh` and `pds-live-hetzner-placement-group.sh --selftest-offline` were written, green, mutation-proven and invoked by NO workflow; both are now wired selftest-first. New 419-line `doc-gates-paths-parity-check.sh` fails closed on `[] == []` and carries a self-retiring pin for the live 70-vs-69 drift. |

Reviewer fixes, one commit per slice: both prose clauses in `required-checks-verify.sh` now scan `*.yaml` as well as `*.yml` (s1); a quoted or absent `continue-on-error` is read as the FALSE it is, so a blocking job is never dropped from the required set and a quoted-`false` step cannot manufacture a laundering red (s2); the parity lane installs PyYAML using this workflow file's own idiom instead of hard-failing on an image fact (s3).

Cross-slice integration proof the reviewer ran and no builder could: s1's clause over a merged s1+s3 workflow tree reads 96 of 115 jobs denied with zero violations, and s2's generator builds its index over that same tree without tripping the catch-all or laundering refusals.

THE HEADLINE, restated because it re-ranks everything in this fence: **doc-gates cannot block a merge at all.** Main's required set is exactly `Cloud gate`, `Console gate`, `Elixir gate`, `PR references an active task`. Every wiring gap inside doc-gates is post-merge DETECTION, never a merge hole — and the crown slice exists because 21 of its step names said `(blocking)` anyway.

Stalled: nothing. Deferred BY DESIGN to round 2, dispatched as their dependencies merge — `cgsiw-s4-suite-mutation-clauses` (after s1 AND s2) mechanizes every disarm this wave proved by hand; `cgsiw-s5-doc-gates-paths-gaps` (after s1) closes the three proven paths-filter gaps and must delete the pin line in `scripts/doc-gates-paths-parity-check.sh` in the same PR or s3's guard reds STALE PIN.

Next wave: merge round 1 in the order s1 → s2 → s3 (disjoint files, so any order works, but s5's brief is written against a merged s1), dispatch s4 and s5, then take the axis this wave deliberately did not: the `continue-on-error` postures themselves, and the gate-critical scripts outside this fence (`api/scripts/sobelow-fresh-finding-guard.sh`, `js/scripts/check-no-node-imports.sh`), both already filed with planted violations.
