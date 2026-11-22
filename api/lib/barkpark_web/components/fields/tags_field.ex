defmodule BarkparkWeb.Components.Fields.TagsField do
  @moduledoc """
  An array of strings with `options.layout: "tags"`, in the desk: the
  TanStack Studio's tags input (barkpark-studio `ArrayInputs.tsx`,
  `TagsInput`), after Sanity's.

    * One box of chips. Each chip is the tag and a × button named
      "Remove <tag>". After the chips, one text input carrying the field's
      path as its id (`tags`), where the person types the next tag.
    * Enter adds what is typed, trimmed, at the end; an empty input adds
      nothing. The Enter that commits an IME's word (Japanese, Chinese,
      Korean) is the IME's, not ours, and adds nothing: the next, plain
      Enter adds the word. `bp-desk-tags.js` reads the key.
    * The last tag removed unsets the field, as Sanity's does: the stored
      document has no key for it, not an empty list.

  WHAT IS POSTED. The input belongs to no form (`form` names none), so the
  editor form never posts what is being typed, and an unrelated edit posts
  nothing for the field: the save keeps what the store holds. An add and a
  remove are `array_op` presses (`add_tag`, `remove_tag`), with the
  document's mark as every other press (`PostIdentity.pressed/3`): the
  server takes the list from the editor's buffer, changes it and saves it
  (`Handlers.Tags`). Presses are handled in the order they were made, so
  tags typed fast, each with its Enter, all land, in order.

  Only the desk draws this (`id_base` set); the old Studio keeps its rows.
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Components.Fields.CompositeField

  @doc "Whether `array_field/1` draws these assigns as tags."
  def tags?(%{id_base: base, field: field}) when is_binary(base), do: tags_field?(field)

  def tags?(_assigns), do: false

  @doc "Whether a schema field is a tags field: an array of strings, `options.layout: \"tags\"`."
  def tags_field?(field),
    do:
      field_attr(field, :type) in ["arrayOf", "array"] and layout(field) == "tags" and
        string_items?(field)

  @doc """
  The list after a tags press, or `current` unchanged when it changes
  nothing.

    * `add_tag`: `value`, trimmed, at the end; a blank value adds nothing.
    * `remove_tag`: the tag at `index` when it is `value`, else the first
      tag that is `value` (the list moved under a press made before it was
      drawn again), else nothing.
  """
  @spec apply_op(String.t(), list(), map()) :: list()
  def apply_op("add_tag", current, %{"value" => value}) when is_binary(value) do
    case String.trim(value) do
      "" -> current
      tag -> current ++ [tag]
    end
  end

  def apply_op("remove_tag", current, %{"value" => value} = params) when is_binary(value) do
    at = index(params["index"])

    cond do
      is_integer(at) and Enum.at(current, at) == value -> List.delete_at(current, at)
      (found = Enum.find_index(current, &(&1 == value))) != nil -> List.delete_at(current, found)
      true -> current
    end
  end

  def apply_op(_action, current, _params), do: current

  defp index(i) when is_integer(i) and i >= 0, do: i

  defp index(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} when i >= 0 -> i
      _ -> nil
    end
  end

  defp index(_), do: nil

  attr :field, :map, required: true
  attr :value, :list, default: []
  attr :path, :string, default: ""
  attr :id_base, :string, required: true
  attr :on_reorder, :string, default: "array_op"
  attr :target, :any, default: nil
  attr :readonly, :boolean, default: false

  @doc "The box of chips and its input."
  def tags_field(assigns) do
    assigns =
      assigns
      |> Map.put_new(:path, "")
      |> Map.put_new(:on_reorder, "array_op")
      |> Map.put_new(:target, nil)
      |> Map.put_new(:readonly, false)
      |> Map.put(:tags, Enum.map(assigns[:value] || [], &display/1))
      |> Map.put(:title, title(assigns.field))
      |> Map.put(:description, CompositeField.description_for(assigns.field))
      |> Map.put(:dom_id, "bp-array-" <> sanitize_id("#{assigns.field.name}#{assigns[:path]}"))

    ~H"""
    <div class="bp-field bp-field-tags" data-field-type="arrayOf" data-array-kind="tags"
         id={@dom_id} data-field-name={@field.name}>
      <label class="bp-field-title" for={@id_base}><%= @title %></label>
      <p :if={@description} class="bp-field-description"><%= @description %></p>
      <div class="tags-box" data-tags-box>
        <span :for={{tag, i, id} <- chips(@tags, @dom_id)} id={id} class="tag"><%= tag %><button
            type="button"
            aria-label={gettext("Remove %{tag}", tag: tag)}
            disabled={@readonly}
            phx-click={@on_reorder}
            phx-target={@target}
            phx-value-action="remove_tag"
            phx-value-field={@field.name}
            phx-value-path={@path}
            phx-value-index={i}
            value={tag}
          ><svg width="1em" height="1em" viewBox="0 0 25 25" fill="none" aria-hidden="true"><path d="M18 7L7 18M7 7L18 18" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" /></svg></button></span>
        <input
          id={@id_base}
          class="tags-input"
          type="text"
          form={@dom_id <> "-none"}
          autocomplete="off"
          readonly={@readonly}
          placeholder={if @tags == [], do: gettext("Enter tag and press ENTER…")}
        />
        <button
          :if={!@readonly}
          type="button"
          hidden
          data-tags-add
          phx-click={@on_reorder}
          phx-target={@target}
          phx-value-action="add_tag"
          phx-value-field={@field.name}
          phx-value-path={@path}
        ></button>
      </div>
    </div>
    """
  end

  # Each chip keyed by its tag (and which of that tag it is), not its place:
  # after a remove the next chip keeps its own button. Drawn by place,
  # the removed chip's button, still waiting for its answer, became the next
  # tag's, and LiveView drops a click on such a button.
  defp chips(tags, dom_id) do
    {chips, _seen} =
      tags
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {tag, i}, seen ->
        n = Map.get(seen, tag, 0)

        hash =
          :crypto.hash(:sha256, tag) |> Base.url_encode64(padding: false) |> binary_part(0, 12)

        {{tag, i, "#{dom_id}-tag-#{hash}-#{n}"}, Map.put(seen, tag, n + 1)}
      end)

    chips
  end

  defp display(v) when is_binary(v), do: v
  defp display(nil), do: ""
  defp display(v) when is_number(v) or is_boolean(v) or is_atom(v), do: to_string(v)
  defp display(v), do: Jason.encode!(v)

  # Sanity's `options.layout` on the array: on the parsed field's `raw`
  # definition, or on the schema's own field map (`Shared.find_field/2`).
  defp layout(field) do
    case field_attr(field, :raw) || field do
      %{"options" => %{"layout" => layout}} -> layout
      %{"layout" => layout} -> layout
      _ -> nil
    end
  end

  defp string_items?(field) do
    case field_attr(field, :of) do
      %{} = of -> field_attr(of, :type) in ["string", nil]
      nil -> true
      _other -> false
    end
  end

  defp field_attr(%{} = f, key), do: Map.get(f, key) || Map.get(f, Atom.to_string(key))
  defp field_attr(_f, _key), do: nil

  defp title(%{title: t}) when is_binary(t) and t != "", do: t

  defp title(%{name: n}) when is_binary(n),
    do: n |> String.split(~r/[_\-]+/, trim: true) |> Enum.map_join(" ", &String.capitalize/1)

  defp title(_field), do: ""

  defp sanitize_id(s), do: s |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-")
end
