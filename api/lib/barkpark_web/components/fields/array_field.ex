defmodule BarkparkWeb.Components.Fields.ArrayField do
  @moduledoc """
  HEEx form component for v2 `arrayOf` field type
  (masterplan-20260425-085425, Phase 0 line 55, Decision 13).

  Renders one row per element using the element's field component. Per
  Decision 13, ordered arrays expose **up/down buttons (NO drag)** for
  reordering; unordered arrays hide them. Add and remove buttons are
  always present.

  All reorder events are pure server round-trips: buttons emit `phx-click`
  with `phx-value-action` (`move_up` / `move_down` / `add_row` / `remove_row`)
  and `phx-value-index`. The parent LiveView handles them via the helpers
  exposed below — `move_up/2`, `move_down/2`, `add_row/2`, `remove_row/2`.
  No JS hook, no Sortable.js (Decision 13 explicitly defers drag to v2).

  ## Assigns

    * `:field` (required) — `%Field{type: "arrayOf"}`
    * `:value` — list (defaults to `[]`)
    * `:errors` — `%{integer_index => [error_message, ...] | %{...}}`
    * `:on_change` — `phx-change` event name for inputs
    * `:on_reorder` — `phx-click` event name for up/down/add/remove buttons
      (defaults to `"array_op"`)
    * `:plugin_name` — codelist plugin scope (optional)
    * `:path` — dotted path prefix (optional)
  """

  use Phoenix.Component

  alias BarkparkWeb.Components.Fields.{CodelistField, CompositeField, LocalizedTextField}

  attr :field, :map, required: true
  attr :value, :list, default: []
  attr :errors, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :on_reorder, :string, default: "array_op"
  attr :plugin_name, :string, default: "core"
  attr :path, :string, default: ""

  def array_field(assigns) do
    assigns =
      assigns
      |> Map.put_new(:value, [])
      |> Map.put_new(:errors, %{})
      |> Map.put_new(:on_change, nil)
      |> Map.put_new(:on_reorder, "array_op")
      |> Map.put_new(:plugin_name, "core")
      |> Map.put_new(:path, "")
      |> Map.put(:title, title_for(assigns.field))
      |> Map.put(:rows, Enum.with_index(assigns[:value] || []))
      |> Map.put(:ordered?, !!assigns.field.ordered)

    ~H"""
    <fieldset class="bp-field bp-field-array" data-field-type="arrayOf"
              data-field-name={@field.name} data-ordered={@ordered? && "true"}>
      <legend class="bp-field-title"><%= @title %></legend>
      <ol class="bp-array-rows">
        <%= for {row_value, idx} <- @rows do %>
          <li class="bp-array-row" data-row-index={idx}>
            <div class="bp-array-row-body">
              <%= render_element(assigns, row_value, idx) %>
            </div>
            <div class="bp-array-row-actions">
              <%= if @ordered? do %>
                <button
                  type="button"
                  class="bp-array-btn bp-array-btn-up"
                  phx-click={@on_reorder}
                  phx-value-action="move_up"
                  phx-value-field={@field.name}
                  phx-value-index={idx}
                  disabled={idx == 0}
                  aria-label="Move up"
                >▲</button>
                <button
                  type="button"
                  class="bp-array-btn bp-array-btn-down"
                  phx-click={@on_reorder}
                  phx-value-action="move_down"
                  phx-value-field={@field.name}
                  phx-value-index={idx}
                  disabled={idx == length(@rows) - 1}
                  aria-label="Move down"
                >▼</button>
              <% end %>
              <button
                type="button"
                class="bp-array-btn bp-array-btn-remove"
                phx-click={@on_reorder}
                phx-value-action="remove_row"
                phx-value-field={@field.name}
                phx-value-index={idx}
                aria-label="Remove row"
              >×</button>
            </div>
            <%= for err <- row_errors(@errors, idx) do %>
              <span class="error" data-error-for-row={idx}><%= err %></span>
            <% end %>
          </li>
        <% end %>
      </ol>
      <button
        type="button"
        class="bp-array-btn bp-array-btn-add"
        phx-click={@on_reorder}
        phx-value-action="add_row"
        phx-value-field={@field.name}
      >+ Add</button>
    </fieldset>
    """
  end

  # ─── public helpers — pure list operations the parent LiveView calls when
  # handling a reorder event. They are the single source of truth for the
  # "array up/down persistence" contract (Phase 0 line 60). ───────────────

  @doc "Swap rows `idx` and `idx-1`. Returns the list unchanged if `idx <= 0`."
  @spec move_up(list(), non_neg_integer()) :: list()
  def move_up(list, idx) when is_list(list) and is_integer(idx) and idx > 0 do
    if idx < length(list), do: do_swap(list, idx - 1, idx), else: list
  end

  def move_up(list, _), do: list

  @doc "Swap rows `idx` and `idx+1`. Returns the list unchanged if `idx` is the last row."
  @spec move_down(list(), non_neg_integer()) :: list()
  def move_down(list, idx) when is_list(list) and is_integer(idx) and idx >= 0 do
    if idx < length(list) - 1, do: do_swap(list, idx, idx + 1), else: list
  end

  def move_down(list, _), do: list

  @doc "Append a row to the list."
  @spec add_row(list(), term()) :: list()
  def add_row(list, row) when is_list(list), do: list ++ [row]

  @doc "Remove the row at `idx`. Returns the list unchanged if `idx` is out of range."
  @spec remove_row(list(), non_neg_integer()) :: list()
  def remove_row(list, idx) when is_list(list) and is_integer(idx) and idx >= 0 do
    if idx < length(list), do: List.delete_at(list, idx), else: list
  end

  def remove_row(list, _), do: list

  # ─── private ────────────────────────────────────────────────────────────────

  defp do_swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)

    list
    |> List.replace_at(i, b)
    |> List.replace_at(j, a)
  end

  defp render_element(assigns, row_value, idx) do
    item = element_field(assigns.field)
    row_path = "#{assigns.path}[#{idx}]"

    case item.type do
      "composite" ->
        CompositeField.composite_field(%{
          field: item,
          value: row_value || %{},
          errors: row_subfield_errors(assigns.errors, idx),
          on_change: assigns.on_change,
          plugin_name: assigns.plugin_name,
          path: row_path
        })

      "arrayOf" ->
        array_field(%{
          field: item,
          value: row_value || [],
          errors: row_subfield_errors(assigns.errors, idx),
          on_change: assigns.on_change,
          on_reorder: assigns.on_reorder,
          plugin_name: assigns.plugin_name,
          path: row_path
        })

      "codelist" ->
        CodelistField.codelist_field(%{
          field: item,
          value: row_value,
          errors: row_subfield_errors(assigns.errors, idx),
          on_change: assigns.on_change,
          plugin_name: assigns.plugin_name,
          path: row_path
        })

      "localizedText" ->
        LocalizedTextField.localized_text_field(%{
          field: item,
          value: row_value || %{},
          errors: row_subfield_errors(assigns.errors, idx),
          on_change: assigns.on_change,
          path: row_path
        })

      _ ->
        leaf_assigns = %{
          input_id: "f-#{assigns.field.name}-#{idx}",
          input_name: row_path,
          row_value: row_value,
          on_change: assigns.on_change
        }

        leaf_input(leaf_assigns)
    end
  end

  defp leaf_input(assigns) do
    ~H"""
    <input
      type="text"
      class="bp-input"
      id={@input_id}
      name={@input_name}
      value={to_string(@row_value || "")}
      phx-change={@on_change}
    />
    """
  end

  # The arrayOf parser stores the element shape on `field.of` (a `%Field{}`).
  defp element_field(%{of: %{} = of}), do: of
  defp element_field(_), do: %{type: "string", name: "item", title: nil}

  defp title_for(%{title: t}) when is_binary(t) and t != "", do: t
  defp title_for(%{name: n}) when is_binary(n), do: humanize(n)
  defp title_for(_), do: ""

  defp humanize(name) do
    name
    |> String.replace(~r/[_\-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp row_errors(errors, idx) when is_map(errors) do
    case Map.get(errors, idx) do
      list when is_list(list) -> list
      %{__self__: list} when is_list(list) -> list
      _ -> []
    end
  end

  defp row_errors(_, _), do: []

  defp row_subfield_errors(errors, idx) when is_map(errors) do
    case Map.get(errors, idx) do
      sub when is_map(sub) -> sub
      _ -> %{}
    end
  end

  defp row_subfield_errors(_, _), do: %{}
end
