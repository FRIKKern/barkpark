<!-- doc-tier: human -->
# Cody — programming a codebase *through* its CMS

> A constant has two homes. It lives in the code as a literal — often copied
> across several files — and it lives in Barkpark as a typed, validated, editable
> document. **Edit it in Barkpark; Cody rewrites every bound literal on disk,
> verified, in a reviewable `git diff`.** The CMS becomes the control panel for
> the codebase's own tuning knobs.

Cody is Barkpark's own agent. Two things define it:

1. **Bound variables.** A value is *one logical thing* with many physical
   homes. Cody keeps the paper and every code literal in sync — both ways — and
   flags **drift** when the copies disagree.
2. **It always knows where it is.** Before it touches anything, Cody resolves
   *which* Barkpark it's pointed at (local vs the project's public host) and
   refuses to tune code against a codebase that isn't fully analyzed.

---

## The four rungs

Cody climbs from scalars to logic. Each rung is just a richer `vtype` in
`bindings.json`, validated the same way: a candidate is accepted only if it
type-checks against the binding's constraints.

| Rung | `vtype` | Binds | Example | Validated by |
|---|---|---|---|---|
| ① | `int` / `float` | a tuning scalar | `fragile_density = 0.5` | range (`min`/`max`) |
| ② | `list` | a structured set | `bug_fix_words = ["fix","revert",…]` | JSON array, element type, `min` length |
| ③ | `expr` | a **formula** (logic) | `defect_formula = "fixes / max(churn,1)"` | evaluated with a safe parser; only declared `vars` allowed |
| ④ | `expr` (piecewise) | a **function-cell** | `effort_formula = "tokens>8000 ? 5 : …"` | same — ternary + comparison make it a real pure function |

Rungs ③–④ run on `lib/formula.mjs` — a tiny **`eval`-free** expression language
(ternary, comparison, arithmetic, a fixed function whitelist). A bound formula is
validated by *trying to evaluate it*: unknown variables, bad syntax, or a
non-finite result are rejected at the paper, never written to disk.

A binding declares its anchors — one or more `{file, pattern}` pairs whose regex
capture group locates the literal:

```json
{ "name": "bug_fix_words", "vtype": "list", "elem": "string", "min": 1,
  "doc": "commit-subject terms that mark a bug-fix (drives defect-density)",
  "locations": [ { "file": "tooling/risk/risk.mjs", "pattern": "BUG_WORDS = (\\[[^\\]]*\\])" } ] }
```

---

## Where am I? — connection resolution

Every tooling script (`cody`, `push`, `graph-view`, `tasks`) resolves its target
through one shared module, `tooling/lib/barkpark-env.mjs`. The precedence mirrors
the `bp` CLI exactly:

```
  --host flag   >   BARKPARK_* env   >   barkpark.json   >   http://localhost:4000
```

Then it **probes** `/v1/capabilities` and, if the chosen host is down *and was
derived* (not forced by flag/env), **falls over** to another reachable host in
`barkpark.json` — preferring a cloud one. So a script launched with the local
server stopped still finds the project's public Barkpark. Every command opens
with a one-line banner of exactly where it bound:

```
cody → https://api.barkpark.cloud [cloud] dataset=cody-poc via barkpark.json:public (fell over to public) ✓
```

`kind` (local/cloud) is derived from the URL (loopback / RFC-1918 → local) unless
a host entry pins it. Tokens are **never** read from `barkpark.json` — they come
from `BARKPARK_TOKEN` / `--token`, defaulting to the dev token.

---

## `barkpark.json` — the project's Barkpark map

A committed, **public, secret-free** file at the repo root. It answers *where this
repo's Barkpark lives and how to bring one up* — never *what's my token*. It is
the project-level layer the per-user `~/.config/barkpark/config.json` (written by
`bp setup`) was missing.

```jsonc
{
  "$schema": "https://barkpark.cloud/schema/barkpark.json",
  "project": "barkpark",
  "hosts": {
    "local":  { "url": "http://localhost:4000",      "kind": "local" },
    "public": { "url": "https://api.barkpark.cloud",  "kind": "cloud" }
  },
  "defaultHost": "local",          // which host the chain prefers
  "datasets": {
    "codebase": "codebase",        // the intelligence graph (logical key → name)
    "cody": "cody-poc"             // where tuning papers live
  },
  "intelligence": {
    "publishedTo": "local",        // where the scanned graph is published
    "minCoveragePct": 100,         // the "fully analyzed" bar preflight gates on
    "scan": "node tooling/status/status.mjs --publish"
  },
  "setup": {
    "local": "make dev",
    "smoke": "curl -s http://localhost:4000/v1/capabilities",
    "docs": "docs/setup/SETUP.md"
  }
}
```

