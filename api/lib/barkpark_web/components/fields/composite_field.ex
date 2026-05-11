defmodule BarkparkWeb.Components.Fields.CompositeField do
  @moduledoc """
  HEEx form component for v2 `composite` field type
  (masterplan-20260425-085425, Phase 0 line 55).

  Renders a labeled fieldset with one input per sub-field. Recurses into
  nested `composite`, `arrayOf`, `codelist`, and `localizedText` children.

  ## Assigns

    * `:field` (required) — `%Barkpark.Content.SchemaDefinition.Field{type: "composite"}`
    * `:value` — map keyed by sub-field name (defaults to `%{}`)
    * `:errors` — map of `%{sub_field_name => [error_message, ...]}`; defaults to `%{}`
    * `:on_change` — `phx-change` event name dispatched to parent LiveView
    * `:plugin_name` — codelist plugin scope (optional, defaults to `"core"`)
    * `:path` — dotted path prefix for nested fields (optional)
    * `:readonly` — render values as disabled inputs (defaults to `false`).
      Passes recursively into nested composite / arrayOf / codelist /
      localizedText children. For the v1 leaf fall-through the input
      carries `disabled` so the value remains visible but non-editable.
  """

  use Phoenix.Component

  alias BarkparkWeb.Components.Fields.{ArrayField, CodelistField, LocalizedTextField}

  attr :field, :map, required: true
  attr :value, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :plugin_name, :string, default: "core"
  attr :path, :string, default: ""
  attr :readonly, :boolean, default: false

  def composite_field(assigns) do
    assigns =
      assigns
      |> Map.put_new(:value, %{})
      |> Map.put_new(:errors, %{})
      |> Map.put_new(:on_change, nil)
      |> Map.put_new(:plugin_name, "core")
      |> Map.put_new(:path, "")
      |> Map.put_new(:readonly, false)
      |> Map.put(:title, title_for(assigns.field))
      |> Map.put(:subfields, assigns.field.fields || [])

    ~H"""
    <fieldset class="bp-field bp-field-composite" data-field-type="composite" data-field-name={@field.name}>
      <legend class="bp-field-title"><%= @title %></legend>
      <div class="bp-field-body">
        <%= for sub <- @subfields do %>
          <div class="bp-subfield" data-subfield-name={sub.name}>
            <label class="bp-field-label" for={input_id(@field.name, sub.name)}>
              <%= title_for(sub) %>
            </label>
            <%= render_subfield(assigns, sub) %>
            <%= for err <- Map.get(@errors, sub.name, []) do %>
              <span class="error" data-error-for={sub.name}><%= err %></span>
            <% end %>
          </div>
        <% end %>
      </div>
    </fieldset>
    """
  end

  # Render dispatch for one sub-field of a composite.
  defp render_subfield(assigns, %{type: "composite"} = sub) do
    sub_assigns = %{
      field: sub,
      value: get_value(assigns.value, sub.name, %{}),
      errors: nested_errors(assigns.errors, sub.name),
      on_change: assigns.on_change,
      plugin_name: assigns.plugin_name,
      path: child_path(assigns.path, sub.name),
      readonly: assigns.readonly
    }

    composite_field(sub_assigns)
  end

  defp render_subfield(assigns, %{type: "arrayOf"} = sub) do
    sub_assigns = %{
      field: sub,
      value: get_value(assigns.value, sub.name, []),
      errors: nested_errors(assigns.errors, sub.name),
      on_change: assigns.on_change,
      plugin_name: assigns.plugin_name,
      path: child_path(assigns.path, sub.name),
      readonly: assigns.readonly
    }

    ArrayField.array_field(sub_assigns)
  end

  defp render_subfield(assigns, %{type: "codelist"} = sub) do
    sub_assigns = %{
      field: sub,
      value: get_value(assigns.value, sub.name, nil),
      errors: nested_errors(assigns.errors, sub.name),
      on_change: assigns.on_change,
      plugin_name: assigns.plugin_name,
      path: child_path(assigns.path, sub.name),
      readonly: assigns.readonly
    }

    CodelistField.codelist_field(sub_assigns)
  end

  defp render_subfield(assigns, %{type: "localizedText"} = sub) do
    sub_assigns = %{
      field: sub,
      value: get_value(assigns.value, sub.name, %{}),
      errors: nested_errors(assigns.errors, sub.name),
      on_change: assigns.on_change,
      path: child_path(assigns.path, sub.name),
      readonly: assigns.readonly
    }

    LocalizedTextField.localized_text_field(sub_assigns)
  end

  # v1 enum: `select` with inline `options:` list (book.json `bp_export_status.state`).
  defp render_subfield(assigns, %{type: "select"} = sub) do
    leaf_assigns = %{
      field: sub,
      value: get_value(assigns.value, sub.name, ""),
      input_name: child_path(assigns.path, sub.name),
      input_id: input_id(assigns.field.name, sub.name),
      on_change: assigns.on_change,
      readonly: assigns.readonly,
      options: select_options(sub)
    }

    select_input(leaf_assigns)
  end

  # Multiline `text` — distinct from single-line `string`. Renders <textarea>.
  defp render_subfield(assigns, %{type: "text"} = sub) do
    leaf_assigns = %{
      field: sub,
      value: get_value(assigns.value, sub.name, ""),
      input_name: child_path(assigns.path, sub.name),
      input_id: input_id(assigns.field.name, sub.name),
      on_change: assigns.on_change,
      readonly: assigns.readonly,
      rows: text_rows(sub)
    }

    textarea_input(leaf_assigns)
  end

  # Fall-through for remaining v1 leaf types (string, slug, richText, image, …)
  defp render_subfield(assigns, sub) do
    leaf_assigns = %{
      field: sub,
      value: get_value(assigns.value, sub.name, ""),
      input_name: child_path(assigns.path, sub.name),
      input_id: input_id(assigns.field.name, sub.name),
      on_change: assigns.on_change,
      readonly: assigns.readonly
    }

    leaf_input(leaf_assigns)
  end

  defp leaf_input(assigns) do
    ~H"""
    <input
      type={input_type(@field.type)}
      class="bp-input"
      id={@input_id}
      name={@input_name}
      value={to_string(@value || "")}
      phx-change={@on_change}
      disabled={@readonly}
    />
    """
  end

  defp select_input(assigns) do
    ~H"""
    <select
      class="bp-input bp-input-select"
      id={@input_id}
      name={@input_name}
      phx-change={@on_change}
      disabled={@readonly}
    >
      <option value="" selected={is_nil(@value) or @value == ""}>— Select —</option>
      <%= for opt <- @options do %>
        <option value={opt.value} selected={to_string(@value) == opt.value}>
          <%= opt.label %>
        </option>
      <% end %>
    </select>
    """
  end

  defp textarea_input(assigns) do
    ~H"""
    <textarea
      class="bp-input bp-textarea"
      id={@input_id}
      name={@input_name}
      rows={@rows}
      phx-change={@on_change}
      disabled={@readonly}
    ><%= to_string(@value || "") %></textarea>
    """
  end

  # Normalize `options` list (raw strings or `%{value, label}` maps) into
  # `[%{value, label}]` for select rendering.
  defp select_options(%{options: opts}) when is_list(opts) do
    Enum.map(opts, fn
      %{"value" => v} = o ->
        %{value: to_string(v), label: to_string(Map.get(o, "label", v))}

      %{value: v} = o ->
        %{value: to_string(v), label: to_string(Map.get(o, :label, v))}

      v when is_binary(v) or is_atom(v) or is_number(v) ->
        s = to_string(v)
        %{value: s, label: s}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp select_options(_), do: []

  # `text` fields may declare a `rows:` option (see Sanity-style schema and
  # DocumentEditLive). Falls back to 3 when absent.
  defp text_rows(%{options: %{"rows" => r}}) when is_integer(r) and r > 0, do: r
  defp text_rows(%{options: %{rows: r}}) when is_integer(r) and r > 0, do: r
  defp text_rows(%{rows: r}) when is_integer(r) and r > 0, do: r
  defp text_rows(_), do: 3

  defp title_for(%{title: t}) when is_binary(t) and t != "", do: t
  defp title_for(%{name: n}) when is_binary(n), do: humanize(n)
  defp title_for(_), do: ""

  defp humanize(name) do
    name
    |> String.replace(~r/[_\-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp get_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp get_value(_, _, default), do: default

  defp nested_errors(errors, key) when is_map(errors) do
    case Map.get(errors, key) do
      sub when is_map(sub) -> sub
      list when is_list(list) -> %{__self__: list}
      _ -> %{}
    end
  end

  defp nested_errors(_, _), do: %{}

  defp child_path("", child), do: child
  defp child_path(parent, child), do: "#{parent}.#{child}"

  defp input_id(parent, child), do: "f-#{parent}-#{child}"

  defp input_type("boolean"), do: "checkbox"
  defp input_type("datetime"), do: "datetime-local"
  defp input_type("color"), do: "color"
  defp input_type(_), do: "text"
end
