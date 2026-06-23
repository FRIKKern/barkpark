<!-- doc-tier: agent | canonical-for: grade-critique | budget: 1400tok -->
# Grade Critique — the honest layer over the 9 critics

**Mandate (standing).** A Cody grade is never reported as bare numbers. Every grade run is paired with an *agent-judged* critique that states, per dimension and overall: **why** the number is what it is (cite file:line), the **honest cons** / where it is inflated or blind, whether the metric is **plainly missing important factors**, and **concrete suggestions** to make the dimension true. A high/perfect score is treated as a *red flag for a narrow detector*, not proof of a clean codebase, until an agent has verified it. Coverage *presence* ≠ test *quality*; threshold metrics (Modularity) are checked for gaming, not just for crossing the line.

**Protocol.** On any grade/report: dispatch read-only critic agents (Sonnet/Opus, never Haiku) over the *real* artifacts — the test files, the detectors, the diff — one per suspect dimension. Each agent is told to be skeptical and prove claims with file:line. Synthesize their findings into the report; fold confirmed blind spots into the worklist below; fix grader bugs that make it lie. Re-run only after the artifacts that feed it are regenerated together (`node tooling/status/status.mjs`) so the scorecard is internally consistent.

---

## Latest critique — 2026-06-23 · grade B+ 81 (false B+ 81 → B 79 read fix → B 75 wiring Contract+Dependencies exposed real CVEs → B 79 triaging every critical+high CVE → **honest B+ 81** clearing moderates, removing dead deps, and guarding all 4 wire seams with executable contract tests)

Four critics audited the live grade. Headline truth: **the 9 critics measure how *maintainable* the code is to change — not whether it is correct, secure, or fast at runtime.** Two findings changed the number:

- **Architecture was a false 100.** `quality.mjs` read `results/_layering.json` / `_dup.json`, which a `consistency.mjs scan` never writes (only the `batches/record` agent cycle does). The grader saw `[]` and awarded 100 while `verdict-cache.json` held **5 confirmed layering violations** (`listen_controller`, `tasks_controller`, `pane_builder` build raw Ecto queries in the web layer; `cross_validator`, `search_intelligence` alias `BarkparkWeb.*` from core — arrow inversion). **Fixed**: the grader now falls back to `verdict-cache.json`. Architecture → **85**, overall → **B 79**.
- **Tested 87 is honest about Elixir, blind about everything else.** It is real `mix test --cover` line coverage (elixir 74.2%), but the reach≥40 gate that decides "what's worth testing" *also* decides "what we measure" — so the Go TUI (46%, reach-0) contributes nothing and the **Next.js `web/` app (zero tests) is excluded, not failed**. The dimension note now states this. Live landmine: the proxy hatch (`risk.mjs:191`) scores any file with a sibling test 60% regardless of assertions — harmless only because such files are currently reach-0.

Other 100s: **Dead-code** is Go-packages-only (Elixir/JS/LiveView dead code invisible — rename-worthy). **Evaluated** is a binary "ledger non-empty" trophy while `coverage-report.json` says 74.6% (403 unresearched, 383 auto-stubs). The **sheet_grid decomposition was genuine**, not gamed (clean pure/effectful seams), with one stale false comment (`geometry.ex:14-15`) and an inherited `Core` A1-math duplication to consolidate.

---

## Blind-spot worklist (what a glowing grade still hides)

Ranked by danger × cheapness. The first three are the most dangerous *and* cheap.

| Gap | Why it's dangerous for a public multi-tenant CMS | Cost | How |
|---|---|---|---|
| **Security-critical coverage** | cross-tenant leak / GROQ-or-SQL injection ships green; grade is silent | cheap | tag auth/tenancy seams (`scope.ex`, token plug, query compiler), assert sibling isolation test; regress if dropped |
| ~~API-contract stability~~ **→ WIRED + GUARDED** (`Contract` **100**) | a `/v1/capabilities` shape change bricks the Go CLI + JS SDK | done | reads `blast-radius` seam guards. All 4 wire seams now carry an executable `.exs` contract test (query/mutate, schema_envelope, webhooks/listen — 32 tests; the tests pre-existed, just registered as guards). |
| ~~Dependency / supply chain~~ **→ WIRED + TRIAGED** (`Dependencies` **94**) | CVE in Phoenix/Plug/Oban/npm on the open internet; CI runs `--no-audit` | done | `tooling/deps/deps.mjs` (`mix hex.audit` + `npm`/`pnpm audit`; `govulncheck` skipped). Surfaced **2 critical + 14 high** in `js/` (CI's `--no-audit` hid them) → **all cleared + most moderates** (vitest 2→4, next bump, dead-miniflare removed, ws/form-data/undici/postcss/js-yaml overrides); 3 moderate / 1 low remain (esbuild pinned by vite, js-yaml 3.x major-only). Formula refined from a saturating cliff to a gradient (criticals dominate linearly) so triage moved it 0→44→86→94. |
| **`web/` frontend coverage** | a whole shipped surface has zero tests, excluded by reach | medium | vitest + Istanbul under `web/`; `risk.mjs:166` already scans for it |
| **Type safety (dialyzer)** | spec rot in the dynamically-typed core | medium | dialyzer warnings/module as a critic (PLT cacheable) |
| **Runtime perf / N+1** | the classic CMS killer; "Hotspots" measures change-difficulty, not runtime cost | medium→hard | static `Repo.all`-inside-`Enum.map` lint cheap; true N+1 needs a telemetry harness |
| **OTP discipline / resilience** | blanket `rescue`, unsupervised `Task.start`, no Oban `max_attempts` | medium | static finding kinds; "Reliability" today is only *past* bug-fix density |

**Grader bugs / limits to keep honest:** broken `_layering/_dup` read (FIXED); proxy `+60` hatch ungated on assertion density (`risk.mjs:191`); reach is both value-axis and coverage-filter, so reach-0 surfaces (web/, Go `main`) vanish from Tested; layering rule set is two regexes (`Repo.` in web, `BarkparkWeb.` in core) — cannot see god-context fan-in, plugin↔plugin, or runtime/PubSub cycles.

## Code anchors
- tooling/quality/quality.mjs — the 11 `dims` (weights renormalized), the verdict-cache fallback, the inline Contract signal, the honest dim notes
- tooling/deps/deps.mjs — the Dependencies critic (`mix hex.audit` + `npm`/`pnpm audit` + `govulncheck`); writes deps-report.json
- tooling/consistency/verdict-cache.json — real layering/duplication verdicts (the grader's source of truth when results/_*.json are absent)
- tooling/risk/risk.mjs — coverage measurement + the proxy hatch (line ~191)
- tooling/blast-radius/config.json — the four wire seams + their guards (now read by the Contract critic)
