defmodule BarkparkWeb.Components.Fields.CodelistField do
  @moduledoc """
  HEEx form component for v2 `codelist` field type
  (masterplan-20260425-085425, Phase 0 line 55, Decisions 20–21).

  Phase 0 ships a flat-list `<select>` picker; the Thema-tree picker
  (codelist 93) is Phase 5 work. Hierarchical codelists fall back to a
  flat select using only the **leaf** nodes (i.e. nodes with no children),
  with their breadcrumb path included in the option label so editors can
  still pick a code without the full tree UI.

  ## Empty registry placeholder

  Phase 0 ships zero codelists in core (Decision 20: codelist registries
  are plugin-supplied; the first plugin to register one is OnixEdit in
  Phase 4). When `Barkpark.Content.Codelists.get/2` returns `nil` (or
  returns a codelist with zero values), the field renders a disabled
  placeholder containing the literal phrase `"no codelist registered"`
  followed by `<plugin>:<list_id>`, so authors get clear feedback rather
  than a silent empty `<select>`.

  ## Large flat codelists — `<datalist>` combobox (G5)

  Some codelists are huge flat lists with no parent/child relationships
  (e.g. ISO country ~250, ISO language ~6800, ISO currency ~180). A plain
  `<select>` with thousands of `<option>`s is a scroll trap — browsers
  only let users jump by first letter. When the loaded codelist is
  **leaf-only** (i.e. every raw value has `parent_id == nil`) **AND**
  has more than 100 entries, this field renders a free-form `<input>`
  bound to a `<datalist>` instead, giving editors the browser's native
  typeahead for free.

  Value round-tripping: each `<option>` inside the `<datalist>` carries
  `value={opt.value}` (the codelist CODE) with the label text as the
  option's text content. The browser shows the label as an autocomplete
  hint but writes the `value` (the code) into the input when picked.
  Acceptable starting point — the input's submitted value IS the code.

  Hierarchical codelists (any raw value with a non-nil `parent_id`, e.g.
  Thema) render via the `TreeCodelistField` LiveComponent (G4) when the
  codelist carries more than 100 raw entries — that's the breakpoint
  where a flat breadcrumb `<select>` stops being navigable. Small
  hierarchical codelists (≤ 100 entries) continue to render via the
  flat-with-breadcrumbs `<select>` path; under that size the editor can
  eyeball the leaves faster than they can drill into a tree.

  ## Assigns

    * `:field` (required) — `%Field{type: "codelist", codelist_id: "<plugin>:<list>", version: int}`
    * `:value` — selected code (string) or `nil`
    * `:errors` — list of error strings (or `%{__self__: [...]}` for nested call sites)
    * `:on_change` — `phx-change` event name
    * `:plugin_name` — plugin scope (defaults to `"core"`; OnixEdit will pass `"onixedit"`)
    * `:path` — input name path (optional)
    * `:codelist_loader` — function `(plugin_name, list_id) -> codelist | nil`;
      defaults to `&Barkpark.Content.Codelists.get/2`. Test seam.
    * `:readonly` — disable the `<select>` (defaults to `false`).
  """

  use Phoenix.Component

  alias BarkparkWeb.Components.Fields.TreeCodelistField

  @no_codelist_phrase "no codelist registered"

  # G5 threshold: flat codelists larger than this render as a <datalist>
  # combobox (browser-native typeahead) instead of a giant <select>.
  @combobox_threshold 100

  # G4 threshold: hierarchical codelists with more than this many raw
  # entries render as a `TreeCodelistField` LiveComponent. Below the
  # threshold the flat-with-breadcrumbs `<select>` is still the better
  # UX — under ~100 nodes the editor can eyeball the list faster than
  # they can drill into a tree.
  @tree_threshold 100

  attr :field, :map, required: true
  attr :value, :string, default: nil
  attr :errors, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :plugin_name, :string, default: "core"
  attr :path, :string, default: ""
  attr :codelist_loader, :any, default: nil
  attr :tree_loader, :any, default: nil
  attr :readonly, :boolean, default: false

  def codelist_field(assigns) do
    assigns =
      assigns
      |> Map.put_new(:value, nil)
      |> Map.put_new(:errors, %{})
      |> Map.put_new(:on_change, nil)
      |> Map.put_new(:plugin_name, "core")
      |> Map.put_new(:path, "")
      |> Map.put_new(:codelist_loader, nil)
      |> Map.put_new(:tree_loader, nil)
      |> Map.put_new(:readonly, false)

    list_id = assigns.field.codelist_id || ""
    plugin_name = assigns.plugin_name
    loader = assigns.codelist_loader || (&default_loader/2)
    codelist = loader.(plugin_name, list_id)
    options = options_for(codelist)
    flat? = flat_codelist?(codelist)
    raw_count = raw_value_count(codelist)
    use_combobox? = flat? and length(options) > @combobox_threshold
    use_tree? = tree_codelist?(codelist) and raw_count > @tree_threshold

    assigns =
      assigns
      |> Map.put(:title, title_for(assigns.field))
      |> Map.put(:plugin_name, plugin_name)
      |> Map.put(:list_id, list_id)
      |> Map.put(:options, options)
      |> Map.put(:input_name, assigns.path)
      |> Map.put(:input_id, "f-#{assigns.field.name}")
      |> Map.put(:errors_list, errors_list(assigns.errors))
      |> Map.put(:empty_phrase, @no_codelist_phrase)
      |> Map.put(:use_combobox, use_combobox?)
      |> Map.put(:use_tree, use_tree?)

    ~H"""
    <div class="bp-field bp-field-codelist" data-field-type="codelist" data-field-name={@field.name}>
      <%= cond do %>
        <% @options == [] -> %>
          <select
            class="bp-input bp-input-codelist bp-codelist-empty"
            id={@input_id}
            name={@input_name}
            disabled
            data-codelist-empty="true"
            data-codelist-id={"#{@plugin_name}:#{@list_id}"}
          >
            <option value="">(<%= @empty_phrase %>: <%= @plugin_name %>:<%= @list_id %>)</option>
          </select>
        <% @use_tree -> %>
          <.live_component
            module={TreeCodelistField}
            id={"tree-" <> @input_id}
            field={@field}
            value={@value}
            options={@options}
            on_change={@on_change}
            plugin_name={@plugin_name}
            list_id={@list_id}
            readonly={@readonly}
            input_name={@input_name}
            tree_loader={@tree_loader}
          />
        <% @use_combobox -> %>
          <input
            class="bp-input bp-input-codelist"
            type="text"
            list={"datalist-" <> @input_id}
            id={@input_id}
            name={@input_name}
            value={@value || ""}
            phx-change={@on_change}
            disabled={@readonly}
            data-codelist-id={"#{@plugin_name}:#{@list_id}"}
            data-codelist-version={@field.version && to_string(@field.version)}
            data-codelist-combobox="true"
            placeholder={"Search " <> @plugin_name <> ":" <> @list_id <> "…"}
          />
          <datalist id={"datalist-" <> @input_id}>
            <%= for opt <- @options do %>
              <option value={opt.value}><%= opt.label %></option>
            <% end %>
          </datalist>
        <% true -> %>
          <select
            class="bp-input bp-input-codelist"
            id={@input_id}
            name={@input_name}
            phx-change={@on_change}
            disabled={@readonly}
            data-codelist-id={"#{@plugin_name}:#{@list_id}"}
            data-codelist-version={@field.version && to_string(@field.version)}
          >
            <option value="" selected={is_nil(@value) or @value == ""}>— Select —</option>
            <%= for opt <- @options do %>
              <option value={opt.value} selected={@value == opt.value}>
                <%= opt.value %> — <%= opt.label %>
              </option>
            <% end %>
          </select>
      <% end %>
      <%= for err <- @errors_list do %>
        <span class="error" data-error-for={@field.name}><%= err %></span>
      <% end %>
    </div>
    """
  end

  @doc "G5 combobox cutoff: flat codelists with more than this many entries render as a <datalist>."
  def combobox_threshold, do: @combobox_threshold

  @doc "G4 tree cutoff: hierarchical codelists with more than this many raw entries render as a TreeCodelistField."
  def tree_threshold, do: @tree_threshold

  @doc "The exact placeholder phrase used when the registry is empty."
  def empty_registry_phrase, do: @no_codelist_phrase

  # ─── private ────────────────────────────────────────────────────────────────

  defp default_loader(plugin_name, list_id) do
    Code.ensure_loaded?(Barkpark.Content.Codelists) and
      apply(Barkpark.Content.Codelists, :get, [plugin_name, list_id])
  rescue
    _ -> nil
  end

  defp options_for(nil), do: []
  defp options_for(false), do: []
  defp options_for(%{values: values}) when is_list(values), do: flatten_options(values)
  defp options_for(_), do: []

  # True iff the codelist is leaf-only — every raw value has a nil parent_id.
  # Used by the G5 combobox path: hierarchical codelists (Thema, …) stay on
  # the flat-with-breadcrumbs <select> renderer; only flat codelists ever
  # become a <datalist> combobox.
  defp flat_codelist?(%{values: values}) when is_list(values) and values != [] do
    Enum.all?(values, fn v -> Map.get(v, :parent_id) in [nil, false] end)
  end

  defp flat_codelist?(_), do: false

  # True iff ANY raw value carries a non-nil parent_id — i.e. the codelist
  # is hierarchical. Drives the G4 tree-picker dispatch.
  defp tree_codelist?(%{values: values}) when is_list(values) and values != [] do
    Enum.any?(values, fn v ->
      pid = Map.get(v, :parent_id)
      not is_nil(pid) and pid != false
    end)
  end

  defp tree_codelist?(_), do: false

  defp raw_value_count(%{values: values}) when is_list(values), do: length(values)
  defp raw_value_count(_), do: 0

  # Flatten hierarchical codelists to leaves only (Phase 0 fallback for Thema —
  # the tree picker lands in Phase 5). Roots that have children become section
  # headers conceptually; here we just emit leaves with breadcrumb labels.
  defp flatten_options(values) do
    by_id = Map.new(values, &{&1.id, &1})
    children_by_parent = Enum.group_by(values, & &1.parent_id)

    leaves = Enum.filter(values, fn v -> Map.get(children_by_parent, v.id, []) == [] end)

    leaves
    |> Enum.sort_by(fn v -> {v.position || 1_000_000, v.code} end)
    |> Enum.map(fn v ->
      %{value: v.code, label: breadcrumb_label(v, by_id)}
    end)
  end

  defp breadcrumb_label(%{parent_id: nil} = v, _by_id), do: best_label(v)

  defp breadcrumb_label(%{parent_id: pid} = v, by_id) do
    case Map.get(by_id, pid) do
      nil -> best_label(v)
      parent -> "#{breadcrumb_label(parent, by_id)} › #{best_label(v)}"
    end
  end

  defp best_label(%{translations: translations} = v) when is_list(translations) do
    pick =
      Enum.find(translations, &(&1.language == "nob")) ||
        Enum.find(translations, &(&1.language == "eng")) ||
        List.first(translations)

    case pick do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> v.code
    end
  end

  defp best_label(%{code: code}), do: code

  defp title_for(%{title: t}) when is_binary(t) and t != "", do: t
  defp title_for(%{name: n}) when is_binary(n), do: humanize(n)
  defp title_for(_), do: ""

  defp humanize(name) do
    name
    |> String.replace(~r/[_\-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp errors_list(errors) when is_list(errors), do: errors
  defp errors_list(%{__self__: list}) when is_list(list), do: list
  defp errors_list(_), do: []
end
