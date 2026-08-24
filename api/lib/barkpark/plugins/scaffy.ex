defmodule Barkpark.Plugins.Scaffy do
  @moduledoc """
  Scaffy — commands as content, as a first-party plugin.

  Scaffy is the epic that makes scaffolding executable and served: a command is
  a `.scaffy` file (a declarative, idempotent, reversible scaffolding document),
  and the engine (`internal/scaffy` + `bp scaffy validate/fmt/run/remove`) is
  shipped and live. This module is the plugin that turns a command into a
  first-class Barkpark document type — so a connected repo pulls its scaffolding
  over one connect, exactly like Papers and Tasks. Charter:
  `.claude/workflows/bp-scaffy-charter.md` (decisions D44–D46).

  ## What this module contributes

    * `register_schemas/1` — the `command` document type (read from
      `priv/plugins/scaffy/schemas/command.json`). Auto-registers on every boot
      via `Barkpark.Plugins.Bootstrap.register_all_schemas/0`, idempotent on
      `(name, dataset)`.

  `capabilities: ["schemas"]` **only** — zero routes. The generic query
  endpoint (`GET /v1/data/query/:dataset/command`) serves every registered
  public schema, and the Studio editor renders `command` through the shared
  `studio_editor_shell`; there is no bespoke Scaffy API and no new LiveView.

  ## The command shape (D45/D46)

  The `.scaffy` source rides **verbatim** in one content string field, `source`
  (schema field type `"source"`) — the `.scaffy` file IS the truth, never a
  lossy block decomposition. `BarkparkWeb.Components.FieldInputs` renders
  `"source"` read-only in a monospace `<pre>` and emits no form input, so a
  Studio save preserves the bytes byte-identically (the field is absent from the
  submitted params → `Content.classic_save_content/4` keeps the stored value).

  Label-spine metadata is queryable — `concept`/`variant`/`domain`/`direction`
  as plain strings, plus weighted `tags` (arrayOf composite
  `{tag,strength,rationale}`, hand-copied from the paper schema: no reusable
  weighted-tags field type exists). `visibility: "public"` gives tokenless reads
  so one connect is zero tokens for `bp scaffy pull` / `ls --remote`.

  Mirrors `Barkpark.Plugins.Bulldocs` (the paper schema plugin) — thin wiring
  that declares a public document type from its bundled JSON.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/scaffy/plugin.json"

  alias Barkpark.Content.SchemaDefinition

  # Resolved at RUNTIME, deliberately not frozen into an attribute.
  # `Application.app_dir/2` finds priv under BOTH deploy models: the source-tree
  # one (Barkpark compiles + runs in place under /opt/barkpark, where Mix
  # symlinks _build/<env>/lib/barkpark/priv at ./priv) and an OTP release, where
  # priv lives at lib/barkpark-<vsn>/priv. The previous
  # `Path.expand("../../../priv/...", __DIR__)` attribute served only the first:
  # it froze the BUILD machine's absolute path, so every released build raised
  # File.Error enoent here and this plugin's schemas never registered.
  # Precedent: the plugin loader already resolves priv this way — see
  # registry/discovery.ex default_paths/0.
  @schemas_subdir "priv/plugins/scaffy/schemas"
  defp schemas_dir, do: Application.app_dir(:barkpark, @schemas_subdir)

  @doc """
  Declares the `command` document type from `schemas/command.json`. Public
  visibility (tokenless reads), `production` dataset. Bootstrap upserts on
  `(name, dataset)`, so re-registration on every boot never drifts the row.
  """
  @impl Barkpark.Plugin
  # Reachability: the only path read is the runtime-resolved schemas dir joined
  # with a compile-time literal filename — no runtime input reaches `File.read!/1`.
  # Inline rather than a `.sobelow-skips` row on purpose: a baseline entry is
  # pinned to a LINE, so any edit above the call silently kills the waiver and the
  # finding returns as new. The annotation binds by AST adjacency and survives moves.
  # sobelow_skip ["Traversal.FileModule"]
  def register_schemas(_opts) do
    raw =
      schemas_dir()
      |> Path.join("command.json")
      |> File.read!()
      |> Jason.decode!()

    [
      %SchemaDefinition{
        name: Map.fetch!(raw, "name"),
        title: Map.get(raw, "title"),
        icon: Map.get(raw, "icon"),
        visibility: Map.get(raw, "visibility", "public"),
        fields: Map.get(raw, "fields", []),
        dataset: "production"
      }
    ]
  end
end