| Key | Meaning |
|---|---|
| `hosts` | named connections; each `{url, kind?}`. `kind` pins local/cloud (else derived). |
| `defaultHost` | the host name the resolution chain prefers when no flag/env wins. |
| `datasets` | logical key → dataset name. Scripts pass a key (`codebase`, `cody`) and get the mapped name; `--dataset`/`BARKPARK_DATASET` still override. |
| `intelligence.minCoveragePct` | the research-coverage bar Cody preflight treats as "fully analyzed". |
| `intelligence.scan` | the command preflight tells you to run when the graph is stale. |
| `setup` | human hints — how to start a local server and smoke-test it. |

**Rule:** no credentials, ever. The file is committed and public; secrets live in
env or the user-level CLI config.

---

## Preflight — never tune a codebase you don't understand

`cody preflight` reports where it bound *and* whether the codebase is fully
analyzed, then exits non-zero if not. It reads the artifacts the
`codebase-quality` suite already writes (`status.mjs`) — it never re-runs the
chain. "Fully analyzed" means **all** of:

- **reachable** — Barkpark answers `/v1/capabilities`;
- **scanned** — `tooling/barkpark-sync/nodes.json` exists;
- **covered** — research coverage ≥ `intelligence.minCoveragePct`;
- **no pending agent work** — no files missing intentions, no stale consistency groups;
- **in sync** — the graph hasn't changed since the last publish;
- **no drift** — no bound variable disagrees across its copies.

```
$ node cody.mjs preflight           # run from tooling/cody/
  cody → http://localhost:4000 [local] dataset=cody-poc via barkpark.json:local ✓
  intelligence: 412 files · coverage 100% · graph in sync
  ✓ GREEN — Barkpark reachable, codebase fully analyzed, no drift
```

The gate runs before **every** command:

- `apply` / `watch` (which rewrite source on disk) **block** on a non-green
  preflight — `--force` overrides. *Tuning against a stale graph is tuning blind.*
- `scan` / `status` / `set` only **warn** — they never touch source.

---

## Commands

Invoke as `node cody.mjs <command>` from `tooling/cody/` (no standalone binary).

| Command | Direction | What it does |
|---|---|---|
| `preflight` | — | resolve host + report full-intelligence freshness; exit ≠ 0 if stale |
| `scan` | code → paper | extract every literal, register the `tuning` schema, publish each as a doc |
| `status` | — | control panel: code value vs paper value vs # locations + drift |
| `set <var> <val>` | → paper | validate against the binding's type/constraints; write to Barkpark (rejected *at the paper* if invalid) |
| `apply [--write]` | paper → code | rewrite every bound location; dry-run unless `--write` |
| `watch` | live | SSE bridge — edits in Barkpark land on disk instantly, reconnecting on drop |

Common flags: `--host URL`, `--dataset NAME`, `--token TOKEN`, `--force`.

---

## Safety & guarantees

- **Verify-after-write.** `apply`/`watch` re-read each literal after rewriting and
  throw if the on-disk value doesn't match the canonical paper value — a write
  either fully lands or errors; it never half-writes.
- **Canonical compare.** Lists normalize to compact JSON and formulas are
  whitespace-insensitive, so a code literal and a paper value compare equal
  regardless of formatting.
- **Drift is surfaced, not silently reconciled.** When copies of one constant
  disagree, every command shows `⚠ DRIFT a≠b`; preflight makes it a blocker.
- **No secrets on disk.** `barkpark.json` is credential-free by contract.

## What's real vs. a proxy

- **Bindings are hand-curated** in `bindings.json` — a deliberate, auditable set,
  not auto-discovered. Adding one is adding a `{file, pattern}` anchor.
- **The intelligence check reads cached artifacts**, so preflight is fast and
  offline — but `.last-push-hash` is per-repo, not per-host: push to local then
  preflight against public and the "in sync" signal is approximate.
- **`cody-poc` is an isolated dataset** — tuning papers never touch `production`
  or the `codebase` graph.

---

See `tooling/README.md` for the whole Codebase-Intelligence suite, and the
`codebase-quality` skill (`.claude/skills/`) for orchestration.
