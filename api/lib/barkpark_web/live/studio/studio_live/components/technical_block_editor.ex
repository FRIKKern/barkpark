defmodule BarkparkWeb.Studio.StudioLive.Components.TechnicalBlockEditor do
  @moduledoc """
  Typed fallback forms and pure patch builders for technical PortableDoc blocks.

  Collection patches are accepted only when the submitted row count matches the
  stored list. Every row starts from its stored value, so unknown keys, legacy
  rows, and the `code` spelling tolerated by `code-tabs` survive ordinary edits.
  """

  use Phoenix.Component

  attr :block, :map, required: true
  attr :id, :string, required: true

  def technical_block_editor(assigns) do
    ~H"""
    <form
      id={"technical-block-form-" <> @id}
      class="bp-paper-edit-form"
      phx-submit="paper-edit-block"
      phx-change="paper-block-autosave"
      phx-debounce="500"
      data-test-id={"paper-technical-editor-" <> Map.get(@block, "type", "unknown")}
    >
      <input type="hidden" name="block_id" value={@id} />

      <%= case Map.get(@block, "type") do %>
        <% "diff" -> %>
          <.text_input name="file" label="File" value={field(@block, "file")} />
          <.text_input name="lang" label="Language" value={field(@block, "lang")} />
          <.textarea name="diff" label="Unified diff" value={field(@block, "diff")} />
        <% "filetree" -> %>
          <.textarea name="text" label="File tree" value={field(@block, "text")} />
          <.text_input name="legend" label="Legend" value={field(@block, "legend")} />
        <% "footnote" -> %>
          <.collection_rows kind="note" items={collection(@block, "notes")} />
        <% "code-tabs" -> %>
          <.text_input name="syncKey" label="Sync key" value={field(@block, "syncKey")} />
          <.collection_rows kind="tab" items={collection(@block, "tabs")} />
        <% _ -> %>
      <% end %>
    </form>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  defp text_input(assigns) do
    ~H"""
    <label class="bp-paper-edit-fieldlabel">
      {@label}
      <input type="text" name={@name} value={@value} class="bp-paper-edit-text" />
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  defp textarea(assigns) do
    ~H"""
    <label class="bp-paper-edit-fieldlabel">
      {@label}
      <textarea name={@name} rows="7" class="bp-paper-edit-textarea bp-paper-edit-code"><%= @value %></textarea>
    </label>
    """
  end

  attr :kind, :string, required: true
  attr :items, :list, required: true

  defp collection_rows(assigns) do
    ~H"""
    <input type="hidden" name={@kind <> "-count"} value={length(@items)} />
    <div :for={{item, index} <- Enum.with_index(@items)} data-test-id={@kind <> "-row"}>
      <%= if is_map(item) do %>
        <%= if @kind == "note" do %>
          <.text_input name={row_name(@kind, index, "id")} label="ID" value={field(item, "id")} />
          <.textarea name={row_name(@kind, index, "text")} label="Note" value={field(item, "text")} />
        <% else %>
          <.text_input name={row_name(@kind, index, "label")} label="Label" value={field(item, "label")} />
          <.text_input name={row_name(@kind, index, "language")} label="Language" value={field(item, "language")} />
          <.textarea name={row_name(@kind, index, "value")} label="Code" value={tab_value(item)} />
        <% end %>
      <% else %>
        <p data-test-id={@kind <> "-legacy-row"}>Legacy row retained until explicitly removed.</p>
      <% end %>
      <button type="submit" name={@kind <> "-action"} value={"up:#{index}"} disabled={index == 0}>Move up</button>
      <button type="submit" name={@kind <> "-action"} value={"down:#{index}"} disabled={index == length(@items) - 1}>Move down</button>
      <button type="submit" name={@kind <> "-action"} value={"remove:#{index}"}>Remove</button>
    </div>
    <button type="submit" name={@kind <> "-action"} value="add">Add {@kind}</button>
    """
  end

  @doc "Build the typed patch for a supported technical block."
  def build_patch(%{"type" => "diff"}, params),
    do: put_fetched_fields(%{}, params, ~w(diff file lang))

  def build_patch(%{"type" => "filetree"}, params),
    do: put_fetched_fields(%{}, params, ~w(text legend))

  def build_patch(%{"type" => "footnote"} = block, params),
    do: collection_patch(block, params, "notes", "note", &update_note/3, &new_note/0)

  def build_patch(%{"type" => "code-tabs"} = block, params) do
    %{}
    |> put_fetched_fields(params, ["syncKey"])
    |> Map.merge(collection_patch(block, params, "tabs", "tab", &update_tab/3, &new_tab/0))
  end

  def build_patch(_block, _params), do: %{}

  @doc "Validate collection integrity before returning a typed patch."
  def validate_patch(%{"type" => "footnote"} = block, params) do
    with :ok <- validate_collection_count(block, params, "notes", "note") do
      {:ok, build_patch(block, params)}
    end
  end

  def validate_patch(%{"type" => "code-tabs"} = block, params) do
    with :ok <- validate_collection_count(block, params, "tabs", "tab") do
      {:ok, build_patch(block, params)}
    end
  end

  def validate_patch(block, params), do: {:ok, build_patch(block, params)}

  defp collection_patch(block, params, field_name, param_name, updater, factory) do
    count = params[param_name <> "-count"]

    with {:ok, items} <- stored_collection(block, field_name),
         true <- exact_count?(count, length(items)) do
      updated =
        items
        |> Enum.with_index()
        |> Enum.map(fn {item, index} -> updater.(item, params, index) end)
        |> apply_action(params[param_name <> "-action"], factory)

      %{field_name => updated}
    else
      _ -> %{}
    end
  end

  defp validate_collection_count(block, params, field_name, param_name) do
    count_name = param_name <> "-count"

    collection_params? =
      Enum.any?(Map.keys(params), fn key ->
        is_binary(key) and String.starts_with?(key, param_name <> "-")
      end)

    cond do
      not Map.has_key?(params, count_name) and not collection_params? ->
        :ok

      not Map.has_key?(params, count_name) ->
        {:error, {:malformed_collection, field_name}}

      true ->
        case stored_collection(block, field_name) do
          {:ok, items} ->
            if exact_count?(params[count_name], length(items)),
              do: :ok,
              else: {:error, {:malformed_collection, field_name}}

          :error ->
            {:error, {:malformed_collection, field_name}}
        end
    end
  end

  defp update_note(item, params, index) when is_map(item) do
    put_row_fields(item, params, "note", index, ~w(id text))
  end

  defp update_note(item, _params, _index), do: item

  defp update_tab(item, params, index) when is_map(item) do
    item
    |> put_row_fields(params, "tab", index, ~w(label language))
    |> put_tab_value(params, index)
  end

  defp update_tab(item, _params, _index), do: item

  defp put_tab_value(item, params, index) do
    param = row_name("tab", index, "value")

    if Map.has_key?(params, param) do
      submitted = params[param] || ""

      cond do
        submitted == tab_value(item) ->
          item

        Map.has_key?(item, "value") and Map.has_key?(item, "code") ->
          item |> Map.put("value", submitted) |> Map.put("code", submitted)

        Map.has_key?(item, "value") and not is_nil(Map.get(item, "value")) ->
          Map.put(item, "value", submitted)

        Map.has_key?(item, "code") ->
          Map.put(item, "code", submitted)

        true ->
          Map.put(item, "value", submitted)
      end
    else
      item
    end
  end

  defp put_row_fields(item, params, kind, index, fields) do
    Enum.reduce(fields, item, fn field_name, acc ->
      param = row_name(kind, index, field_name)
      if Map.has_key?(params, param), do: Map.put(acc, field_name, params[param] || ""), else: acc
    end)
  end

  defp put_fetched_fields(map, params, fields) do
    Enum.reduce(fields, map, fn field_name, acc ->
      if Map.has_key?(params, field_name),
        do: Map.put(acc, field_name, params[field_name] || ""),
        else: acc
    end)
  end

  defp apply_action(items, "add", factory), do: items ++ [factory.()]
  defp apply_action(items, "remove:" <> index, _factory), do: delete_at(items, index)
  defp apply_action(items, "up:" <> index, _factory), do: move(items, index, -1)
  defp apply_action(items, "down:" <> index, _factory), do: move(items, index, 1)
  defp apply_action(items, _action, _factory), do: items

  defp delete_at(items, index) do
    case parse_index(index) do
      index when is_integer(index) and index >= 0 and index < length(items) ->
        List.delete_at(items, index)

      _ ->
        items
    end
  end

  defp move(items, index, offset) do
    with index when is_integer(index) <- parse_index(index),
         target = index + offset,
         true <- index >= 0 and index < length(items),
         true <- target >= 0 and target < length(items) do
      source_item = Enum.at(items, index)
      target_item = Enum.at(items, target)

      items
      |> List.replace_at(index, target_item)
      |> List.replace_at(target, source_item)
    else
      _ -> items
    end
  end

  defp exact_count?(count, expected) when is_binary(count) do
    case Integer.parse(count) do
      {^expected, ""} -> true
      _ -> false
    end
  end

  defp exact_count?(_count, _expected), do: false

  defp parse_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {index, ""} when index >= 0 -> index
      _ -> nil
    end
  end

  defp new_note, do: %{"id" => "", "text" => ""}
  defp new_tab, do: %{"label" => "", "language" => "", "value" => ""}

  defp collection(block, key) do
    case Map.get(block, key) do
      items when is_list(items) -> items
      _ -> []
    end
  end

  defp stored_collection(block, key) do
    case Map.fetch(block, key) do
      :error -> {:ok, []}
      {:ok, nil} -> {:ok, []}
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, _other} -> :error
    end
  end

  defp field(map, key), do: stringish(Map.get(map, key))
  defp tab_value(tab), do: stringish(Map.get(tab, "value") || Map.get(tab, "code"))
  defp row_name(kind, index, field_name), do: "#{kind}-#{index}-#{field_name}"

  defp stringish(value) when is_binary(value), do: value
  defp stringish(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp stringish(_value), do: ""
end
