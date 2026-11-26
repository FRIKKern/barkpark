defmodule BarkparkWeb.Studio.Desk.DocClip do
  @moduledoc """
  "Copy document" and "Paste document" in the edit pane's header "…" menu,
  as the TanStack Studio's (`DocHeaderMenu.tsx`, `clipboard.ts`): the whole
  document through the system clipboard, in Sanity's format.

  COPY (`desk-doc-copy`) writes nothing. It answers the browser with the
  event `desk:doc-copied`: every field of the document's schema that holds a
  value, as the three clipboard types (`FieldClip.doc_copy/3`), or `empty`,
  the words that refuse a document with nothing in it. The document copied
  is the one the pane shows: the old revision while one is shown
  (`RevisionView`), the published version in the published perspective
  (`PublishedView`), else the open document as the editor holds it (for a
  viewer already redacted, as the form is). `bp-desk-doc-clip.js` writes the
  clipboard, since only the browser can.

  PASTE (`desk-doc-paste`). The browser reads the clipboard and sends its
  Sanity item. Every field of the open document is filled from the copied
  field of the same name when its value fits, read exactly as Paste field
  reads one (`Handlers.FieldPaste.value/5`); the rest are left alone, so a
  post pasted into an author moves only what fits. Nothing fits: the editor
  is told, with Sanity's words, and nothing is written.

  THE CLIPBOARD IS NOT TRUSTED. The fields written are this document's own:
  a top-level field of its schema (never `_id`, `_type`, `_rev` or another
  system key, which no schema field is called), that the form shows and lets
  this editor change (`FieldActions.target/2`: not hidden, not locked by its
  rule, not read-only for a non-admin). Each is one write through the
  Studio's own autosave (`EditorHost.write_built/2`), as Review changes'
  Revert all writes, so the schema's coercion and the save's rules apply.

  The paste names the document of the form it was pressed in
  (`PostIdentity`): one pressed in another document writes nothing. While an
  old revision or the published version is shown nothing is pasted, and the
  menu has no Paste (`RevisionView.menu/2`, `PublishedView.menu/2`); Copy
  stays, as a read.
  """
  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content.DraftId
  alias BarkparkWeb.Studio.Desk.DocUndo
  alias BarkparkWeb.Studio.Desk.FieldActions
  alias BarkparkWeb.Studio.Desk.FieldClip
  alias BarkparkWeb.Studio.Desk.PublishedView
  alias BarkparkWeb.Studio.Desk.RevisionView
  alias BarkparkWeb.Studio.StudioLive.Handlers.FieldPaste
  alias BarkparkWeb.Studio.StudioLive.PostIdentity
  alias BarkparkWeb.Studio.StudioLive.Shared

  @copied "desk:doc-copied"
  @toast "desk:field-toast"

  # A document's item: more than any field's (`FieldPaste`), still bounded.
  @max_bytes 1_048_576

  # The inputs a patch leaves alone: a pasted value remounts them.
  @widget_types ~w(richText reference image)

  @doc """
  The header menu's items with Copy document and Paste document added, after
  the rest and before Delete, as the TanStack Studio ends its menu with them.
  None without a document (no items).
  """
  @spec with_items([map()]) :: [map()]
  def with_items([]), do: []

  def with_items(items) do
    {before, delete} = Enum.split_while(items, &(&1.name != "delete-doc"))
    before ++ [copy_item(), paste_item()] ++ delete
  end

  defp copy_item,
    do: %{
      label: gettext("Copy document"),
      name: "copy-document",
      event: "desk-doc-copy",
      data: [
        "data-desk-doc-copy": true,
        "data-desk-copy-failed": gettext("Could not copy to the clipboard")
      ]
    }

  defp paste_item,
    do: %{
      label: gettext("Paste document"),
      name: "paste-document",
      event: "desk-doc-paste",
      data: [
        "data-desk-doc-paste": true,
        "data-desk-nothing": gettext("Nothing to paste"),
        "data-desk-invalid": gettext("Invalid clipboard item"),
        "data-desk-denied": gettext("The browser did not let this page read the clipboard")
      ]
    }

  @doc "The document's clipboard events: `desk-doc-copy` and `desk-doc-paste`."
  def handle_event("desk-doc-copy", _params, socket) do
    case copy(socket.assigns) do
      nil -> {:noreply, socket}
      answer -> {:noreply, push_event(socket, @copied, answer)}
    end
  end

  def handle_event("desk-doc-paste", %{"clip" => clip} = params, socket) when is_binary(clip) do
    if PostIdentity.ours?(params, socket) and is_map(socket.assigns[:editor_doc]) and
         not RevisionView.shown?(socket.assigns) and
         not PublishedView.active?(socket.assigns),
       do: paste(clip, socket),
       else: {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Copy ────────────────────────────────────────────────────────────────

  defp copy(%{editor_doc: %{}} = assigns) do
    doc = shown_doc(assigns)
    fields = for field <- fields(assigns), do: {field, FieldActions.stored(doc, field["name"])}

    if Enum.all?(fields, fn {_field, value} -> FieldClip.empty?(value) end) do
      %{empty: gettext("Empty value, nothing to copy")}
    else
      id = DraftId.published_id(to_string(doc.doc_id))
      FieldClip.doc_copy(fields, id, assigns[:editor_type])
    end
  end

  defp copy(_assigns), do: nil

  defp shown_doc(assigns) do
    cond do
      RevisionView.shown?(assigns) -> assigns.desk_revision.doc
      PublishedView.shown?(assigns) -> assigns.desk_published_view.doc
      true -> assigns.editor_doc
    end
  end

  # The schema's top-level fields, with the Title the form draws for a
  # `title` the schema need not declare.
  defp fields(%{editor_schema: %{fields: fields}}) when is_list(fields) do
    declared =
      for %{"name" => name} = field <- fields,
          is_binary(name) and not String.starts_with?(name, "_"),
          do: field

    if Enum.any?(declared, &(&1["name"] == "title")),
      do: declared,
      else: [%{"name" => "title", "type" => "string"} | declared]
  end

  defp fields(_assigns), do: [%{"name" => "title", "type" => "string"}]

  # ── Paste ───────────────────────────────────────────────────────────────

  defp paste(clip, socket) do
    case read(clip) do
      {:ok, copied} -> write(planned(copied, socket), socket)
      :nothing -> toast(socket, "default", gettext("Nothing to paste"), nil)
      :invalid -> toast(socket, "critical", gettext("Invalid clipboard item"), nil)
    end
  end

  # Each field this editor may write here that the copy fills, with the
  # value it takes, in the schema's order.
  defp planned(copied, socket) do
    assigns = socket.assigns
    ref? = &FieldActions.ref?(socket, &1, &2)

    for %{"name" => name} <- fields(assigns),
        {sig, value} <- [copied[name]],
        %{} = field <- [FieldActions.target(assigns, name)],
        current <- [FieldActions.stored(assigns.editor_doc, name)],
        {:ok, clean} <- [FieldPaste.value(field, current, sig, value, ref?)],
        do: {name, field, clean}
  end

  defp write([], socket) do
    toast(
      socket,
      "critical",
      gettext("Invalid clipboard item"),
      gettext("Source and target schema types are not compatible")
    )
  end

  defp write(writes, socket) do
    saved =
      Enum.reduce(writes, socket, fn {name, _field, value}, acc ->
        params = %{"doc" => %{name => value}, "_target" => ["doc", name]}
        # Each field a step of the document's undo, as TanStack's paste
        # writes each with its own edit (`DocUndo.write_built/2`).
        {:noreply, acc} = DocUndo.write_built(params, acc)
        acc
      end)

    if Enum.any?(writes, fn {_name, field, _value} -> field["type"] in @widget_types end),
      do:
        {:noreply,
         saved
         |> assign(:editor_form_gen, Shared.next_form_gen(saved, true))
         |> BarkparkWeb.Studio.StudioLive.Handlers.TextConfirmed.redrawn(saved)},
      else: {:noreply, saved}
  end

  defp toast(socket, tone, title, description) do
    payload = if description, do: %{description: description}, else: %{}
    {:noreply, push_event(socket, @toast, Map.merge(payload, %{tone: tone, title: title}))}
  end

  # The clipboard's item as `%{name => {sig, value}}` when it is a copied
  # document: Barkpark's own copy inside it, else what Sanity's item holds.
  # `:nothing` for anything else (a copied field is not a document).
  defp read(clip) when byte_size(clip) > @max_bytes, do: :invalid

  defp read(clip) do
    case Jason.decode(clip) do
      {:ok, %{"type" => "sanityClipboardItem"} = item} -> document(item)
      _ -> :nothing
    end
  end

  defp document(%{"barkpark" => %{"kind" => "document", "fields" => fields}})
       when is_list(fields) do
    copied =
      for %{"name" => name, "sig" => sig} = field <- fields,
          is_binary(name) and is_binary(sig),
          reduce: %{} do
        acc -> Map.put_new(acc, name, {sig, field["value"]})
      end

    {:ok, copied}
  end

  defp document(%{"barkpark" => %{"kind" => _kind}}), do: :nothing

  # Sanity's own document: each value's kind is all it says about itself.
  defp document(%{"isDocument" => true, "value" => %{} = value}) do
    copied =
      for {name, v} <- value,
          is_binary(name) and not String.starts_with?(name, "_"),
          into: %{},
          do: {name, {sanity_sig(v), v}}

    {:ok, copied}
  end

  defp document(_item), do: :nothing

  defp sanity_sig(v) when is_binary(v), do: "string"
  defp sanity_sig(v) when is_number(v), do: "number"
  defp sanity_sig(v) when is_boolean(v), do: "boolean"
  defp sanity_sig(_v), do: "sanity:object"
end
