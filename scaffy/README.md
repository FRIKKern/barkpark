<!-- doc-tier: human | canonical-for: scaffy-corpus | budget: none -->
# Scaffy — commands as content

**A Scaffy command is a `.scaffy` file: a declarative, idempotent, reversible scaffolding
document.** It doesn't just *generate* a new file — it also injects the wiring a plain
generator can never reach: the registries, routers, barrels, index files and config maps
that every real feature has to be threaded into by hand. It plants a named `MARK` at each
injection site so a later run is a no-op and a `remove` is exact, and it closes by running
the repo's own gates so a green apply *means* the slice compiles.

The doctrine behind it, stated once:

> **Every fact has one owner.** Every *derived* surface is either collected at runtime
> (plugin behaviour), generated from a manifest (capabilities / tokens / codegen), or
> **applied by a command** — never maintained by hand.

The north star is a 30-second vertical slice with parity at birth:

```console
$ bp add block-type --var BlockName=timeline
  ● internal/pdrender/timeline.go            created
  ● internal/pdrender/timeline_test.go       created
  ○ internal/pdrender/pdrender.go            injected  MARK:go-registry-timeline
  ○ js/packages/react/src/blocks/core.ts     injected  MARK:js-emitter-timeline +js-map
  ○ js/packages/react/tests/PortableDoc.test.tsx      injected  MARK:js-case-timeline +js-count
  ○ api/lib/barkpark/portable_doc/render/compose.ex   injected  MARK:ex-compose-timeline
  ✔ go test -run TestTimelineRenderer ./internal/pdrender/   ok
  ✔ npx vitest run                                            42→43 passing
  scaffy: timeline block scaffolded across 3 surfaces + test parity in 28s
```

The fast path *is* the standard path — standards become executable.

## Papers

- **Masterplan** — the full design case: [`/papers/scaffy-commands-as-content`](/papers/scaffy-commands-as-content)
- **Showcase** — every W1 command shown in full, with file trees, run mocks and a remove demo: [`/papers/scaffy-command-showcase`](/papers/scaffy-command-showcase)
- **Benchmark** — the measured case: byte-identical to the agent at $0 wherever the catalog covers the chore, with the boundary where it does not: [`/papers/scaffy-benchmark`](/papers/scaffy-benchmark)

## Status — engine shipped, catalog served

