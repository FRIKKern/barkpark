ARCHIVED — do not load; facts moved to docs/cli/m0-decisions.md
# Implementation Contract — `cli_commands/0` plugin callback + `collect_cli_commands/1` collector

> **Status:** M0 contract for Wave 2 to follow. This specifies the new plugin
> callback that lets a plugin contribute ergonomic CLI verbs (e.g. bulldocs
> `publish`, `patch`) into the `/v1/capabilities` manifest with **zero host edits**.
> Every returned command must conform to the frozen `commands[]` per-command shape
> in `manifest.schema.json`.

## 0 · What this adds and why

The capabilities manifest's `commands[]` array is the single CLI contract. Core
verbs are hand-maintained; plugin verbs arrive via a new additive callback,
`cli_commands/0`, lifted by `resolve_cli_commands/2`, collected by
`collect_cli_commands/1`, and folded into `commands[]` (tagged provenance) by the
`/v1/capabilities` controller. It clones the existing `api_tests` machinery
verbatim-style — the cleanest additive precedent in the registry.

```
plugin: cli_commands/0  ──lift──▶  resolve_cli_commands/2  ──reduce──▶  collect_cli_commands/1
                                                                              │
   Registry.all/0 ─┐                                                         ▼
   collect_routes/1 ┼──▶ /v1/capabilities controller ──▶ commands[] (auth-tier projected)
   collect_cli_commands/1 ─┘
```

## 1 · The `@callback` and its return shape

### Signature (add to `plugin.ex`, alongside the additive callbacks)

`cli_commands/0` slots in next to `api_tests/0` (the additive callback at
`plugin.ex:609`). Add both the additive declaration and its resolver:

```elixir
@callback cli_commands() :: [cli_command()]
```

…and, alongside the resolver declarations (the `resolve_*` block near
`resolve_api_tests/2` at `plugin.ex:513–516`):

```elixir
@callback resolve_cli_commands(prev :: [cli_command()], ctx :: map()) :: [cli_command()]
```

### Return shape — `cli_command()`

`cli_commands/0` returns a **list of command maps**, each one matching the
frozen `commands[]` per-command schema in `manifest.schema.json` exactly. The CLI
wires no per-verb code; it builds the leaf entirely from these fields. Define the
type alongside the other plugin types:

```elixir
@type cli_command() :: %{
        required(:id) => String.t(),               # stable "<noun>.<verb>" id (e.g. "bulldocs.publish")
        required(:noun) => String.t(),             # matches a nouns[].name
        required(:verb) => String.t(),             # action token (e.g. "publish")
        required(:summary) => String.t(),
        required(:http) => %{                       # the single API call
          required(:method) => String.t(),         # GET | POST | PUT | PATCH | DELETE
          required(:path_template) => String.t()   # FLAT template, e.g. "/v1/plugins/bulldocs/papers"
        },
        required(:auth_tier) => String.t(),        # none|read|write|admin|scoped_admin|ingest
        required(:args) => [%{                      # positional args, declaration order
          required(:name) => String.t(),
          required(:required) => boolean(),
          required(:type) => String.t(),
          required(:summary) => String.t()
        }],
        required(:flags) => [%{                      # command-local flags
          required(:name) => String.t(),
          required(:type) => String.t(),
          required(:summary) => String.t(),
          optional(:default) => term(),
          optional(:repeatable) => boolean()
        }],
        required(:writes) => boolean(),
        required(:batch) => boolean(),
        required(:paginated) => boolean(),
        required(:dry_run) => boolean(),            # HONEST: false unless server validate-only exists
        required(:default_output) => String.t(),    # table|json|yaml|minimal
        optional(:scoped_prefix) => String.t() | nil
      }
```

> **Field names are load-bearing.** They must be the frozen `manifest.schema.json`
> names verbatim — `id`, `noun`, `verb`, `summary`, `http` (`method`,
> `path_template`), `auth_tier`, `args`, `flags`, `writes`, `batch`, `paginated`,
> `dry_run`, `default_output`, `scoped_prefix`. The controller folds these
> straight into `commands[]`; a renamed key fails the manifest's
> `additionalProperties:false` golden test.

The host stamps **provenance** (`source: "plugin:<name>"`) — see §3. Plugins do
not set `source` themselves; the controller derives it from the owning plugin's
manifest `plugin_name` during the fold.

### Example (bulldocs `publish`)

