defmodule BarkparkWeb.Studio.Desk.FieldActions do
  @moduledoc """
  A field's "Field actions" menu in the desk's form, as the TanStack Studio's
  (`Fields.tsx` `FieldActions`): a "…" button at the field's top right, shown
  under the pointer or the focus, with "Copy field" and "Paste field".

  The menu is an HTML popover in the desk's menu look (`Desk.Menu`), as the
  document's "…" menu is: Enter or a click opens it, Escape or a click
  outside closes it and gives the focus back to the button. `bp-desk.js`
  focuses the first item, keeps `aria-expanded` and moves the focus with the
  arrow keys (its menu rule matches `dk-doc-menu-list`).

  COPY. The item sends `desk-field-copy` with the field's name. The answer
  is the event `desk:field-copied`: the field's stored value as the three
  clipboard types (`FieldClip`), or the words that say the field is empty.
  `bp-desk-field-actions.js` writes the clipboard, since only the browser
  can, and shows the words. An empty field is refused and the clipboard keeps
  what it held, as in Sanity, so a misclick never wipes the next paste.

  The value copied is the one stored for the open document (its draft when
  it has one), read from the editor's own copy of it. Only a top-level field
  of the open document's schema is answered for, so the event hands out
  nothing the form does not show.

  PASTE. Drawn, and not on yet.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content.DraftId
  alias BarkparkWeb.Studio.Desk.FieldClip
  alias BarkparkWeb.Studio.Desk.Glyph
  alias BarkparkWeb.Studio.Desk.Menu

  @copied "desk:field-copied"

  attr :name, :string, required: true, doc: "the field's name in the schema"

  @doc "The \"…\" button and its menu, for the field `name`."
  def menu(assigns) do
    assigns = assign(assigns, id: "field-actions-" <> assigns.name, anchor: anchor(assigns.name))

    ~H"""
    <div class="field-actions" data-desk-field-actions>
      <button
        type="button"
        id={"#{@id}-button"}
        class="icon-btn"
        popovertarget={@id}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("Field actions")}
        data-tip={gettext("Field actions")}
        style={"anchor-name: #{@anchor}"}
      >
        <Glyph.glyph name="ellipsis-horizontal" />
      </button>
      <div
        id={@id}
        popover
        role="menu"
        aria-label={gettext("Field actions")}
        class="dk-field-menu dk-doc-menu-list dk-menu"
        style={"position-anchor: #{@anchor}"}
        data-desk-copy-failed={gettext("Could not copy to the clipboard")}
      >
        <Menu.item
          role="menuitem"
          tabindex="-1"
          icon="copy"
          popovertarget={@id}
          popovertargetaction="hide"
          phx-click="desk-field-copy"
          phx-value-field={@name}
          data-desk-field-copy={@name}
        >{gettext("Copy field")}</Menu.item>
        <Menu.item
          role="menuitem"
          tabindex="-1"
          icon="clipboard"
          disabled
          aria-disabled="true"
          data-desk-field-paste={@name}
        >{gettext("Paste field")}</Menu.item>
      </div>
    </div>
    """
  end

  # A CSS anchor name is an identifier and a field's name need not be one.
  defp anchor(name),
    do: "--dk-field-" <> (:md5 |> :crypto.hash(name) |> Base.encode16(case: :lower))

  @doc "The desk's field events: `desk-field-copy`."
  def handle_event("desk-field-copy", %{"field" => name}, socket) when is_binary(name) do
    case copy(socket.assigns, name) do
      nil -> {:noreply, socket}
      answer -> {:noreply, push_event(socket, @copied, answer)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # What the browser is told for a copy of field `name`: its three clipboard
  # types, or `empty`, the words that refuse it. nil when no document is open
  # or its schema has no such field.
  defp copy(%{editor_doc: %{} = doc, editor_schema: %{fields: fields}} = assigns, name) do
    case field(fields, name) do
      nil ->
        nil

      field ->
        value = stored(doc, name)

        if FieldClip.empty?(value) do
          %{field: name, empty: gettext("Empty value, nothing to copy")}
        else
          id = DraftId.published_id(to_string(doc.doc_id))
          field |> FieldClip.field_copy(value, id, assigns[:editor_type]) |> Map.put(:field, name)
        end
    end
  end

  defp copy(_assigns, _name), do: nil

  # The schema's field of that name. The form's Title input stands for a
  # `title` the schema need not declare.
  defp field(fields, name) do
    Enum.find(List.wrap(fields), &(is_map(&1) and &1["name"] == name)) ||
      if name == "title", do: %{"name" => "title", "type" => "string"}
  end

  # The title is the document's own column; every other field is in its content.
  defp stored(doc, "title"), do: Map.get(doc, :title)
  defp stored(doc, name), do: Map.get(Map.get(doc, :content) || %{}, name)
end