The **engine is live** — `bp scaffy validate` / `fmt` / `run` / `remove` (W2–W3) apply,
receipt, and reverse commands from marks, and the corpus is **served from the connected
Barkpark** (W4). The `.scaffy` documents are still full-text, copy-ready and hand-applicable
*today* (see [Hand-applying a command today](#hand-applying-a-command-today)); they also *are*
the specification — the corpus defines the hardened v2 grammar by example and is the parser's
own test fixtures.

| Wave | Ships | State |
|---|---|---|
| **W1** — corpus + showcase | 7 full `.scaffy` commands, this README, the showcase paper | shipped |
| **W2** — parser + validator | `bp scaffy validate` / `bp scaffy fmt` in Go: the grammar as code — strict tokens, derived-guard check, weak-guard lint, casing-consistency lint. The Wave-2 rulings below are its law | **shipped** |
| **W3** — engine | `bp scaffy run` / `bp scaffy remove`: apply with marks + receipts (`.scaffy/receipts/`), dry-run diff, idempotent re-run, symmetric remove | **shipped** |
| **W4** — commands as content | a `command` document type, the corpus served from the connected Barkpark, `bp scaffy pull <concept>/<variant>` + `bp scaffy ls --remote` (validate-first + consent gate) | **shipped** |
| **W5** — ONEOF + the frequency-mined seven | the `ONEOF` enum primitive (D56, lint `E-021`), 7 new commands (add-error-shape, add-canonical-marker, ensure-import, ensure-cli-noun, add-backfill-task, add-schema-type, classify-block-type), the flagship's pd-parity leg, corpus reconciled at 14 and seeded | **shipped** |

The CLI surface is **eight verbs**: `validate` / `fmt` (W2), `run` / `remove` (W3),
`pull` / `ls --remote` (W4), plus **`bp scaffy discover`** — a deterministic, read-only,
zero-token git-mining pass that ranks the tree's accretion hotspots into new command
candidates — and **`go run ./scaffy/seed --check`**, which syncs the corpus to the served
catalog and is its drift tripwire.

**The merged-is-served law.** A `.scaffy` edit changes the source's `sha256`, so the served
copy must be re-seeded or it silently falls behind `main`. `seed --check` (and the
advisory `scaffy-catalog-drift` workflow that runs it on every corpus PR) reds the moment a
touched command drifts — served bytes must equal merged bytes.

## The command corpus

Twenty-two commands, each covering a thing Barkpark development actually repeats — the
Wave-5 additions (and add-sdk-method / ensure-root-layout-zones / ensure-router-zones /
add-plugin-bucket / add-plugin-route / ensure-console-hook-zones / add-console-helper /
add-site-template after them) were frequency-mined from twelve months of git history, so
every entry answers a proven repetition. Every command lives at
`scaffy/commands/<name>.scaffy`.

**Recipes** (`scaffy/recipes/`) are documented shell sequences over these commands —
the ratified composition surface (charter D80; chain primitives rejected). Start with
`recipes/feature-pack.md`: a complete plugin+schema+route+CLI+SDK feature in six proven
steps, zero hand-bridged registrations.

| Command | What it does |
|---|---|
| **add-block-type** | Flagship. Scaffolds a new PortableDoc block across **3 code surfaces** — Go renderer + `DefaultRegistry` map entry, an Elixir `compose_block/2` clause before the catch-all, and the JS fail-closed 4-edit (emitter fn + `coreEmitters` entry + `CASES` fixture + `toHaveLength` count bump) — plus optional CSS/classification. Parity at birth. |
| **add-oban-worker** | Creates a worker module + its test under `lib/barkpark/workers/`, then injects a `{"* * * * *", Worker}` tuple into the `Oban.Plugins.Cron` crontab in `api/config/config.exs`. `:default` queue only. |
| **add-cli-verb** | Appends one entry to a plugin's `cli_commands/0` list — a manifest-driven CLI verb with **zero Go**. Showcases "the architecture already made this a one-liner." |
| **add-migration** | Creates a timestamped Ecto migration under `api/priv/repo/migrations/`. The 14-digit timestamp is a declared `VARIABLE` (commands have no clock) and drives the D3(d)/A1 module-name transform. |
| **add-plugin** | All-CREATE, zero-inject: `plugin.json` + `README.md` + `schemas/.gitkeep` + a one-line `use Barkpark.Plugin` module + a test — the live `mix barkpark.plugin.new` templates, formalized. `discover_and_register/0` auto-collects the rest. |
| **add-docs-card** | Creates a routing-table row in `CLAUDE.md` + a card file with a `doc-tier` header. The 7-card cap makes it a *scratch demo* today — it can only land paired with a remove. |
| **remove-docs-card** | The symmetry partner: removes the row, the card file and the `docs/INDEX.md` brace-expansion mention, leaving the tree byte-clean. Proves every mutating op is reversible from its `MARK`. |
| **add-error-shape** | Lands a new v1 JSON error code end-to-end (38 clause-adds in `errors.ex` history): a fix-suggesting `@hints` entry, a `build/1` clause, a test — accreting behind marks. `known_codes/0`, the OpenAPI `Error.code` enum and the coverage test all self-derive. |
| **add-canonical-marker** | Plants the two-line `@canonical capability:<slug>` marker above any **public** entry point (274 commit mentions, 40 live markers). The head line crosses as an `OPAQUE` variable taken verbatim (D58) — multi-clause Elixir heads and Go signatures both anchor cleanly. Since W6 it is the corpus's one `INSERT BEFORE FIRST` (see the Wave-6 ruling — its original self-consuming-REPLACE spelling is the fixture that ratified the primitive). |
| **ensure-import** | The first **ensure** command: idempotently ensures a module `import` line exists in an Elixir file — insert once after a caller-named anchor, skip forever after. Guard = the full import line itself (the ensure law, below). |
| **ensure-cli-noun** | Same law, Go spelling: ensures a top-level noun sits in **both** scaffy-owned copies of the `bp` noun set — `completionNouns` (shell completion) and `usageBuiltins` (the top-level usage built-ins line, a slice since the 2026-07-17 drift backfill). Ends the three-copy noun drift the W6 duels measured as the catalog's worst gap. The dispatch copy stays hand-written, gated by `TestCompletionNounsCoverAllDispatchedBuiltins` + its usage mirror. |
| **add-backfill-task** | All-CREATE: a safe-by-default one-shot backfill `Mix.Task` (8+ live tasks share the idiom byte-for-byte) — a bare run is a DRY RUN that writes nothing, `--apply` mutates — plus a paired pure-helper test that never boots the app. |
| **add-schema-type** | A plugin-declared document type in the MINIMAL-template shape (the byte-identical 6-key `SchemaDefinition` wrap scaffy/bulldocs/sheets share): one schema JSON created + two `register_schemas/1` injections. `Visibility` is a `ONEOF` enum — `public`\|`private`, anything else refused at substitution time. |
| **classify-block-type** | Closes add-block-type's manual step: adds a block type to its composition-doctrine tier entry list in `tiers.ex` via one bare `INSERT AFTER FIRST` at the `@{{.tier}} [` opener — since the 2026-07-17 append-friendly restructure (the ~w sigils became plain string lists with house trailing commas), any number of same-tier classifies land as independent clean inserts, killing the W7 same-tier refusal (D80) and its one-word hand-edit recipe (D79, retired). Mark names are `tier-<name>--<tier>` (double-dash sentinel) so the engine's substring re-run guard is prefix-safe against pairs like stat/stats; a hand-added entry guard-skips clean per the ensure law. `Tier` is the corpus's first `ONEOF` (`element`\|`widget`\|`section`); `:section` still refuses loud (one-line list, hand-edit territory). |
| **add-sdk-method** | Lands a new `@barkpark/core` client method end-to-end — the six-file layer-parity chore measured at 34 commits/12 months: a starter module in the house transport idiom, `Result`/`Options` types + the `BarkparkClient` signature, the `createClient` wiring, both `index.ts` barrel exports, an msw test pair, and the corpus's **first scaffolded changeset**. All six injections are bare `INSERT AFTER FIRST` against never-consumed anchors (house trailing-comma style makes every site separator-safe) — no REANCHOR families. |
| **ensure-root-layout-zones** | Plants the two named `scaffy:zone` marker comments in `root.html.heex` — the repo's #2 accretion file, which W1/W7 ruled un-anchorable. Zero variables: a one-time reversible plant of a head anchor at each genuinely append-shaped neighborhood (new script assets after `{@inner_content}`, new LiveView hooks after `let Hooks = {};`), so later appends land at a named mark. The other two streams are cut with evidence in the command prose: theme blocks are emitter-owned (`design/emit.mjs` generated region) and feature CSS placement is contextual by design (the W1 CSS-leg cut, re-affirmed). |
| **ensure-router-zones** | Same repair, router spelling: plants three `scaffy:zone` comments in `router.ex` — the #1 unserved accretion file (175 commits/12 months, 68% PURE_ADD), twice ruled un-anchorable because route order is semantics. Each zone sits where an append is ordering-safe **by construction** and its comment states the contract it guards in words (pipeline definitions are position-free; new plugin auth-buckets land before the dynamic-tailed `:ticket_key` run; scoped mirrors are order-neutral at the tail given a novel `/v1/<noun>` suffix). The flat-core `/v1` stream is cut with evidence: those adds are neighbor-bound (in-scope appends, "sibling routes below" prose, noun-local static-before-dynamic pins no generic zone can encode). |
| **add-plugin-bucket** | The zones' first consumer: a new plugin auth-tier as 2 `INSERT AFTER FIRST` ops anchored at the router zones' mark lines — the `pipeline :<bucket>` definition in the router-pipelines zone + the `scope <mount> … plugin_routes(scope: :<bucket>)` wrapper in the plugin-buckets zone (5 such bucket adds since April). Requires ensure-router-zones applied first, **by loud refusal**: the anchors don't exist on a virgin tree, so the engine's D20 conservatism refuses (exit 5, nothing written) and the command's prose carries the 2-run recipe — run-proven that recipe + refusal beats a composition primitive. `MountPath` is a `ONEOF` (`/v1/plugins`\|`/v1`); the auth plug is deliberately open. Router leg only — the plugin's `register_routes/1` entries are add-plugin-route's job; the JS manifest-parity tripwire is separate (non-scaffy) work. |
| **ensure-console-hook-zones** | The cloud-console repair: plants three `scaffy:zone` comments across the Cloud console SPA pair — app.js (#7 discover hotspot, 81 commits/60 MOSTLY_ADD) + its co-accreting node harness `__app.test.mjs` (55/82 commits ride together). One zone per mechanically append-shaped seam: new pure-helper declarations (IIFE scope + eval-tail hook call make position semantics-free), new `__bpTestHook` export entries (order-free keys, house trailing commas), new test groups (node:test registration order is NOT semantics-free — a `test()` registered above a top-level `await` is drained before the later top-level `const`s initialise and TDZ-crashes, measured cch-w61-s1 on node 20 *and* node 22 — so this zone is planted at the harness TAIL, below every top-level await). The console vein's other legs are cut with evidence in the command prose: the cloud router is a 9968-line `Plug.Router` of bespoke inline handler bodies with noun-local ordering pins (the flat-core ruling, re-affirmed), registry.ex is an Ecto context accreting bespoke `@doc + def` business functions, and app.css is emitter-owned at the head (design/emit.mjs GENERATED tokens) + contextual-by-section in the hand region. Includes the corpus's second and third `INSERT BEFORE FIRST`. |
| **add-console-helper** | The zones' consumer: one node-pinned pure helper across the pair in a single run — the `function` skeleton in the console-helpers zone, its export entry in the console-hook-map zone, its starter test group in the console-tests zone. Requires ensure-console-hook-zones first **by loud refusal** (the add-plugin-bucket recipe: absent anchors exit 5, nothing written). The starter is an identity passthrough with a test pinning exactly that, deliberately: growing the body reds the starter test and forces the test group to grow in the same change. Closes on the pair's own CI-enforced gate run LOCAL: `node --test cloud/priv/static/__app.test.mjs` (438+ tests, ~250 ms, zero deps — console-harness.yml runs the same suite on PRs). |
| **add-site-template** | The overpowered one: births a complete deployable cloud site template in one run — a 13-file Astro static starter tree under `templates/<slug>/` (manifest + schema + seed + app skeleton, modeled on astro-starter) **plus all 13 catalog-family and deploy-axis injections across 12 files** (both cloud allowlists, the `/new` display catalog, both bootstrap lock literals, the pinned deploy-test message, the `DeployRequest` clause + message, the Provisioner row, the runtime.exs env override — the touch point the historical astro-search-starter addition missed — the Go exact-set lock, the CLI usage line, MANIFEST.md). Closes on the repo's own drift gates: `make provisioner-catalog-sync` (glob-driven mirror), the Go catalog lock both directions, and the Elixir lock tests (ci). The reverse-drift trap (a manifest without its family reds the tree) is exactly why it is ONE command. Honest line: framework fixed to Astro/static; `package-lock.json` is a documented manual step (`npm ci` needs resolved hashes scaffy cannot synthesize). |
| **add-plugin-route** | The in-plugin leg: one route tuple planted at the **head** of a plugin's `register_routes/1` list — the route auto-folds into the host router at compile time via the runtime collector, so this single list entry is the whole authoring moment (no `router.ex` edit, ever). Targets the six block-list plugins (tickets, quiz, pulse, tasks, bulldocs, github) through a **variable** `IN` path; sheets/onixedit refuse loud at anchor resolution. Head-insert is the house ordering law, not a compromise: history's own adds moved head-ward (`/tasks/prime` "must mount BEFORE `/tasks/:doc_id`"), so a new static path can never be shadowed by an existing dynamic catchall. `Method` is a `ONEOF` over the closed `http_verb` set (`:live` is a different tuple shape, out of scope by name); `AuthBucket` is open by design — add-plugin-bucket mints new tiers, and the host router silently drops unknown buckets until their wrapper lands. Guard = the tuple's method+path head, so a hand-authored duplicate route refuses injection. |

### The ensure law (D57)

An `ensure-*` command is `DIRECTION "add"` whose `ASLONG` guard keys on a **payload-body
substring a hand-edit would also produce** — the full import line, the full quoted noun
literal — **never** on the `MARK:` comment. Run-proven: guarded on the mark alone, the
engine injected a duplicate against a hand-planted import; guarded on the line, it skipped
clean. The corollaries are part of the contract: a human who typed the same line first
wins (the run is a no-op and writes **no receipt**), and a later `bp scaffy remove` exits
4 **expected** — scaffy never owned the line, so there is nothing it may retract. Guard
the **full** line: a bare prefix false-skips on `import Logger.Foo`. The law does not
extend to `MARK VIRTUAL` count-bumps, which stay receipt-owned.

## Grammar reference

The grammar is **D3 hardened by D12 (amendments A1–A5) and pinned by the Wave-2 rulings
(D20–D26)**. Every command in the corpus obeys all of it. The rules below are the
human-readable contract; the corpus is the normative source, and `bp scaffy validate`
(W2) is the same law as code.

### Core rules — D3(a)–(g)

**(a) Fenced targets.** Every multi-line anchor or target block is fenced with `::: … :::`,
never left bare. The fence is what lets a payload span lines without the parser guessing
where it ends.

```scaffy
IN "api/config/config.exs"
REPLACE
::: playground-reaper anchor :::
       {"* * * * *", Barkpark.Tenancy.Workers.PlaygroundReaper}
::: playground-reaper anchor :::
WITH
::: {{.worker-name}} cron :::
       {"* * * * *", Barkpark.Tenancy.Workers.PlaygroundReaper},
       # scaffy:add-oban-worker {{.WorkerName}} MARK:oban-cron-{{.worker-name}}
       {"{{.CronExpr}}", Barkpark.Workers.{{.WorkerName}}}
::: {{.worker-name}} cron :::
```

**(b) MARK on every mutating op.** Every op that mutates a file carries `MARK "NAME"`.
On the **first** run the op anchors *structurally* (against real text in the tree) and
plants the mark; on **later** runs it anchors *at the mark*. The mark is also the handle a
`remove` uses. No mark ⇒ not reversible, not idempotent. (A site where no mark can
physically be planted uses `MARK VIRTUAL` — see D24 below.)

```scaffy
IN "internal/pdrender/pdrender.go"
### Register {{.block-name}} in the DefaultRegistry block map
INSERT AFTER FIRST
::: registry head anchor :::
	r.blocks["heading"] = headingRenderer{ir: ir}
::: registry head anchor :::
WITH
::: {{.block-name}} registration :::
	// scaffy:add-block-type {{.BlockName}} MARK:go-registry-{{.block-name}}
	r.blocks["{{.block-name}}"] = {{.blockName}}Renderer{}
::: {{.block-name}} registration :::
MARK "go-registry-{{.block-name}}"
```

**(c) Guards derive from the payload.** By default the idempotency guard is *the text the op
itself writes*. You only reach for an explicit `ASLONG` when the payload isn't
self-identifying — and the guard **must match text the op writes**. Guarding on a quote
style or whitespace the op doesn't actually emit is the canonical failure: the guard never
matches, so the op re-inserts on every run.

```scaffy
# GOOD — the payload plants a MARK comment; that line IS the implicit guard:
#   // scaffy:add-block-type {{.BlockName}} MARK:go-registry-{{.block-name}}
# present ⇒ the op is already applied ⇒ skip.

# BAD — payload emits double quotes, guard expects single ⇒ never matches ⇒
# the op re-inserts on every run (the canonical quote-mismatch failure)
ASLONG FILE DONT CONTAIN "r.blocks['{{.block-name}}']"
```

**(d) Every token resolves to a declared `VARIABLE`.** No free-floating tokens. Casing is a
*spelling-as-transform*: the same variable renders in whatever case the target position
needs (see A1).

```scaffy
VARIABLE 1 "BlockName" TITLE "Name your block type" DESCRIPTION "…" EXAMPLES "Timeline"
# supplied as --var BlockName=Timeline, then:
# {{.BlockName}} → Timeline · {{.block-name}} → timeline · {{.blockName}} → timeline · {{.block_name}} → timeline
```

**(e) Shared payloads use `SNIPPET` / `USE`, never paste-twice.** A payload that appears in
two ops is defined once and referenced.

```scaffy
SNIPPET starter-div
::: starter-div :::
<div class="bp-{{.block-name}}">
::: starter-div :::
# … later ops reference it:  WITH USE starter-div
```

(No W1 command needed one — every payload appears exactly once. The rule exists so a
payload is never pasted twice when one does.)

**(f) Commands close with assertions.** Postconditions: `ASSERT FILE … CONTAINS` (and
`DONT CONTAIN` for removes), and where a real gate exists, `ASSERT CMD` invoking it. A green
apply then *means* the slice is wired and compiles.

```scaffy
ASSERT FILE "internal/pdrender/pdrender.go" CONTAINS "MARK:go-registry-{{.block-name}}"
ASSERT CMD "go test ./internal/pdrender/ -run Test{{.BlockName}}Renderer -count=1"
```

**(g) Path-position and URL-position tokens of the same variable must agree on casing.**
If a file path derives from `{{.worker_name}}` (snake) then the module inside it derives
from `{{.WorkerName}}` (Pascal) — the two spellings of one variable stay consistent, so the
generated slice never has a path/identifier mismatch.

### Amendments — D12 (A1–A5), binding on every W1 command

**A1 — snake_case is a first-class spelling.** Five canonical spellings-as-transforms of one
variable:

| Token | Case | Example (`WorkerName=SmokeReaper`) |
|---|---|---|
| `{{.WorkerName}}` | Pascal | `SmokeReaper` |
| `{{.worker-name}}` | kebab | `smoke-reaper` |
| `{{.workerName}}` | camel | `smokeReaper` |
| `{{.worker_name}}` | snake | `smoke_reaper` |
| `{{.WORKER_NAME}}` | SCREAMING | `SMOKE_REAPER` |

SCREAMING_SNAKE is the constant-name spelling JS, Rust and Python share
(`SMOKE_REAPER_PROJECTION` and friends); it joined the set after the four-joiner era
(first external consumer: gyldendal.no's create-widget const stems), rides **last** in the
collapse-precedence order so no pre-existing one-word resolution moves, and is **not** a
path-legal spelling (E-009 still admits only kebab and snake in path positions).

Elixir and Go **file paths derive via snake** (`lib/barkpark/workers/{{.worker_name}}.ex`).
Without a snake spelling, no Elixir or Go command could derive its own paths.

**A2 — gate tiers.** `ASSERT CMD` gains an optional `TIER ci` suffix. A command runs its
**LOCAL** asserts wherever it's applied; **`TIER ci`** asserts are deferred to CI (they're
too heavy or too unsafe to run on a dev box). See [Gate tiers](#gate-tiers) for the exact
proven-safe list.

```scaffy
ASSERT CMD "go test ./internal/pdrender/ -run Test{{.BlockName}}Renderer -count=1"
ASSERT CMD "cd api && mix test test/barkpark/workers/{{.worker_name}}_test.exs" TIER ci
```

**A3 — comma-list append is a fenced REPLACE of the last element.** When you append to a
comma-separated collection whose last element has **no trailing separator**, you can't bare-
`INSERT` after it — two adjacent terms with no comma is a parse error. Instead you **REPLACE
the last element** with itself + separator + the new element. (Positional `INSERT` still
keeps `FIRST`/`LAST`; the retired bare `ABOVE`/`AFTER`/`BEFORE INLINE` spellings are gone.)

```scaffy
# last element `{"* * * * *", PlaygroundReaper}` has no trailing comma —
# so re-emit it WITH a comma and append, don't insert a dangling tuple
REPLACE
::: playground-reaper anchor :::
       {"* * * * *", Barkpark.Tenancy.Workers.PlaygroundReaper}
::: playground-reaper anchor :::
WITH
::: {{.worker-name}} cron :::
       {"* * * * *", Barkpark.Tenancy.Workers.PlaygroundReaper},
       # scaffy:add-oban-worker {{.WorkerName}} MARK:oban-cron-{{.worker-name}}
       {"{{.CronExpr}}", Barkpark.Workers.{{.WorkerName}}}
::: {{.worker-name}} cron :::
```

**A4 — REPLACE guards are load-bearing.** When a `REPLACE` target survives as a *substring of
its own replacement* (as in A3 above — the old tuple is still present after the edit),
idempotency rests **entirely** on the guard. A `REPLACE` without a payload-derived guard is
a lint error. Anchor the ≥2nd run at the planted **MARK**, never at the now-mutated
structural target — since W2 that re-anchor is first-class syntax, the `REANCHOR` clause
(D21 below), and a self-consuming `REPLACE` without **both** a payload-derived `ASLONG`
**and** a `REANCHOR` is an error.

```scaffy
REPLACE … WITH …
MARK "oban-cron-{{.worker-name}}"
REANCHOR "oban-cron-"
# guard = text the op itself writes (the planted mark line), never the old target
ASLONG FILE DONT CONTAIN "# scaffy:add-oban-worker {{.WorkerName}} MARK:oban-cron-{{.worker-name}}"
```

**A5 — guard/assert hygiene: ASCII-only, brace-free.** Guards and asserts are ASCII-only and
drawn from a **brace-free region** of the payload. A token's closing `}}` may never sit
adjacent to a literal `}` in a guard or assert string — the `}}}` run is ambiguous to the
tokenizer.

```scaffy
# GOOD — the docs-card INDEX sweep puts the token one slot early, commas both sides
ASSERT FILE "docs/INDEX.md" CONTAINS ",{{.card-name}},tui"
# BAD — token flush against the brace-expansion's closing brace ⇒ '{{.card-name}}}',
# a }}} run the tokenizer cannot split
ASSERT FILE "docs/INDEX.md" CONTAINS "tui,{{.card-name}}}.md"
```

**FIRST / LAST pins (carried from D7).** Whenever a positional anchor could match twice,
the occurrence is pinned explicitly — `INSERT AFTER|BEFORE FIRST` / `INSERT AFTER|BEFORE
LAST` — so a human (and later the engine) applies it at exactly one unambiguous site. No
implicit "first match wins."

### Wave-2 rulings — D20–D26, the validator's law

Ratified on run-proofs (the matcher fork parsed against the real `config.exs`; the lint
dry-run ran over the live corpus). `bp scaffy validate` implements exactly these rules.

**D20 — the REPLACE matcher is byte-exact fenced-bytes.** The anchor matches **the exact
bytes between its fence lines**, wherever they occur in the file, and `REPLACE` swaps
**only those bytes** — never the enclosing line, never a widened region. The two rejected
alternatives both fail on the real tree: whole-line matching goes clean-miss on run 2
(sibling accretion becomes impossible), and substring-match-consume-the-whole-line
reproduces the recorded `config.exs` SyntaxError. Engine law (W3): at apply time the
anchor bytes must occur **exactly once** in the file — zero is a clean miss, two or more
is an ambiguity error, never a "first match wins."

**D21 — `REANCHOR "<mark-name-prefix>"`, the run-≥2 re-anchor.** Optional clause directly
after `MARK`, on `REPLACE` only. Semantics: when any planted `MARK:<prefix>…` exists in
the target file, the *effective anchor* is the **LAST planted mark block of that family**
(the mark comment line + its marked payload line(s)), and `WITH` re-emits that block +
separator + the new block; when no such mark exists (run 1), the fenced structural target
applies. This is how a comma-list append (A3) takes a *second* sibling: the first run
consumed the structural target into a longer line, so later runs key on the family's tail
mark — the only safe key (a naive "last similar tuple" tail-finder grabs unrelated
pre-existing entries). Lint: a self-consuming `REPLACE` (target survives as a substring of
its own payload) without **both** a payload-derived `ASLONG` **and** a `REANCHOR` is an
**error**.

```scaffy
MARK "cli-verb-{{.noun}}-{{.verb}}"   # this run's own mark (planted by the payload)
REANCHOR "cli-verb-"                  # run ≥2: anchor at the LAST planted cli-verb-* block
```

**D22 — `VARIABLE` annotations: `OPAQUE`, `SHAPE`, `SUCCESSOR`.** Optional structural
keywords between the variable's quoted name and `TITLE`:

- `OPAQUE` — the value is **never re-cased**. References use exactly **one** token
  spelling per file (any legal joiner-output of the declared name), and opaque tokens are
  exempt from path-casing lints. For literals: cron expressions, routes, prose, numerics.
- `SHAPE "ts14"` — the value must match a named shape from the validator's catalog.
  `ts14` = exactly 14 ASCII digits forming a real UTC `YYYYMMDDHHMMSS` calendar instant
  (the Ecto migration prefix).
- `SUCCESSOR "<SiblingName>"` — the value is the named sibling **plus one**. The validator
  lints the declared `EXAMPLES` pairs (Scaffy has no arithmetic — the +1 crosses as a
  declared pair, checked, never computed).
- `ONEOF "a", "b", …` — constrains the value to a **closed enum set** (added Wave-5, D56 —
  see the Wave-5 ruling below).

```scaffy
VARIABLE 1 "Ts" OPAQUE SHAPE "ts14" TITLE "Migration timestamp" …
VARIABLE 3 "CountAfter" OPAQUE SUCCESSOR "CountBefore" TITLE "Registry count after this run" …
```

Non-opaque (transform) variables resolve through **one shared word-list** — `_`, `-` and
case boundaries are equivalent — and the five deterministic joiners of A1. Not all five
spellings must appear in a file, but every spelling that *does* appear must be a joiner
output of the declared name.

**D23 — direction is declared, never inferred: `DIRECTION "add" | "remove"`.** Required
header field, directly after `VARIANT`. Polarity is textually undecidable (a correct
remove-side un-sweep `REPLACE` looks exactly like an add to any containment heuristic), so
the command states it. One direction-driven rule family follows: **add** ⇒ guards are
`ASLONG FILE DONT CONTAIN` (act while the planted text is absent); **remove** ⇒ guards are
positive `ASLONG FILE CONTAIN` (act only while the planted text is present), marks are
**consumed** rather than planted, and postconditions may assert `ABSENT`.

**D24 — `MARK VIRTUAL "name"`: the unplantable mark.** A plain `MARK "name"` **requires**
its planted text `MARK:<name>` to appear verbatim in the op's **own payload** — the
validator errors otherwise (this lint mechanically catches the W1 corpus's one real bug,
an op that promised a mark its payload never wrote). Where no mark can physically survive
(the corpus case: `docs/INDEX.md`'s brace-expansion line admits no comment syntax),
`MARK VIRTUAL` declares a **nominal handle with zero in-file bytes** — and *requires* an
`ASLONG` guard, because idempotency must rest somewhere. Mark uniqueness is pair-scoped:
unique within a file; cross-file reuse of a mark name is legal only between
`DIRECTION`-opposed commands (the add that plants it and the remove that consumes it).

**D25 — the ratified spellings.** First-class grammar, defined by example in the corpus:

| Spelling | Meaning |
|---|---|
| `REMOVE` | delete the fenced block byte-exactly, anchored at (and **consuming**) its `MARK` |
| `DELETE FILE IF PRESENT "path"` | delete a whole file; **requires** a content-distinguishing `ASLONG` (guard on text the paired add wrote — never delete a hand-authored file that merely shares the name) |
| `ASSERT FILE "path" EXISTS` / `ABSENT` | whole-file postconditions (the create / remove halves) |
| positive `ASLONG FILE CONTAIN` | the guard polarity of every remove-direction op (D23) |
| `SNIPPET` / `USE` | retained in the grammar with **zero corpus instances** — exercised by synthetic fixtures only |

**D26 — payload bytes are pinned.** A payload is **exactly the lines between the fence
lines, verbatim** — tabs, leading blanks and load-bearing blank lines included, each line
contributing its trailing newline. Fence lines are flush-left and are **never** part of
the payload. An empty fence (two adjacent fence lines) is zero lines ⇒ a **0-byte file**
(the `.gitkeep` case). `CREATE` implies `mkdir -p` — intermediate directories are created,
engine behaviour, not a lint.

### Wave-5 ruling — D56, `ONEOF` enum variables

Ratified this wave (charter D56): the first grammar primitive since the Wave-2 annotations.
A `VARIABLE` may declare a **closed set of legal values** as a fourth structural annotation,
alongside `OPAQUE` / `SHAPE` / `SUCCESSOR` (D22). Syntax is a comma-separated quoted list —
byte-for-byte the `EXAMPLES` list shape — placed between the quoted variable name and
`TITLE`:

```scaffy
VARIABLE 1 "Visibility" OPAQUE ONEOF "public", "private" TITLE "Visibility" DESCRIPTION "…" EXAMPLES "public"
VARIABLE 2 "Tier" ONEOF "element", "widget", "section" TITLE "Composition tier" DESCRIPTION "…" EXAMPLES "widget"
```

Motivating command: **`add-schema-type`** — pick a visibility (`public`|`private`) and a
composition tier (`element`|`widget`|`section`); free text there is a class of error the
grammar can now refuse rather than a mistake caught only at review. `ONEOF` composes with
every other annotation: `OPAQUE ONEOF` (verbatim member, path-casing exempt) and transform
`ONEOF` (the member still resolves through the five A1 joiners — `widget` → `Widget` /
`widget` / …) are both legal.

The constraint is enforced on **both halves of the D37 split**, exactly like `SHAPE`:

- **Runtime (`bp scaffy run`).** A `--var` value outside the declared set is a **usage
  error** (`VarError`, **exit 2**) — the same class as a `SHAPE` violation. The engine owns
  the live value; the message names the offending value and lists the legal members.
- **Lint (`bp scaffy validate`) — new rule `E-021`.** A declared `EXAMPLES` value that is
  **not** a member of the variable's `ONEOF` set reds at the `VARIABLE` line. This is the
  source-text half: it catches a mis-authored fixture before it ships, mirroring how
  `E-013`/`E-014`/`E-015` lint declared `EXAMPLES` for `SHAPE`/`SUCCESSOR`. `E-021` is an
  append-only addition to the catalog (`internal/scaffy/doc.go`), covered by one adversarial
  red fixture, `testdata/red/E-021-oneof-violation.scaffy`.

`bp scaffy fmt` needs **zero** changes: `joinFields` is keyword-agnostic, so a canonical
`ONEOF` line (the comma bound to the preceding member) is already a Format identity and
survives byte-exact and idempotent — pinned by a fixpoint test.

### Wave-6 ruling — `INSERT BEFORE FIRST|LAST`, the prepend primitive

Ratified from the D55 deferral under the no-fixture-no-primitive discipline, with
**add-canonical-marker** as the motivating fixture. The verb splices the fenced payload
directly **before** the pinned anchor occurrence; the anchor bytes survive untouched. Every
AFTER law carries over verb-generically — fenced target + `WITH` payload, mandatory `MARK`
(E-007) planted by the payload (E-008), payload-derived guards (E-006), FIRST/LAST
occurrence pins (at-least-once anchor policy, like AFTER — D20 exactly-once stays
`REPLACE`/`REMOVE`-only) — and `REANCHOR` stays `REPLACE`-only (P-005). A `remove` inverts
it exactly like an AFTER insert: the receipt's post-image is excised byte-exactly.

The deferral had priced this as ergonomics — "prepend above a surviving head" was
expressible as a self-consuming `REPLACE` re-emitting the head, so add-canonical-marker
shipped on that idiom. The ratify experiment run-proved it was a **latent defect**, not
ergonomics: E-005 *forces* a `REANCHOR` onto every self-consuming `REPLACE`, and for the
prepend idiom that clause is a corruption vector. Marking a **second, different-slug**
capability in the same file left the per-slug guard silent, so the planted
`MARK:canonical-` family hijacked the anchor and the splice either **aborted** (D33 tail
desync — `{`/`do`-terminal heads) or **silently corrupted** under a green report
(`}`-terminal one-liner heads: comma appended to real code + a duplicate bodyless head
planted). As a plain `INSERT BEFORE FIRST` the op is not self-consuming, carries no
`REANCHOR`, and the two-slug scenario is two independent clean inserts — pinned forever by
`TestCanonicalMarkerTwoSlugsOneFile`.

`bp scaffy fmt` again needs **zero** changes (keyword-agnostic `joinFields`, pinned by the
fmt golden); an unpinned `INSERT BEFORE` is P-002
(`testdata/red/P-002-insert-before-unpinned.scaffy`). Corpus census at ratification: 1
`INSERT BEFORE FIRST` (the canonical-marker plant), `REPLACE` 11→10 (now 3 — the
ensure-console-hook-zones plants above app.js's escape hatch and IIFE tail joined it,
2026-07-17; then 10→9 the same day when classify-block-type's self-consuming REPLACE
became an `INSERT AFTER FIRST` on the tiers.ex append-friendly restructure — the second
retirement of the idiom for the same reason: E-005's forced `REANCHOR` made the
two-sibling scenario refuse or corrupt, and a plain insert makes it two independent
clean applies); `INSERT BEFORE LAST` is grammar-legal with zero corpus instances, exercised
by synthetic fixtures (the `SNIPPET`/`USE` precedent).

## Gate tiers

`ASSERT CMD` is split into two tiers (A2). A **LOCAL** gate is proven safe to run on a dev
box; a **`TIER ci`** gate is deferred to CI because it's too heavy or too risky to run
locally (Elixir compiles the world; a partial build can wedge a dev machine).

| Tier | Gate | Notes |
|---|---|---|
| **LOCAL** | `go vet ./…` | fast, no side effects |
| **LOCAL** | `CC=/usr/bin/clang go build ./…` | `cc` is shadowed by a Claude wrapper — pin the real clang |
| **LOCAL** | `go test -run <Named> ./…` | scoped by name, never the whole suite |
| **LOCAL** | `cd js && pnpm install && pnpm build` | js workspace bootstrap — the proven precondition for the tsc + vitest gates in a fresh worktree (103 phantom errors → 0) |
| **LOCAL** | `npx tsc --noEmit` | JS SDK typecheck — needs the pnpm bootstrap above first |
| **LOCAL** | `npx eslint <file>` | scoped to the touched file |
| **LOCAL** | `npx vitest run` (react pkg) | the PortableDoc fixture + count assertion |
| **LOCAL** | `bash scripts/check-doc-budgets.sh` | 0.1s byte-gate for the doc spine |
| **LOCAL*** | `bash scripts/docs-anchors-check.sh` | **clean-checkout caveat** ↓ |
| **LOCAL**** | `CC=/usr/bin/clang mix test <single file>` | **warm-build caveat** ↓ — proven 2026-07-16 |
| **TIER ci** | `mix format --check-formatted` | Elixir compiles the world |
| **TIER ci** | *all other `mix …` gates* (full `mix test`, `mix phx.server`) | same — full suite OOMs locally |

**\* `docs-anchors-check.sh` clean-checkout caveat.** It's LOCAL-safe *only in a fresh
worktree* — there it runs green in ~24s. In the litter-saturated primary checkout (many live
worktrees, stray files) it hangs past 115s scanning the tree. A command that asserts it must
say so in the command text: run it in a clean checkout, or defer to CI.

**\*\* scoped `mix test` warm-build caveat (A2's open half, resolved 2026-07-16).** A
*single-file* `CC=/usr/bin/clang mix test test/…_test.exs` is LOCAL-safe **with a warm
`api/_build`** — proven: `plugins/media_test.exs` green in 9.0s wall,
`plugins/cli_commands_manifest_test.exs` in 2s, no OOM. What OOMs is the FULL suite (and
`mix phx.server` boot). In a cold fresh worktree the first run pays a full compile
(`_build` cannot be borrowed across worktrees) — budget minutes for it or run the scoped
test from a warm checkout.

## Hand-applying a command today

Before the W3 engine shipped, a Scaffy command was applied **by hand** — and the grammar is
designed so that's unambiguous (D7). To apply `scaffy/commands/<name>.scaffy`:

1. **Bind the variables.** Read the `VARIABLE` declarations at the top and pick your values
   (`--var BlockName=timeline`). Expand every `{{.…}}` token through its five spellings (A1):
   Pascal / kebab / camel / snake / SCREAMING.
2. **Do the CREATEs (`●`).** For each `CREATE FILE`, write the file with tokens expanded. These
   are the new-file half — the part a plain generator could also do.
3. **Do the INJECTs (`○`) in order.** For each mutating op, open the `IN` file, find the
   fenced structural anchor **at the pinned occurrence** (`FIRST`/`LAST`), and apply the
   `INSERT` / `REPLACE` — swapping **exactly the anchor bytes** (D20), never the whole line.
   The payload plants its own `MARK:<name>` comment at the site so the edit is findable
   again (that's what a future `remove` and a re-run will key on). If the op carries
   `REANCHOR` and a mark of that family is already planted, anchor at the **last** planted
   mark block instead of the structural target (D21). A `MARK VIRTUAL` op plants nothing —
   its `ASLONG` guard is the whole handle (D24).
4. **Check the guards.** Before each injection, confirm the guard per the command's
   `DIRECTION` (D23): on an **add**, the `DONT CONTAIN` text must be absent — if present,
   the op is already applied; skip it. On a **remove**, the positive `CONTAIN` text must be
   present — if absent, there is nothing to remove; skip it. That's the idempotency
   contract you're enforcing by hand.
5. **Run the asserts.** Execute every `ASSERT FILE … CONTAINS` (grep) and every **LOCAL**
   `ASSERT CMD`. Defer `TIER ci` asserts to the PR. A command whose LOCAL asserts pass is
   correctly applied.
6. **To reverse** (e.g. the docs-card scratch demo): find each `MARK`, delete the marked
   region, delete the created files, and confirm with the command's `ASSERT FILE … DONT
   CONTAIN` postconditions that the tree is byte-clean.

Because every anchor in the corpus is verified against the live tree with `file:line` + quoted
context, and every occurrence is pinned, a reviewer can apply any command deterministically —
which is exactly the property the W3 engine now automates (`bp scaffy run`).
