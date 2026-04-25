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

  ## Assigns

    * `:field` (required) — `%Field{type: "codelist", codelist_id: "<plugin>:<list>", version: int}`
    * `:value` — selected code (string) or `nil`
    * `:errors` — list of error strings (or `%{__self__: [...]}` for nested call sites)
    * `:on_change` — `phx-change` event name
    * `:plugin_name` — plugin scope (defaults to `"core"`; OnixEdit will pass `"onixedit"`)
    * `:path` — input name path (optional)
    * `:codelist_loader` — function `(plugin_name, list_id) -> codelist | nil`;
      defaults to `&Barkpark.Content.Codelists.get/2`. Test seam.
  """

  use Phoenix.Component

  @no_codelist_phrase "no codelist registered"

  attr :field, :map, required: true
  attr :value, :string, default: nil
  attr :errors, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :plugin_name, :string, default: "core"
  attr :path, :string, default: ""
  attr :codelist_loader, :any, default: nil

  def codelist_field(assigns) do
    assigns =
      assigns
      |> assign_new(:value, fn -> nil end)
      |> assign_new(:errors, fn -> %{} end)
      |> assign_new(:on_change, fn -> nil end)
      |> assign_new(:plugin_name, fn -> "core" end)
      |> assign_new(:path, fn -> "" end)
      |> assign_new(:codelist_loader, fn -> nil end)

    list_id = assigns.field.codelist_id || ""
    plugin_name = assigns.plugin_name
    loader = assigns.codelist_loader || (&default_loader/2)
    codelist = loader.(plugin_name, list_id)
    options = options_for(codelist)

    assigns =
      assigns
      |> assign(:title, title_for(assigns.field))
      |> assign(:plugin_name, plugin_name)
      |> assign(:list_id, list_id)
      |> assign(:options, options)
      |> assign(:input_name, assigns.path)
      |> assign(:input_id, "f-#{assigns.field.name}")
      |> assign(:errors_list, errors_list(assigns.errors))
      |> assign(:empty_phrase, @no_codelist_phrase)

    ~H"""
    <div class="bp-field bp-field-codelist" data-field-type="codelist" data-field-name={@field.name}>
      <%= if @options == [] do %>
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
      <% else %>
        <select
          class="bp-input bp-input-codelist"
          id={@input_id}
          name={@input_name}
          phx-change={@on_change}
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
