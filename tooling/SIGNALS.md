<!-- doc-tier: human -->
# tooling/ — Canonical signals (one signal per root)

The codebase-intelligence suite scores every file on several axes. The flaw v2
fixes: three headline scores (`importance`, `usefulness`, centrality) all ride
the **same root signal** — reach (the dependency graph). When a file is imported
everywhere it tops all three *for one reason*, and the dashboard reads as three
independent confirmations of a single fact. That is double-counting dressed as
corroboration.

The fix is one rule.

## The rule

> **Measure each root signal exactly once. Compose only ACROSS roots.**
>
> Orthogonal roots measure genuinely different things, so composing them
> *compounds* into a new signal (churn × complexity is more than either alone).
> **Never blend same-root signals** — that is pure overlap and just re-asserts the
> underlying signal with a multiplier (reach × reach = reach², not new
> information).

Every composite must trace back so that **no root reaches the same composite
twice**.

## The canonical roots — each measured ONCE

| Root | Measures | Measured by (the one pass that owns it) |
|---|---|---|
| **reach** | transitive dependents — how many files (transitively) depend on this one; dependency/import-graph centrality | `tooling/blast-radius/` builds the file graph; `tooling/barkpark-sync/generate.mjs` derives `dependentCount`; `tooling/usefulness/usefulness.mjs` computes transitive `reach` (promoted to the surfaced value — see below) |
| **churn** | git change frequency | `tooling/file-importance/` (`file-signals.json` → `churn`) |
| **complexity** | size / cognitive load — tokens, defs (ergonomics) | `tooling/ergonomics/` (`tokens`, `defs`, `sizeClass`, `bloat`) |
| **defects** | fix/revert commit density — where bugs actually land (risk) | `tooling/risk/risk.mjs` (`bugFixes`, `defectDensity`) |
| **tests** | test presence proxy — reliability (risk). v2 Phase 1 replaces the proxy with real coverage | `tooling/risk/risk.mjs` (`hasTest`, `testScore`) |
| **conventions** | consistency with house style | `tooling/consistency/` |
| **ownership** | bus-factor / author concentration — *NEW in Phase 0* | `tooling/risk/risk.mjs` (`primaryAuthorShare`, `authorCount`) |
| **relationships** | dependency · intention · co-change edges | `tooling/barkpark-sync/` (dependency) + `tooling/intentions/` (intention) + `tooling/cochange/cochange.mjs` (co-change — built, integrated into generate.mjs) |
| **filebase** | tree tidiness — root clutter, tracked build artifacts, directory fan-out, spotlight-clutter (a top-level dir holding one niche file), dead/stale docs, dead/stale tasks, YAGNI orphans | `tooling/aesthetics/aesthetics.mjs` (`bloat.score`, `aesthetics.score`, per-finding `{path, kind, severity, why, fix}`) |

### filebase — the structural root (the only one not measured per-file)

Every other root is a property of a *file in the graph* (its reach, its churn, its
coverage). **filebase** is a property of the **tree** — where files sit, what's
committed that shouldn't be, what's dead. That is why it cannot double-count: it
measures a genuinely different thing (structure / tidiness), so it composes cleanly
with the per-file roots rather than re-asserting one of them.

Its ethos is **YAGNI** — *reward absence*. The detector flags only what does not
earn its place: source dumped in the repo root (belongs in a subpackage), build
artifacts tracked in git (diff noise — gitignore), a cold-doc graveyard (`_attic/`),
junk/unscoped tasks, and high-confidence orphans. It is deliberately **conservative**:
`main.go`/`go.mod`/`Makefile`/`README` are never "dead"; a contract or runbook is not
dead just because it isn't a routing card; golden/testdata fixtures and `.changeset/`
files (referenced by *convention*, invisible to grep) are explicitly skipped. The
analyzer only ANALYZES — it never deletes or moves a file. It feeds two scorecard
dimensions: **Bloat** (structural) and **Aesthetics** (qualitative mess + YAGNI).

## What Phase 0 changes

- **`usefulness` → `reach`.** "Usefulness" was never a distinct value axis — it
  was reach with a leverage/reliability multiplier, blended with an agent score.
  v2 makes `reach` a **pure programmatic value**: a normalized (0–100) transitive
  dependent count. No agent pass produces the number any more. The existing agent
  `why_useful` prose is **kept as a `why` DESCRIPTION field**, graded "reusability"
  — it explains *why* a file is reusable; it is **not a score**.
- **`ownership` added.** Programmatic, free — one git-log pass already runs in
  `risk.mjs`. Per file: `primaryAuthorShare` (top author's % of commits) and
  `authorCount` (the bus-factor). Surfaced on the papers.
- **`importance` is untouched.** It stays exactly as v1 computed it. In **Phase 2**
  it becomes a *composite* read from `scoring-config.json` (a derived score over
  clean roots), not a base score. Phase 0 only stops framing usefulness as a
  separate value axis that double-counts reach with it.

## Composites (Phase 2 — not built here)

Recomposed on canonical roots, each factor a distinct root, each root once:

- **Hotspot** = churn × complexity — refactor targets (the field's gold standard).
- **Priority** = reach × issue-severity × defect-amplifier × untested-boost.
- **Refactor-worth** = bloat × churn × separability — the agent-ergonomics axis.
  Each split candidate also carries a deterministic **safety** label (path + churn,
  pure: `contract` / `test` / `cli-tool` / `prod`, churn>30 overlay) so the plan
  ranks SAFE high-value splits first and flags risky prod ones — ordering + annotation
  only, the Modularity SCORE is unchanged.
- **Critical-untested** = reach × ¬(real coverage) — the danger worklist.

Phase 0 establishes the clean roots those composites read. The calibration engine
(`tooling/fit/`, Phase 4) is built; all four composites (Hotspot, Priority,
Refactor-worth, Critical-untested) are implemented.
