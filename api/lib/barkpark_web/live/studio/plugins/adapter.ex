defmodule BarkparkWeb.Studio.Plugins.Adapter do
  @moduledoc """
  Studio editor adapter for v2 plugin schema field types.

  The base Studio LiveView (`BarkparkWeb.Studio.StudioLive`) historically
  matched on `field["type"]` and rendered a static set of v1 inputs (string,
  text, boolean, select, …). The Phase 4 adapter slots in BEFORE that match:
  if the field declares a v2 type — `composite`, `arrayOf`, `codelist`, or
  `localizedText` — the adapter parses it into a
  `Barkpark.Content.SchemaDefinition.Field` struct and dispatches to the
  matching component under `BarkparkWeb.Studio.Plugins.FieldComponents`.

  v1 fields never enter this module: `v2?/1` returns `false` and StudioLive
  uses its existing `render_input/2` clauses unchanged. This is the
  no-regression guarantee for legacy seed schemas (post, page, author,
  category, project, siteSettings, navigation, colors).

  ## Plugin owner discovery

  A schema's plugin owner is the `:plugin_name` we pass into codelist
  components for registry scoping (Decision 20). The adapter resolves it in
  this order:

    1. Explicit `field["plugin"]` on a per-field basis (rare).
    2. The schema's top-level `"plugin"` key — when a plugin's
       `register_schemas/1` callback emits a SchemaDefinition with a `plugin`
       attribute in `raw_payload`, the adapter respects it.
    3. Otherwise the prefix of `codelist_id` itself: `"onixedit:role"` →
       plugin `"onixedit"` (matches `Barkpark.Content.Codelists`'s convention).
    4. Falls back to `"core"`.

  No `Code.eval_*` is used (decision D7). The TUI is read-only for v2
  (decision D12); the TUI's read-only path lives in `cmd/barkpark/tui.go`.
  """

  use Phoenix.Component

  alias Barkpark.Content.SchemaDefinition.Field
  alias BarkparkWeb.Studio.Plugins.FieldComponents

  @v2_types ~w(composite arrayOf codelist localizedText)

  @doc """
  Returns `true` if `field` is a v2 plugin field type that this adapter
  handles. Accepts string-keyed maps (the on-disk shape from
  `SchemaDefinition.fields`) or `%Field{}` structs.
  """
  @spec v2?(map()) :: boolean()
  def v2?(%Field{type: t}) when t in @v2_types, do: true
  def v2?(%{"type" => t}) when t in @v2_types, do: true
  def v2?(_), do: false

  @doc """
  Returns the list of v2 type names this adapter handles. Useful for tests
  and for documenting the contract with WI1/WI2/WI3.
  """
  def v2_types, do: @v2_types

  @doc """
  Render `field` for the Studio editor. The caller is the existing Studio
  LiveView; `assigns` carries `editor_form` (and optionally `editor_schema`).

  Returns a Phoenix LiveView rendered struct. Callers should only invoke
  this when `v2?(field)` returns `true`. v1 fields fall through to
  StudioLive's `render_input/2`.
  """
  def render(assigns, %{"type" => type, "name" => name} = raw_field)
      when type in @v2_types do
    plugin = resolve_plugin(assigns, raw_field)
    parsed = to_field_struct(raw_field)
    value = field_value(assigns, name, type)
    path = "doc[#{name}]"

    case type do
      "composite" ->
        FieldComponents.composite(%{
          field: parsed,
          value: ensure_map(value),
          errors: errors_for(assigns, name),
          on_change: "autosave",
          plugin_name: plugin,
          path: path
        })

      "arrayOf" ->
        FieldComponents.array_of(%{
          field: parsed,
          value: ensure_list(value),
          errors: errors_for(assigns, name),
          on_change: "autosave",
          on_reorder: "array_op",
          plugin_name: plugin,
          path: path,
          # Picker context for reference rows (tsk-dossier-ref-picker).
          dataset: Map.get(assigns, :dataset, "production"),
          scope_prefix: Map.get(assigns, :scope_prefix, ""),
          api_token_raw: Map.get(assigns, :api_token_raw, "")
        })

      "codelist" ->
        FieldComponents.codelist(%{
          field: parsed,
          value: ensure_string(value),
          errors: errors_for(assigns, name),
          on_change: "autosave",
          plugin_name: plugin,
          path: path
        })

      "localizedText" ->
        FieldComponents.localized_text(%{
          field: parsed,
          value: ensure_map(value),
          errors: errors_for(assigns, name),
          on_change: "autosave",
          path: path
        })
    end
  end

  def render(assigns, _other) do
    # Defensive: if a caller invokes us on a non-v2 field, render nothing.
    # StudioLive will use `render_input/2` for v1 fields via the dispatch
    # check at the call site (see the `v2?/1` fork in
    # `StudioComponents.Editor.studio_field_renderer/1`).
    ~H""
  end

  # ─── plugin owner resolution ────────────────────────────────────────────

  defp resolve_plugin(assigns, raw_field) do
    cond do
      is_binary(raw_field["plugin"]) and raw_field["plugin"] != "" ->
        raw_field["plugin"]

      schema_plugin(assigns) != nil ->
        schema_plugin(assigns)

      raw_field["type"] == "codelist" and is_binary(raw_field["codelistId"]) ->
        case String.split(raw_field["codelistId"], ":", parts: 2) do
          [plugin, _] when plugin != "" -> plugin
          _ -> "core"
        end

      # Composite / arrayOf top-level fields don't carry `codelistId` themselves;
      # walk the subtree and inherit the plugin prefix from the first nested
      # codelist. Without this, nested codelists default to `"core"` and look
      # up `core:<plugin>:<list>` → MISS → "(no codelist registered)" placeholder.
      raw_field["type"] in ["composite", "arrayOf"] ->
        case find_nested_codelist_plugin(raw_field) do
          nil -> "core"
          plugin -> plugin
        end

      true ->
        "core"
    end
  end

  # Walks composite / arrayOf subtrees for the first nested codelist's plugin
  # prefix. Returns `nil` when no nested codelist is found (the caller falls
  # back to `"core"`). For composites with codelists from multiple plugins
  # (rare polymorphic case) the first encountered prefix wins — documented
  # limitation.
  defp find_nested_codelist_plugin(%{"type" => "composite", "fields" => fields})
       when is_list(fields) do
    Enum.find_value(fields, &find_nested_codelist_plugin/1)
  end

  defp find_nested_codelist_plugin(%{"type" => "arrayOf", "of" => of}) when is_map(of) do
    find_nested_codelist_plugin(of)
  end

  defp find_nested_codelist_plugin(%{"type" => "codelist", "codelistId" => id})
       when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      [plugin, _] when plugin != "" -> plugin
      _ -> nil
    end
  end

  defp find_nested_codelist_plugin(_), do: nil

  defp schema_plugin(%{editor_schema: %{plugin: plugin}}) when is_binary(plugin) and plugin != "",
    do: plugin

  defp schema_plugin(%{editor_schema: %{} = schema}) do
    case Map.get(schema, "plugin") do
      p when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  defp schema_plugin(_), do: nil

  # ─── value extraction ───────────────────────────────────────────────────

  defp field_value(%{editor_form: form}, name, _type) when is_map(form), do: Map.get(form, name)
  defp field_value(_, _, _), do: nil

  defp ensure_map(v) when is_map(v), do: v
  defp ensure_map(_), do: %{}

  defp ensure_list(v) when is_list(v), do: v
  defp ensure_list(_), do: []

  defp ensure_string(v) when is_binary(v), do: v
  defp ensure_string(_), do: nil

  defp errors_for(%{validation_errors: errs}, name) when is_map(errs), do: errs[name] || %{}
  defp errors_for(_, _), do: %{}

  # ─── raw map → %Field{} conversion (mirrors SchemaDefinition.parse_field/2,
  # which is private; we deliberately avoid `Code.eval_*` per D7). ─────────

  defp to_field_struct(%{"type" => type, "name" => name} = raw) do
    base = %Field{
      name: name,
      type: type,
      title: raw["title"],
      options: raw["options"],
      validations: raw["validations"] || [],
      onix: raw["onix"],
      raw: raw
    }

    case type do
      "composite" ->
        %Field{
          base
          | fields:
              raw
              |> Map.get("fields", [])
              |> Enum.map(&to_field_struct_or_nil/1)
              |> Enum.reject(&is_nil/1)
        }

      "arrayOf" ->
        of_raw = Map.get(raw, "of") || %{"type" => "string", "name" => "#{name}[item]"}
        of_raw = of_raw |> stringify() |> Map.put_new("name", "#{name}[item]")

        %Field{
          base
          | ordered: !!Map.get(raw, "ordered", false),
            of: to_field_struct(of_raw)
        }

      "codelist" ->
        %Field{
          base
          | codelist_id: raw["codelistId"],
            version: raw["version"]
        }

      "localizedText" ->
        %Field{
          base
          | languages: raw["languages"] || [],
            format: localized_format(raw["format"] || "plain"),
            fallback_chain: raw["fallbackChain"] || []
        }

      _ ->
        base
    end
  end

  defp to_field_struct_or_nil(%{"type" => _, "name" => _} = raw), do: to_field_struct(raw)

  defp to_field_struct_or_nil(other) when is_map(other),
    do: to_field_struct_or_nil(stringify(other))

  defp to_field_struct_or_nil(_), do: nil

  defp localized_format("rich"), do: :rich
  defp localized_format(_), do: :plain

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
