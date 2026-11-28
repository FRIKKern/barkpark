defmodule BarkparkWeb.Studio.StudioLive.PageTitle do
  @moduledoc """
  The open document's name in the browser tab and its heading
  (`page_title`), moved out of `StudioLive.Shared` (task-42a6f063263338f6).
  """

  import Phoenix.Component, only: [assign: 2]

  # The browser tab names the open document (task-fee30130f015c416): every
  # document tab read "Studio · Barkpark", and a screen reader's page
  # announcement never said which document it was. The root layout's
  # live_title adds the " · Barkpark" suffix.
  # It is recomputed wherever the open document changes in place, not only on
  # navigation: a save that renames it, and the block editor's sync
  # (task-72e1de4c53c5ed9f).
  # Same order as the document header names it (Editor's document_header):
  # `DocTitle.header/2`.
  #
  # The row named is the newest stored version this tab has seen
  # (`Lifecycle.base_doc/1`): `editor_doc` stays this tab's own row after
  # another editor's save (task-42a6f063263338f6). A title this tab holds
  # unsaved (a save that did not land, a refused one) is named over it, as
  # TanStack's DocumentPane names its cached doc, which carries this editor's
  # unsent values (edits.ts `overlay`).
  def assign_page_title(socket) do
    title =
      case title_doc(socket) do
        %{} = doc ->
          BarkparkWeb.Studio.DocTitle.header(doc, socket.assigns[:editor_schema])

        _ ->
          "Studio"
      end

    assign(socket, page_title: title)
  end

  defp title_doc(socket) do
    with %{} = doc <- BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle.base_doc(socket) do
      case held_text(socket.assigns) do
        title when is_binary(title) -> %{doc | title: title}
        nil -> doc
      end
    end
  end

  @doc """
  The open document and the title it is named by while this tab holds its
  title unsaved (a save that did not land, a refused one):
  `{published id, type, page_title}`, else nil. The desk's list row names
  it so (task-82becc4945d1ad1e), as TanStack's row reads the doc its cache
  overlays with this editor's unsent values; one rule, so the row, the
  header and the tab cannot drift apart. A document is one id of one type:
  two types can share an id.

  With `type`, a list pane's type: nil for a list of another type, so that
  pane is not drawn again while the title is held.
  """
  def held(assigns, type \\ nil) do
    with title when is_binary(title) <- held_text(assigns),
         %{doc_id: id, type: doc_type} when is_binary(id) <- assigns[:editor_doc],
         true <- is_nil(type) or type == doc_type,
         shown when is_binary(shown) <- assigns[:page_title] do
      {Barkpark.Content.published_id(id), doc_type, shown}
    else
      _ -> nil
    end
  end

  # The title text this tab holds unsaved, else nil.
  defp held_text(assigns) do
    held = assigns[:editor_unsaved_keys] || MapSet.new()

    case assigns[:editor_form] do
      %{"title" => title} when is_binary(title) ->
        if MapSet.member?(held, "title"), do: title

      _ ->
        nil
    end
  end
end