```elixir
%{
  id: "bulldocs.publish",
  noun: "bulldocs",
  verb: "publish",
  summary: "Publish a paper from a portable-doc payload.",
  http: %{method: "POST", path_template: "/v1/plugins/bulldocs/papers"},
  auth_tier: "ingest",
  args: [%{name: "slug", required: true, type: "slug", summary: "Paper slug."}],
  flags: [%{name: "file", type: "file", summary: "Payload from file or - for stdin."}],
  writes: true,
  batch: false,
  paginated: false,
  dry_run: false,
  default_output: "minimal",
  scoped_prefix: nil
}
```

## 2 · Where it slots in `plugin.ex` — the five edit sites

All line numbers are current as of M0 (verified against
`api/lib/barkpark/plugin.ex`). The pattern is identical to `api_tests`/
`resolve_api_tests`.

| # | Site | Anchor (line) | Edit |
|---|---|---|---|
| 1 | `@callback` (additive) | near `api_tests/0` (`609`) and the resolver block (`513–516`) | Add `@callback cli_commands() :: [cli_command()]` and `@callback resolve_cli_commands(prev, ctx) :: [cli_command()]`. |
| 2 | `@optional_callbacks` | `611–634` | Append `cli_commands: 0, resolve_cli_commands: 2`. (Add a trailing comma to the current last entry `test_connection: 1` on line `634`, then add the two new lines.) `manifest/0` stays the only NON-optional callback. |
| 3 | `__using__` default impls | model on `def api_tests, do: []` (`777–778`) | Add `@impl Barkpark.Plugin` + `def cli_commands, do: []`. |
| 4 | `__using__` resolver default | model **verbatim** on `resolve_checkers/2` (`700–708`, the canonical list-concat lift) | Add `@impl Barkpark.Plugin` + `def resolve_cli_commands(prev, _ctx)` that calls the additive form via `function_exported?/3` and `prev ++ result` when the result is a list, else `prev`. |
| 5 | `defoverridable` | `803–827` | Append `cli_commands: 0, resolve_cli_commands: 2`. |

The resolver default (site 4), cloned from `resolve_checkers/2`:

```elixir
@impl Barkpark.Plugin
def resolve_cli_commands(prev, _ctx) do
  if function_exported?(__MODULE__, :cli_commands, 0) do
    result = __MODULE__.cli_commands()
    if is_list(result), do: prev ++ result, else: prev
  else
    prev
  end
end
```

This is the **additive-lift** pattern: a plugin that exports only the additive
`cli_commands/0` gets its list concatenated onto `prev`; a plugin wanting to
filter/reorder sibling-plugin commands overrides `resolve_cli_commands/2`
directly.

## 3 · The `registry.ex` change

### 3a · `@resolver_callbacks` row (registry.ex `94–104`)

Add the metadata row so `reduce_resolvers/3` knows how to lift the additive form
and `warn_duplicate_forms/0` can dedupe it. Tuple shape is
`{additive_name, additive_arity, additive_default, lift_kind}`:

```elixir
resolve_cli_commands: {:cli_commands, 0, [], :list_concat}
```

(List-shaped, `[]` baseline, list-concat lift — identical to
`resolve_api_tests: {:api_tests, 0, [], :list_concat}` on line `103`.)

### 3b · `collect_cli_commands/1` wrapper (clone of `collect_api_tests/1`)

Add a collector modeled **verbatim-style** on `collect_api_tests/1`
(registry.ex `360–382`) — the minimal, **uncached** template (an admin-triggered
/ request-time read, not a hot path, so it deliberately skips the
`:persistent_term` snapshot that the cached collectors consult):

```elixir
@spec collect_cli_commands(keyword()) :: [Barkpark.Plugin.cli_command()]
def collect_cli_commands(opts \\ []) do
  baseline = Keyword.get(opts, :baseline, [])
  ctx = Keyword.get(opts, :ctx, %{})
  reduce_resolvers(:resolve_cli_commands, baseline, ctx)
end
```

- `baseline` defaults to `[]` (list-shaped, matching the lift kind). The host MAY
  seed the core CLI verbs via `:baseline` so plugins can drop/reorder them
  symmetric with how `collect_api_tests/1` lets the host seed built-in smoke
  tests.
