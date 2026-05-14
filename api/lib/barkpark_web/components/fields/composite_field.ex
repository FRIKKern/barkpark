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

  alias BarkparkWeb.Components.Fields.{ArrayField, CodelistField, LocalizedTextField, Visibility}

  attr :field, :map, required: true
  attr :value, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :on_change, :string, default: nil
  attr :plugin_name, :string, default: "core"
  attr :path, :string, default: ""
  attr :readonly, :boolean, default: false

  def composite_field(assigns) do
    path = Map.get(assigns, :path, "")

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
      |> Map.put(:depth, path_depth(path))

    ~H"""
    <%= if @depth >= 2 do %>
      <details class="bp-field bp-field-composite" data-field-type="composite" data-field-name={@field.name} data-depth={@depth} open>
        <summary class="bp-field-title"><%= @title %></summary>
        <div class="bp-field-body">
          <%= for sub <- @subfields, Visibility.visible?(sub, @value) do %>
            <div class="bp-subfield" data-subfield-name={sub.name}>
              <label class="bp-field-label" for={input_id(@field.name, sub.name)}>
                <%= title_for(sub) %>
              </label>
              <%= if onix_el = onix_element(sub) do %>
                <span class="bp-onix-hint" data-onix-element>
                  ONIX: <code><%= onix_el %></code>
                </span>
              <% end %>
              <%= render_subfield(assigns, sub) %>
              <%= for err <- Map.get(@errors, sub.name, []) do %>
                <span class="error" data-error-for={sub.name}><%= err %></span>
              <% end %>
            </div>
          <% end %>
        </div>
      </details>
    <% else %>
      <fieldset class="bp-field bp-field-composite" data-field-type="composite" data-field-name={@field.name} data-depth={@depth}>
        <legend class="bp-field-title"><%= @title %></legend>
        <div class="bp-field-body">
          <%= for sub <- @subfields, Visibility.visible?(sub, @value) do %>
            <div class="bp-subfield" data-subfield-name={sub.name}>
              <label class="bp-field-label" for={input_id(@field.name, sub.name)}>
                <%= title_for(sub) %>
              </label>
              <%= if onix_el = onix_element(sub) do %>
                <span class="bp-onix-hint" data-onix-element>
                  ONIX: <code><%= onix_el %></code>
                </span>
              <% end %>
              <%= render_subfield(assigns, sub) %>
              <%= for err <- Map.get(@errors, sub.name, []) do %>
                <span class="error" data-error-for={sub.name}><%= err %></span>
              <% end %>
            </div>
          <% end %>
        </div>
      </fieldset>
    <% end %>
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

  defp leaf_input(%{field: %{type: "boolean"}} = assigns) do
    assigns = Map.put(assigns, :checked, truthy?(assigns.value))

    ~H"""
    <div class="bp-input-checkbox">
      <input type="hidden" name={@input_name} value="false" />
      <input
        type="checkbox"
        class="bp-input"
        id={@input_id}
        name={@input_name}
        value="true"
        checked={@checked}
        phx-change={@on_change}
        disabled={@readonly}
      />
    </div>
    """
  end

  defp leaf_input(%{field: %{type: "string", name: name}} = assigns) do
    if numeric_name?(name) do
      ~H"""
      <input
        type="text"
        inputmode="numeric"
        pattern="-?[0-9]+(\.[0-9]+)?"
        class="bp-input bp-input-numeric"
        id={@input_id}
        name={@input_name}
        value={to_string(@value || "")}
        phx-change={@on_change}
        disabled={@readonly}
      />
      """
    else
      ~H"""
      <input
        type="text"
        class="bp-input"
        id={@input_id}
        name={@input_name}
        value={to_string(@value || "")}
        phx-change={@on_change}
        disabled={@readonly}
      />
      """
    end
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

  # Name-based heuristic: ONIX types numeric fields as `string` (e.g.
  # `priceAmount`, `editionNumber`, `prizeYear`, ~30 fields). Renderer
  # detects them by name suffix or exact match and emits `inputmode="numeric"`
  # + a `.bp-input-numeric` class hook so mobile keyboards switch to digits
  # and CSS can render the input visually distinct (monospace, right-aligned).
  # The pattern is a soft hint enforced on submit, not blur — won't block
  # typing. This is a renderer-only heuristic: schema does NOT declare a
  # `numeric:` flag; deleting this helper fully reverts behaviour.
  @numeric_suffixes ~w(Count Number Year Amount Percent)
  @numeric_names ~w(quantity weeks days pageRun extentValue priceAmount taxRate)

  defp numeric_name?(name) when is_binary(name) do
    name in @numeric_names or
      Enum.any?(@numeric_suffixes, fn suf -> String.ends_with?(name, suf) end)
  end

  defp numeric_name?(_), do: false

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?("1"), do: true
  defp truthy?("on"), do: true
  defp truthy?(_), do: false

  # Depth of the current composite within the form. Splits on `.` and `[`,
  # drops the `doc` envelope, counts remaining segments. Examples:
  #
  #   ""                                   -> 0
  #   "doc[titleDetail]"                   -> 1
  #   "doc[contributors][0]"               -> 2
  #   "doc[productSupplies][0].market"     -> 3
  defp path_depth(""), do: 0

  defp path_depth(path) when is_binary(path) do
    path
    |> String.split(["[", "."], trim: true)
    |> Enum.map(&String.trim_trailing(&1, "]"))
    |> Enum.reject(&(&1 == "" or &1 == "doc"))
    |> length()
  end

  defp path_depth(_), do: 0

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

  # Extracts the ONIX element name from a sub-field. Handles atom-keyed
  # `%Field{}` structs (post-adapter, the normal v2 path) and string-keyed
  # raw maps (book.json passthrough). Returns nil when no onix.element is
  # declared so the caller can render conditionally.
  defp onix_element(%{onix: %{} = o}), do: Map.get(o, "element") || Map.get(o, :element)
  defp onix_element(%{"onix" => %{} = o}), do: Map.get(o, "element") || Map.get(o, :element)
  defp onix_element(_), do: nil

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
