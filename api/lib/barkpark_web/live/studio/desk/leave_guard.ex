defmodule BarkparkWeb.Studio.Desk.LeaveGuard do
  @moduledoc """
  What the desk asks before it leaves a document with a held field
  (task-33cbb6269c8823ad): typing whose save did not land (refused, or held
  over another editor's rewrite, `editor_unsaved_keys`), or a field the
  store refused (`RefusedSave`).

  The edit pane carries the question as `data-desk-held` and the document's
  id as `data-desk-held-doc`. `bp-desk.js` asks it before a link opens a
  desk path without that document, and before the tab closes or reloads, as
  the TanStack Studio's `beforeunload` does over `hasUnsaved()`
  (`lib/edits.ts`). Leaving drops the held text: the next document's form
  replaces it. Nothing held, nothing drawn.
  """

  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.StudioLive.RefusedSave

  @doc "The question, naming the held fields; nil when nothing is held."
  @spec message(map()) :: String.t() | nil
  def message(assigns) do
    case keys(assigns) do
      [] ->
        nil

      keys ->
        gettext(
          "Not saved: %{fields}. Leave this document anyway? What you typed there will be lost.",
          fields: Enum.map_join(keys, ", ", &title(assigns, &1))
        )
    end
  end

  @doc "The open document's published id while a field is held, else nil."
  @spec doc(map()) :: String.t() | nil
  def doc(assigns) do
    with [_ | _] <- keys(assigns),
         %{doc_id: id} when is_binary(id) <- assigns[:editor_doc] do
      Barkpark.Content.published_id(id)
    else
      _ -> nil
    end
  end

  # The held top-level fields, in the schema's order.
  defp keys(assigns) do
    held =
      (assigns[:editor_unsaved_keys] || MapSet.new())
      |> MapSet.union(MapSet.new(refused(assigns)))

    order = Enum.map(fields(assigns), &(is_map(&1) && &1["name"]))
    Enum.sort_by(held, &(Enum.find_index(order, fn name -> name == &1 end) || length(order)))
  end

  defp refused(%{editor_doc: _} = assigns), do: RefusedSave.keys(assigns)
  defp refused(_assigns), do: []

  defp title(assigns, key) do
    case Enum.find(fields(assigns), &(is_map(&1) and &1["name"] == key)) do
      %{"title" => title} when is_binary(title) and title != "" -> title
      _ -> key
    end
  end

  defp fields(assigns) do
    case assigns[:editor_schema] do
      %{fields: fields} when is_list(fields) -> fields
      _ -> []
    end
  end
end