- `ctx` defaults to `%{}`.
- Delegates to `reduce_resolvers(:resolve_cli_commands, baseline, ctx)`, which
  folds `baseline` through every registered plugin in load order
  (`load_ordered_plugins/0`) and applies each plugin's resolver (or lifts its
  additive form). Per-plugin failures isolate to `prev` — one bad plugin cannot
  break the manifest.

## 4 · How `/v1/capabilities` folds it into the manifest

The capabilities controller assembles the manifest at request time from three
registry inputs and applies the auth-tier existence-hiding projection:

```
Registry.all/0           ──▶ plugin set {module, manifest, name}  ──▶ nouns[] (+ core nouns)
Registry.collect_routes/1 ──▶ mounted route specs (provenance / path sanity)
Registry.collect_cli_commands/1 ──▶ plugin CLI verbs (additive list)
hand-maintained core verbs ──▶ core commands[]
                         │
                         ▼
        merge → stamp source → PROJECT through caller auth_tier → commands[]
```

Concrete steps:

1. **Nouns.** From `Registry.all/0` (`%{module, manifest, name}` entries), derive
   one `nouns[]` entry per plugin that contributes commands, `plugin: <name>`;
   merge with the core nouns (`plugin: null`). `name`/`summary` required per the
   noun schema.
2. **Commands.** Concatenate the hand-maintained **core** commands with
   `collect_cli_commands/1`'s plugin commands. Stamp each plugin command's
   provenance — the controller derives `source: "plugin:<name>"` from the owning
   plugin's `plugin_name` (plugins do not self-declare `source`). `collect_routes/1`
   is folded in as a cross-check that each command's `http.path_template`
   corresponds to a real mounted route.
3. **Existence-hiding projection (contract rule #1).** Project BOTH `nouns[]` and
   `commands[]` through ONE default-deny allow-list keyed on the **caller's**
   resolved `auth_tier` (the manifest's top-level `auth_tier` echo). A command is
   visible only if the caller's tier may invoke its required `auth_tier`. An
   anonymous (`none`) caller sees zero `admin`/`scoped_admin`/`ingest` commands
   and zero admin noun names — they don't even learn the routes exist.
   - **`scoped_admin` caveat (contract rule #2):** the projection must NOT hide a
     `scoped_admin` command from a token that *might* hold a per-workspace role —
     only the server knows the caller's per-workspace role at request time. Treat
     `scoped_admin` visibility per the projection's role-aware branch, never a
     blanket client-side deny.
4. **ETag varies by tier.** Because the projected `commands[]`/`nouns[]` differ
   per tier, the `etag` is content-addressed over the projected document — an
   admin manifest and a public manifest carry different etags (drives `304` +
   tier-keyed on-disk cache).
5. **Honest `dry_run`.** Every folded command ships `dry_run: false` in v1 unless
   the server genuinely supports validate-only for it (contract rule #5).

## 5 · Verification checklist for Wave 2

- [ ] `plugin.ex`: 5 edit sites done (§2); compiles; `bash -n` n/a (Elixir) — run
      `mix compile` clean.
- [ ] `registry.ex`: `@resolver_callbacks` row added (§3a); `collect_cli_commands/1`
      added (§3b); `warn_duplicate_forms/0` recognizes the new pair (a plugin
      defining BOTH `cli_commands/0` and `resolve_cli_commands/2` is warned).
- [ ] A plugin exporting only `cli_commands/0` has its list concatenated into
      `collect_cli_commands/1` output.
- [ ] Each returned command validates against `manifest.schema.json` `commands[]`
      (required keys present; `additionalProperties:false` holds; `auth_tier` ∈ the
      6-value enum; `default_output` ∈ the 4-value enum; `http.method` ∈ the verb
      enum).
- [ ] `/v1/capabilities` existence-hiding golden test: anonymous caller sees no
      `ingest`/`admin`/`scoped_admin` plugin commands; `scoped_admin` is not
      blanket-hidden from a role-bearing token.

## Schema field references

This contract is bound to `manifest.schema.json`: the `cli_command()` return type
mirrors the frozen `commands[]` per-command object field-for-field — `id`, `noun`,
`verb`, `summary`, `http{method, path_template}`, `auth_tier`, `args`, `flags`,
`writes`, `batch`, `paginated`, `dry_run`, `default_output`, `scoped_prefix` —
and the controller projects through the same `auth_tier` enum
(`none|read|write|admin|scoped_admin|ingest`) and `default_output` enum
(`table|json|yaml|minimal`) the schema fixes.