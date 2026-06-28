<!-- doc-tier: human | canonical-for: onboarding-critic-charter | budget: 900tok -->
# Doc-Onboarding critic — Onboarding / Time-to-Value

The 14th Cody dimension. Measures how fast a cold newcomer reaches first value,
whether the docs lead with what users want, whether the path is a precise pedagogical
waterfall, and whether the onboarding surface reflects what has actually shipped.

This is the **journey critic**, orthogonal to doc-truth:
- **doc-truth** asks "is each document internally correct, deduplicated, and correctly routed?"
- **this critic** asks "does the fastest, lowest-friction path to a first win exist, is it the one presented first, is it sequenced like a smart waterfall, and is it current with shipped features?"

A repo can have 100%-true docs and still fail here — a true-but-buried grade table,
a true-but-stale skeleton README, a friction-unranked menu of equivalent targets, or a
value proposition with no operational waterfall behind it.

**Scope**: the onboarding surface only — README, QUICKSTART, cheatsheets, PHILOSOPHY,
per-package READMEs, and any "get started" CTA. Not the full doc corpus.

## Sub-axes

| Key | Weight | Measures |
|---|--:|---|
| `time-to-first-value` | 28% | Steps from cold start to first concrete win; fastest available path vs path presented |
| `currency-feature-coverage` | 24% | Gap between shipped capabilities and onboarding mention; materiality-weighted |
| `lead-with-value` | 18% | Docs lead with what users want (value CTA), not internal artifacts (grade table) |
| `pedagogical-waterfall` | 18% | Warnings precede the commands they guard; sequencing teaches cleanly |
| `path-completeness` | 12% | Every persona has an end-to-end waterfall; no dead-ends or wrong-door naming |

## Scoring bands

| Score | Band | Meaning |
|---|---|---|
| 90–100 | Exemplary | Fastest path is the presented path; first win in ≤3 steps; zero currency gap; clean waterfall |
| 75–89 | Strong | Short waterfall, sound pedagogy; minor ordering or framing slips |
| 60–74 | Mixed | Coherent path for some personas; inverted lead or notable gaps |
| 40–59 | Weak | Headline value asserted without operational waterfall; large currency gaps |
| 0–39 | Failing | Fastest/most-valuable path missing entirely; dead-ends dominate |

## Programmatic signals

`onboarding.mjs` computes these without an agent:

1. **stepsToFirstWin** — executable command lines from first install to first win verb
   (`bp task ready` / `bp task next` / `bp whoami` / `bp capabilities` / `curl .../api/schemas`).
2. **leadOffset** — line number of first H1, first CTA heading, first install command;
   flag when a grade/percentage table (≥3 numeric cells) precedes the CTA.
3. **zeroInstallPath** — presence of a live-demo/studio URL and whether it is
   rendered as a CTA heading/imperative vs a passive inline link.
4. **cloudCoverageRatio** — shipped Cloud `bp` subcommands (hardcoded from Cloud CLI case
   blocks in `internal/cli/cli.go`: signup / login / subscribe / launch / go-live /
   barkparks / doctor) vs mentioned in any onboarding doc; Cloud coverage ratio + uncovered list.
5. **featureCurrencyDelta** — `feat(` commits merged since each doc's last git touch;
   `feat(cloud)` specifically for cloud-surface docs.
6. **destructiveGuards** — per-code-block detection of `mix ecto.reset` / `mix ecto.drop` /
   `rm -rf` / `--target local --yes` (without `--dry-run` or `--docker`; bare `--yes` is
   not flagged); checks whether a guard word (`Destructive`, `dry-run`, `WARNING`) appears
   in the **immediately preceding prose**, not just anywhere in the doc.
7. **provisionalFraming** — occurrences of `(wizard)` in ship-marker context (e.g.
   'commands marked (wizard)', '(wizard) ship with…') — bare `(wizard)` is excluded;
   also matches `against the <x>-branch`, `(coming soon)`, `[coming soon]`.
8. **pricingPresence** — grep for shipped tier names+prices (Supporter $69 / Support++ $499).
9. **entryPointRouting** — entry-point docs lacking a "which path is mine?" decision tree.
10. **wrongDoorNaming** — directory names whose label inverts consumer expectation
    (`sdk/` = Bulldocs ingest, not the general `@barkpark/core` JS SDK).

## Agent judgment batches

`onboarding.mjs` emits `agentJudgmentBatches[]` — structured questions the programmatic
pass cannot answer. A follow-on agent pass reads them and fills in:

- Per-persona time-to-value verdict (well / partially / poorly) and dead-end locator.
- Materiality of each currency gap (blocks-first-value vs nice-to-have).
- Whether the fastest available path (zero-install demo) is genuinely lower-friction
  and whether its absence from the CTA merits the full penalty.
- Provisional-stamp trust impact (none / minor / trust-eroding).
- Whether the Cloud persona's next step is discoverable from the onboarding surface.

The programmatic pass produces the floor; agent pass refines to final score.

## Usage

```bash
# Programmatic pass (writes onboarding-report.json, summary to stderr)
node tooling/doc-onboarding/onboarding.mjs

# JSON to stdout (for piping / status.mjs integration)
node tooling/doc-onboarding/onboarding.mjs --json
```

## How to wire into status.mjs / quality.mjs / SIGNALS.md as the 14th critic

**Do not edit status.mjs, quality.mjs, or SIGNALS.md here** — those files are owned
by their respective passes. This section describes the contract so the wiring author
has everything they need.

### 1. SIGNALS.md — add one row to the canonical roots table

```
| **onboarding** | journey quality — time-to-first-value, currency gap, lead framing, waterfall sequencing, path completeness | `tooling/doc-onboarding/` (`onboarding-report.json` → `overallScore`, `scores.*`, `findings[]`) |
```

SIGNALS.md is doc-tier: human; it currently has 9 canonical root rows (no hard cap declared). Onboarding is a
tree-level property (measures the surface, not per-file), in the same family as
`filebase`. It does NOT double-count doc-truth: doc-truth owns falsity/dedup/routing;
this critic owns journey/friction/currency.

### 2. quality.mjs — read the report alongside aesthetics

```js
const onb = rd("tooling/doc-onboarding/onboarding-report.json",
               { overallScore: null, scores: {}, findings: [] });
```

Add one scorecard row (weight suggestion: equal-sibling at the same tier as Bloat and
Aesthetics, ~5% of the composite when both doc critics are present):

```js
{ name: "Onboarding", score: onb.overallScore, note: "time-to-first-value critic" }
```

The cross-critic gate: a repo cannot land Exemplary/Strong here if doc-truth has
flagged the primary onboarding path as materially false — cap at Mixed (60) until the
truth defect clears.

### 3. status.mjs — emit one line in the console scorecard

```
Onboarding   <score>   <worst persona verdict> · highest-leverage: <fix>
```

Read from `onboarding-report.json`; graceful fallback to `null` when the report is
absent (e.g. first clone before the pass has run).

### 4. Gitignore

`onboarding-report.json` is gitignored (see `.gitignore` in this dir) — same pattern
as `aesthetics-report.json` and `ergonomics-report.json`. It is a local analysis
artifact, not a committed source file.
