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

## Status — corpus first, no engine yet

Wave 1 ships the **command corpus + showcase**, deliberately **without an engine**. These
are full-text, copy-ready `.scaffy` documents — never sketches, never elided `…` bodies —
that a human can hand-apply *today* (see [Hand-applying a command today](#hand-applying-a-command-today)).
They also *are* the specification: the corpus defines the hardened v2 grammar by example,
and it becomes the parser's test fixtures in the next wave.

| Wave | Ships | State |
|---|---|---|
| **W1** — corpus + showcase | 7 full `.scaffy` commands, this README, the showcase paper | **this wave** |
| **W2** — parser + validator | `bp scaffy validate` / `bp scaffy fmt` in Go: the grammar as code — strict tokens, derived-guard check, weak-guard lint, casing-consistency lint | next |
| **W3** — engine | `bp scaffy run` / `bp scaffy remove`: apply with marks + receipts (`.scaffy/receipts/`), dry-run diff, idempotent re-run, symmetric remove | planned |
| **W4** — commands as content | a `command` document type, Studio authoring, a catalog per concept×variant, `bp add <concept>` fetching from the connected Barkpark | planned |

## The command corpus

Seven commands, each covering a thing Barkpark development actually repeats. Every command
lives at `scaffy/commands/<name>.scaffy`.

| Command | What it does |
|---|---|
| **add-block-type** | Flagship. Scaffolds a new PortableDoc block across **3 code surfaces** — Go renderer + `DefaultRegistry` map entry, an Elixir `compose_block/2` clause before the catch-all, and the JS fail-closed 4-edit (emitter fn + `coreEmitters` entry + `CASES` fixture + `toHaveLength` count bump) — plus optional CSS/classification. Parity at birth. |
| **add-oban-worker** | Creates a worker module + its test under `lib/barkpark/workers/`, then injects a `{"* * * * *", Worker}` tuple into the `Oban.Plugins.Cron` crontab in `api/config/config.exs`. `:default` queue only. |
| **add-cli-verb** | Appends one entry to a plugin's `cli_commands/0` list — a manifest-driven CLI verb with **zero Go**. Showcases "the architecture already made this a one-liner." |
| **add-migration** | Creates a timestamped Ecto migration under `api/priv/repo/migrations/`. The 14-digit timestamp is a declared `VARIABLE` (commands have no clock) and drives the D3(d)/A1 module-name transform. |
| **add-plugin** | All-CREATE, zero-inject: `plugin.json` + `README.md` + `schemas/.gitkeep` + a one-line `use Barkpark.Plugin` module + a test — the live `mix barkpark.plugin.new` templates, formalized. `discover_and_register/0` auto-collects the rest. |
| **add-docs-card** | Creates a routing-table row in `CLAUDE.md` + a card file with a `doc-tier` header. The 7-card cap makes it a *scratch demo* today — it can only land paired with a remove. |
| **remove-docs-card** | The symmetry partner: removes the row, the card file and the `docs/INDEX.md` brace-expansion mention, leaving the tree byte-clean. Proves every mutating op is reversible from its `MARK`. |

## Grammar reference

The grammar is **D3 hardened by D12 (amendments A1–A5)**. Every W1 command obeys all of it.
The rules below are the human-readable contract; the corpus is the normative source.

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
       {"{{.CronExpr}}", Barkpark.Workers.{{.WorkerName}}}
::: {{.worker-name}} cron :::
```

**(b) MARK on every mutating op.** Every op that mutates a file carries `MARK "NAME"`.
On the **first** run the op anchors *structurally* (against real text in the tree) and
plants the mark; on **later** runs it anchors *at the mark*. The mark is also the handle a
`remove` uses. No mark ⇒ not reversible, not idempotent.

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

**A1 — snake_case is a first-class spelling.** Four canonical spellings-as-transforms of one
variable:

| Token | Case | Example (`WorkerName=SmokeReaper`) |
|---|---|---|
| `{{.WorkerName}}` | Pascal | `SmokeReaper` |
| `{{.worker-name}}` | kebab | `smoke-reaper` |
| `{{.workerName}}` | camel | `smokeReaper` |
| `{{.worker_name}}` | snake | `smoke_reaper` |

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
structural target.

```scaffy
REPLACE … WITH …
MARK "oban-cron-{{.worker-name}}"
# guard = text the op itself writes (the planted mark line), never the old target
ASLONG FILE DONT CONTAIN "MARK:oban-cron-{{.worker-name}}"
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
the occurrence is pinned explicitly — `INSERT AFTER FIRST` / `INSERT AFTER LAST` — so a
human (and later the engine) applies it at exactly one unambiguous site. No implicit
"first match wins."

## Gate tiers

`ASSERT CMD` is split into two tiers (A2). A **LOCAL** gate is proven safe to run on a dev
box; a **`TIER ci`** gate is deferred to CI because it's too heavy or too risky to run
locally (Elixir compiles the world; a partial build can wedge a dev machine).

| Tier | Gate | Notes |
|---|---|---|
| **LOCAL** | `go vet ./…` | fast, no side effects |
| **LOCAL** | `CC=/usr/bin/clang go build ./…` | `cc` is shadowed by a Claude wrapper — pin the real clang |
| **LOCAL** | `go test -run <Named> ./…` | scoped by name, never the whole suite |
| **LOCAL** | `npx tsc --noEmit` | JS SDK typecheck |
| **LOCAL** | `npx eslint <file>` | scoped to the touched file |
| **LOCAL** | `npx vitest run` (react pkg) | the PortableDoc fixture + count assertion |
| **LOCAL** | `bash scripts/check-doc-budgets.sh` | 0.1s byte-gate for the doc spine |
| **LOCAL*** | `bash scripts/docs-anchors-check.sh` | **clean-checkout caveat** ↓ |
| **TIER ci** | `mix test <file>` | Elixir compiles the world — CI only until a scoped local proof lands |
| **TIER ci** | `mix format --check-formatted` | same |
| **TIER ci** | *all other `mix …` gates* | same |

**\* `docs-anchors-check.sh` clean-checkout caveat.** It's LOCAL-safe *only in a fresh
worktree* — there it runs green in ~24s. In the litter-saturated primary checkout (many live
worktrees, stray files) it hangs past 115s scanning the tree. A command that asserts it must
say so in the command text: run it in a clean checkout, or defer to CI.

## Hand-applying a command today

No engine exists yet (W3), so a Scaffy command is applied **by hand** — and the grammar is
designed so that's unambiguous (D7). To apply `scaffy/commands/<name>.scaffy`:

1. **Bind the variables.** Read the `VARIABLE` declarations at the top and pick your values
   (`--var BlockName=timeline`). Expand every `{{.…}}` token through its four spellings (A1):
   Pascal / kebab / camel / snake.
2. **Do the CREATEs (`●`).** For each `CREATE FILE`, write the file with tokens expanded. These
   are the new-file half — the part a plain generator could also do.
3. **Do the INJECTs (`○`) in order.** For each mutating op, open the `IN` file, find the
   fenced structural anchor **at the pinned occurrence** (`FIRST`/`LAST`), and apply the
   `INSERT` / `REPLACE`. The payload plants its own `MARK:<name>` comment at the site so the
   edit is findable again (that's what a future `remove` and a re-run will key on).
4. **Check the guards.** Before each injection, confirm the guard text (payload-derived, A3/A4)
   isn't already present — if it is, the op is already applied; skip it. That's the
   idempotency contract you're enforcing by hand.
5. **Run the asserts.** Execute every `ASSERT FILE … CONTAINS` (grep) and every **LOCAL**
   `ASSERT CMD`. Defer `TIER ci` asserts to the PR. A command whose LOCAL asserts pass is
   correctly applied.
6. **To reverse** (e.g. the docs-card scratch demo): find each `MARK`, delete the marked
   region, delete the created files, and confirm with the command's `ASSERT FILE … DONT
   CONTAIN` postconditions that the tree is byte-clean.

Because every anchor in the corpus is verified against the live tree with `file:line` + quoted
context, and every occurrence is pinned, a reviewer can apply any command deterministically —
which is exactly the property the W3 engine will automate.
