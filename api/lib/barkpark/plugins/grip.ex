defmodule Barkpark.Plugins.Grip do
  @moduledoc """
  Grip — the source-of-truth grip layer as content, as a first-party plugin.

  Every wrong value the truth-grip epic set out to abolish was a **level-skip**:
  reading at one authority level and claiming at a higher one. `tooling/grip`
  made that structurally impossible for facts written through its own Node
  write path. This plugin closes the other door — the one every agent already
  has, and the only one the Studio and `bp doc` know about: writing a fact
  straight into Barkpark as a document.

  ## What this module contributes

    * `register_schemas/1` — the `fact` document type (read from
      `priv/plugins/grip/schemas/fact.json`). Auto-registers on every boot via
      `Barkpark.Plugins.Bootstrap.register_all_schemas/0`, idempotent on
      `(name, dataset)`.
    * `lifecycle_hooks/0` — ONE `before_publish` gate,
      `reject_level_skipping_fact/1`. A `type:fact` document may not publish
      when its `rerun` command fails the fail-closed screen, or when the
      `level` it claims sits ABOVE the level that command derives.

  `capabilities: ["schemas"]` only — zero routes. The generic query endpoint
  serves the type and the Studio editor renders it through the shared editor
  shell, exactly as `Barkpark.Plugins.Scaffy` does for `command`.

  ## Why a hook and not a schema rule

  Schema-v2's cross-field `validations:` slot is parsed but INERT:
  `docs/contracts/schema-v2.md` defers evaluation to Phase 3, and
  `api/test/barkpark/content/validation_test.exs`'s
  `validates_validations_slot_is_inert_in_phase_0` asserts `{:ok, content}`
  even for content that violates a declared rule. A `validations:` entry
  expressing "level must not exceed the level derived from rerun" would
  therefore be dead text today — it would announce a gate that never fires,
  which is worse than no gate. The `before_publish` seam is live, is fired by
  `Barkpark.Content.Lifecycle.publish_document/5`, and already carries two
  shipped halt-capable exemplars this hook is modelled on:
  `Barkpark.Plugins.Tasks.portable_brief_gate/1` and
  `Barkpark.Plugins.Bulldocs.reject_hollow_paper_publish/1`.

  ## Publish, not save — and why that is the right door

  Both exemplars wall PUBLISH and leave draft authoring free, and this follows
  them. A fact is drafted before it is measured: an author writes the subject
  and the claim, then runs the command and pastes the result. Gating
  `before_save` would make an in-progress fact unsaveable, so the honest path
  would stop being the cheap one — the thing charter D3 exists to prevent.
  Publication is where a fact becomes citable, so publication is the wall.

  The grammar itself lives in `Barkpark.Plugins.Grip.Rerun`, which documents
  what it is a port of and where it knowingly diverges.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/grip/plugin.json"

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.Grip.Rerun

  # Resolved at RUNTIME, deliberately not frozen into an attribute.
  # `Application.app_dir/2` finds priv under BOTH deploy models: the source-tree
  # one (Barkpark compiles + runs in place under /opt/barkpark, where Mix
  # symlinks _build/<env>/lib/barkpark/priv at ./priv) and an OTP release, where
  # priv lives at lib/barkpark-<vsn>/priv. A `Path.expand("../../../priv/...",
  # __DIR__)` attribute serves only the first: it freezes the BUILD machine's
  # absolute path, so every released build raises File.Error enoent and the
  # plugin's schemas never register.
  @schemas_subdir "priv/plugins/grip/schemas"
  defp schemas_dir, do: Application.app_dir(:barkpark, @schemas_subdir)

  @doc """
  Declares the `fact` document type from `schemas/fact.json`.

  `visibility` is read from the JSON with a `"private"` default — an ALLOWLIST,
  not a denylist, matching the five sibling loaders (`bulldocs.ex`,
  `onixedit.ex`, `media.ex`, `sheets.ex`, `scaffy.ex`) and the ruling at
  `plugins/indx/indexer_worker.ex` `schema_public?/1`, so a dropped key or a
  typo fails CLOSED rather than exposing the evidence ledger anonymously.
  """
  @impl Barkpark.Plugin
  # Reachability: the only path read is the runtime-resolved schemas dir joined
  # with a compile-time literal filename — no runtime input reaches `File.read!/1`.
  # Inline rather than a `.sobelow-skips` row on purpose: a baseline entry is
  # pinned to a LINE, so any edit above the call silently kills the waiver and
  # the finding returns as new. The annotation binds by AST adjacency and
  # survives line moves.
  # sobelow_skip ["Traversal.FileModule"]
  def register_schemas(_opts) do
    raw =
      schemas_dir()
      |> Path.join("fact.json")
      |> File.read!()
      |> Jason.decode!()

    [
      %SchemaDefinition{
        name: Map.fetch!(raw, "name"),
        title: Map.get(raw, "title"),
        icon: Map.get(raw, "icon"),
        visibility: Map.get(raw, "visibility", "private"),
        fields: Map.get(raw, "fields", []),
        dataset: "production"
      }
    ]
  end

  @doc """
  ONE `before_publish` hook. Non-fact documents pass untouched, so with this
  plugin loaded nothing else on the write path changes.
  """
  @impl Barkpark.Plugin
  def lifecycle_hooks do
    %{before_publish: [&reject_level_skipping_fact/1]}
  end

  # THE PUBLISH WALL. A fact publishes only when BOTH doors open:
  #
  #   1. the screen admits the `rerun` string (it is a re-derivable command at
  #      all — fail-closed, so an unclassifiable head is refused), and
  #   2. the claimed `level` is at or below the level that command DERIVES.
  #
  # The order is load-bearing: the screen runs first so the ladder never
  # levels a string that is not a command. That composition is what lets the
  # ladder stay a faithful port while the screen stays a subset — prose with a
  # blessed head is stopped by the screen before it can inherit that head's
  # authority.
  #
  # The payload doc is whatever `Content.Lifecycle.publish_document/5` is
  # promoting — a `%Document{}` struct in production, a plain map in tests.
  # Both shapes are read, mirroring `reject_hollow_paper_publish/1`.
  defp reject_level_skipping_fact(%{doc: doc}) when is_map(doc) do
    if fact_doc?(doc), do: gate_fact(doc), else: :ok
  end

  defp reject_level_skipping_fact(_payload), do: :ok

  defp gate_fact(doc) do
    content = doc_content(doc)
    rerun = field(content, "rerun")

    case Rerun.screen(rerun) do
      {:error, message} ->
        {:halt, message}

      :ok ->
        # DERIVED, never claimed. `derive_level/1` is handed the rerun command
        # and nothing else — not the evidence, not the claim. That asymmetry
        # IS the inversion this epic exists to enforce: no wording anywhere in
        # the document can raise the ceiling.
        case Rerun.check_ceiling(field(content, "level"), Rerun.derive_level(rerun)) do
          :ok -> :ok
          {:error, message} -> {:halt, message}
        end
    end
  end

  defp fact_doc?(%{type: "fact"}), do: true
  defp fact_doc?(%{"type" => "fact"}), do: true
  defp fact_doc?(%{"_type" => "fact"}), do: true
  defp fact_doc?(_), do: false

  defp doc_content(doc) do
    case Map.get(doc, :content) || Map.get(doc, "content") do
      content when is_map(content) -> content
      _ -> %{}
    end
  end

  # Content is string-keyed everywhere it is persisted (it round-trips through
  # JSON), so the string key is the only one read. An atom fallback would be a
  # second spelling of the same field and a place for the two to disagree.
  defp field(content, key), do: Map.get(content, key)
end
