<!-- doc-tier: human | canonical-for: scaffy-frequency-miner | budget: 3000tok -->
# scaffy-mine — the canonical Scaffy frequency miner

`bash tooling/scaffy-mine/mine.sh` → one JSON object of reproducible, labelled
accretion-frequency numbers. It replaces the W5 hand-mined figures that were
computed agent-side with a drifting window and a capped node script that can no
longer be re-run. **This script's output is canon.** It is also the executable
prototype for `bp scaffy discover` (leap 1, spec below) — the Go verb now
EXISTS (`internal/scaffy/discover.go` + `internal/cli/scaffy_discover_cmd.go`)
and is the living, whole-repo successor; this script stays pinned as the
papers' reference oracle (`bp scaffy discover --until 591fdcd53` reproduces
its stage-2 figures exactly: router 174 commits / 1280 partners /
378·164·78·53 support, co-creation 236 strict / 304 loose).

Read-only git. Deterministic (window pinned to a commit, not wall-clock). No
dependencies beyond `bash` + `git` + `awk`. Runs the full repo in **~1.8s** on an
M-series Mac (measured; comfortably under the 60s gate and the 3s Go target).

## What it emits (pin `591fdcd53`, 12 months before the pin's commit day, `--no-merges`)

| Field | Value | Reproducible? |
|---|---|---|
| `errors_ex_accretion.added_clause_lines` | **38** | exact |
| `errors_ex_accretion.distinct_commits` | **19** | exact |
| `errors_ex_accretion.misgrep_def_build` | **0** | exact (see mis-grep note) |
| `co_creation.strict_basename_paired` | **236** | exact under the pinned window (charter cited 234 — see Honesty record) |
| `co_creation.loose_any_ex_any_test` | **304** | exact under the pinned window (charter cited 303 — see Honesty record) |
| `router_ex_cochange.commits` | **174** | exact |
| `router_ex_cochange.partners.naive_uncapped` | **1280** | exact (charter's "~1275" was approximate) |
| `router_ex_cochange.partners.by_min_support` | **≥2: 378 / ≥3: 164 / ≥4: 78 / ≥5: 53** | exact |
| `router_ex_cochange.partners.restricted_to_nodes_json_universe` | **null** (~468 when materialized) | NOT from a clean checkout — see below |

**The mis-grep tripwire.** `errors.ex` builds error shapes with `defp build(…)`
clauses — *private*. Grepping for `def build(` (public) returns **0** and would
silently claim "no accretion here". The miner counts the real grammar and prints
the mis-grep value beside it so the trap is visible, never load-bearing.

## Honesty record

1. **The 739 router-partner figure is DROPPED (charter D69(b)).** W5 cited "739
   co-change partners" for `router.ex`. It is **irreproducible**: the only script
   that produced partner lists, `tooling/cochange/cochange.mjs`, hard-caps partners
   at `MAX_PARTNERS = 8` (line 44) and restricts to the `nodes.json` universe with
   a `MIN_SUPPORT = 3` threshold — it *structurally cannot* emit 739 for any file.
   The original run used a ~2874-commit window that is unreconstructable (no pin,
   no recorded date). We do not carry forward a number we cannot re-derive. The
   honest, uncapped truth for this file, in the pinned window, is **1280 naive
   partners** (falling to 378 / 164 / 78 / 53 as you demand ≥2…≥5 co-changes).

2. **Co-creation drifts ±1–2 from the charter, and that drift is the whole point.**
   The survey computed 234 strict / 303 loose with a literal `--since='12 months
   ago'` — a window that moves every day it is run, so the numbers were never
   reproducible. This script pins the window to the PIN commit's own day, giving a
   stable **236 strict / 304 loose**. The 2-and-1 gap *is* the drift the survey's
   floating window introduced. The pinned figures supersede them.

3. **The `nodes.json`-restricted "~468" is not a clean-checkout number.**
   `tooling/barkpark-sync/nodes.json` is a *derived, gitignored* artifact
   (`generate.mjs` output). When it is present the miner computes the restricted
   count; otherwise it emits `null` with a reason. A benchmark number that
   silently depends on an un-committed file is not canon — so we mark it as such.

4. **What "uncapped" means.** No `MAX_PARTNERS`, no `MIN_SUPPORT` at the source, no
   sprawl cap. Thresholds (≥2…≥5) are reported *as a distribution over the full
   partner set*, so a reader chooses the cut — the miner never chooses it for them.

## `bp scaffy discover` — the Go-pass spec (leap 1, backlogged)

W5 mined patterns **by hand, agent-side** — a real (if unmetered) token spend per
pattern; per charter D69(a) no token figure for that work is citable as data. This
bash prototype proves the same mining is a deterministic, **zero-token** pass. The
ascension: promote it to a first-class `bp scaffy discover` subcommand in Go so
the catalog's own justification is a build artifact, not an agent transcript.

**Shape — three stages over ONE shared git-log skeleton** (exactly what `mine.sh`
does; the awk becomes Go):

- **Shared skeleton.** One `git log --no-merges --since=<pinned> --format=<sentinel>%H
  --name-status <pin>` invocation, streamed. Split on the sentinel into per-commit
  file-status sets. Every stage consumes this one stream — no second git pass.
- **Stage A — hunk-added-regex counter.** For a named accretion file + a clause
  regex (`^\+\s*defp build\(`), a second streamed `git log -p -- <file>` counts
  added clause-lines and the distinct commits that added them. This is the
  "how hot is this registry" signal.
- **Stage B — same-commit suffix-pair matcher.** Over ADDED files per commit,
  basename-pair `foo.ex`↔`foo_test.exs` (strict) and any-`.ex`+any-`_test.exs`
  (loose). Generalizes to any suffix pair (`.ex`/`.html.heex`, `.ts`/`.test.ts`) —
  the "these are always born together" signal that justifies co-creation commands.
- **Stage C — uncapped co-change matrix.** For a target file, count every partner
  co-touched in the same commit, with a support histogram (≥N). Modeled on
  `cochange.mjs`'s git-log parsing but **without** the `nodes.json` universe gate
  and **without** partner caps — the discover pass reports the full distribution
  and lets the caller threshold. This is the "what accretes around this router"
  signal that surfaces registry/barrel hot-spots to Scaffy-ify.

**Deliberate non-features.** No `nodes.json` gate (discover must run on a bare
checkout). No caps (report the distribution, don't pre-truncate). No JSON schema
dependency (stdlib `encoding/json` only). No wall-clock window (pin-derived).

**Build cost.** ~**300–400 LOC** of Go, stdlib-only (`os/exec` for `git`,
`bufio.Scanner` for the stream, `regexp`, `encoding/json`). One `discover.go` +
one `discover_test.go` golden-fixture test. Target runtime **sub-3s** on the full
repo (the bash prototype is 1.8s; Go with a single streamed pass should beat it).
Estimated **~1 focused build session**. Backlog task: **scaffy-backlog-discover-go-pass**.
Do **not** build the Go subcommand from this directory — this miner is the spec and
the reference oracle its golden test will pin against.
