defmodule BarkparkWeb.Studio.Desk.ItemRefs do
  @moduledoc """
  The titles of the documents an object array's items point at, for the
  items' previews on the desk (`ArrayItemDialog`), as the TanStack Studio's
  (`ObjectArrayInput.tsx` `useItemPreview`): a doc link whose preview
  subtitle is its `target` shows the target's title, "Fixture post 04", not
  its id.

  The ids are read from the editor's buffer: every reference subfield of
  every item of the document's object arrays. The titles are read again (one
  query, `Refs.titles/3`) only when those ids change, so typing in any other
  field reads nothing. `EditorHost` calls `follow/1` after each event and
  message the editor handles; the adapter hands `desk_item_refs` to the
  array (`ref_titles`). A target that cannot be read is shown by its id.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Barkpark.Content
  alias BarkparkWeb.Studio.Desk.Refs

  @doc "The socket with `desk_item_refs` following the editor's buffer."
  def follow(%{assigns: %{editor_schema: %{} = schema, dataset: dataset} = assigns} = socket)
      when is_binary(dataset) do
    ids = ids(assigns[:editor_form], schema)

    cond do
      ids == assigns[:desk_item_ref_ids] ->
        socket

      ids == [] ->
        socket |> assign(:desk_item_ref_ids, []) |> assign(:desk_item_refs, %{})

      true ->
        titles = Refs.titles(ids, dataset, assigns[:scope] || [])
        socket |> assign(:desk_item_ref_ids, ids) |> assign(:desk_item_refs, titles)
    end
  end

  def follow(socket), do: socket

  @doc """
  The published ids every reference subfield of every object array item of
  `form` holds, in order, without repeats. Read from the buffer alone.
  """
  @spec ids(map() | nil, map()) :: [String.t()]
  def ids(form, schema) when is_map(form) do
    for %{"name" => name, "type" => type, "of" => %{} = of} <- Map.get(schema, :fields) || [],
        type in ["arrayOf", "array"],
        refs = ref_names(of),
        refs != [],
        %{} = item <- List.wrap(form[name]),
        ref <- refs,
        id = ref_id(item[ref]),
        id != nil,
        uniq: true,
        do: id
  end

  def ids(_form, _schema), do: []

  defp ref_names(%{"fields" => fields}) when is_list(fields),
    do: for(%{"name" => n, "type" => "reference"} <- fields, do: n)

  defp ref_names(_of), do: []

  defp ref_id(%{"_ref" => id}) when is_binary(id) and id != "", do: Content.published_id(id)
  defp ref_id(id) when is_binary(id) and id != "", do: Content.published_id(id)
  defp ref_id(_value), do: nil
end
