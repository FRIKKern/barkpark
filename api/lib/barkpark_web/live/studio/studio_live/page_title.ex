defmodule BarkparkWeb.Studio.StudioLive.PageTitle do
  @moduledoc """
  The open document's name in the browser tab and its heading
  (`page_title`), moved out of `StudioLive.Shared` (task-42a6f063263338f6).
  """

  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.Component, only: [assign: 2]

  # The browser tab names the open document (task-fee30130f015c416): every
  # document tab read "Studio · Barkpark", and a screen reader's page
  # announcement never said which document it was. The root layout's
  # live_title adds the " · Barkpark" suffix.
  # It is recomputed wherever the open document changes in place, not only on
  # navigation: a save that renames it, and the block editor's sync
  # (task-72e1de4c53c5ed9f).
  # Same order as the document header names it (Editor's document_header):
  # the stored title, else the schema's derived preview title (a titleless
  # author is its name), else a singleton's schema title, else "Untitled".
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
          BarkparkWeb.Studio.DocTitle.shown(Map.get(doc, :title)) ||
            derived_title(doc, socket.assigns[:editor_schema])

        _ ->
          "Studio"
      end

    assign(socket, page_title: title)
  end

  defp title_doc(socket) do
    with %{} = doc <- BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle.base_doc(socket) do
      held = socket.assigns[:editor_unsaved_keys] || MapSet.new()

      case socket.assigns[:editor_form] do
        %{"title" => title} when is_binary(title) ->
          if MapSet.member?(held, "title"), do: %{doc | title: title}, else: doc

        _ ->
          doc
      end
    end
  end

  defp derived_title(doc, schema) do
    Barkpark.Content.TitleDerivation.preview_title(doc, schema) ||
      (schema && Map.get(schema, :singleton) == true && Map.get(schema, :title)) ||
      gettext("Untitled")
  end
end
