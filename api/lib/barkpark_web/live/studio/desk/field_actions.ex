defmodule BarkparkWeb.Studio.Desk.FieldActions do
  @moduledoc """
  A field's "Field actions" menu in the desk's form, as the TanStack Studio's
  (`Fields.tsx` `FieldActions`): a "…" button at the field's top right, shown
  under the pointer or the focus, with "Copy field" and "Paste field".

  The menu is an HTML popover in the desk's menu look (`Desk.Menu`), as the
  document's "…" menu is: Enter or a click opens it, Escape or a click
  outside closes it and gives the focus back to the button. `bp-desk.js`
  focuses the first item, keeps `aria-expanded` and moves the focus with the
  arrow keys (its menu rule matches `dk-doc-menu-list`). `aria-expanded` is
  the browser's: a patch of the form while a menu is open leaves it alone.

  COPY. The item sends `desk-field-copy` with the field's name. The answer
  is the event `desk:field-copied`: the field's stored value as the three
  clipboard types (`FieldClip`), or the words that say the field is empty.
  `bp-desk-field-actions.js` writes the clipboard, since only the browser
  can, and shows the words. An empty field is refused and the clipboard keeps
  what it held, as in Sanity, so a misclick never wipes the next paste.

  The value copied is the one stored for the open document (its draft when
  it has one), read from the editor's own copy of it. That copy is the one
  the form was drawn from: for a viewer it is already redacted
  (`Shared`'s editor clamp), so a field kept from them is empty here too.
  Only a top-level field of the open document's schema that the form shows
  is answered for (`shown/2`): a field hidden by its `visibleWhen` is not,
  whatever the page sent. A field locked by its rule is shown, read-only,
  and copies.

  PASTE. A browser that will not let the page read the clipboard says so
  and nothing is sent. Otherwise the browser reads the clipboard and the item sends
  `desk-field-paste` with the field's name and the clipboard item's JSON.
  `Handlers.FieldPaste` reads the item against the field's schema; the
  clipboard is not trusted. What fits is saved as a typed edit of that field
  is: the Studio's own `autosave`, through `EditorHost`, with the `doc`
  params the field's input would have posted. What does not fit is answered
  with the event `desk:field-toast` and the words that refuse it, and nothing
  is written.

  A field the form does not let this editor change takes no paste
  (`paste?/2`): one locked by its `readOnly` rule (`FieldLock`), or declared
  read-only for an editor who is not an admin. Its Paste item is off, and a
  paste sent by hand is dropped. So is one for a field the form is hiding.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content
  alias Barkpark.Content.DraftId
  alias BarkparkWeb.Components.Fields.Visibility
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.Desk.EditorHost
  alias BarkparkWeb.Studio.Desk.FieldClip
  alias BarkparkWeb.Studio.Desk.FieldLock
  alias BarkparkWeb.Studio.Desk.Glyph
  alias BarkparkWeb.Studio.Desk.Menu
  alias BarkparkWeb.Studio.StudioLive.Handlers.FieldPaste
  alias BarkparkWeb.Studio.StudioLive.Shared
  alias Phoenix.LiveView.JS

  @copied "desk:field-copied"
  @toast "desk:field-toast"

  # The field types whose input is a widget LiveView does not patch
  # (`Shared.widget_values_changed?/3`): a new value remounts them.
  @widget_types ~w(richText reference image)

  attr :name, :string, required: true, doc: "the field's name in the schema"
  attr :paste, :boolean, default: true, doc: "whether this editor may paste into the field"

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
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
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
        data-desk-unavailable={gettext("Copy and paste did not load. Reload the page.")}
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
          disabled={!@paste}
          aria-disabled={!@paste && "true"}
          popovertarget={@id}
          popovertargetaction="hide"
          phx-click="desk-field-paste"
          phx-value-field={@name}
          data-desk-field-paste={@name}
          data-desk-nothing={gettext("Nothing to paste")}
          data-desk-invalid={gettext("Invalid clipboard item")}
          data-desk-denied={gettext("The browser did not let this page read the clipboard")}
        >{gettext("Paste field")}</Menu.item>
      </div>
    </div>
    """
  end

  # A CSS anchor name is an identifier and a field's name need not be one.
  defp anchor(name),
    do: "--dk-field-" <> (:md5 |> :crypto.hash(name) |> Base.encode16(case: :lower))

  @doc """
  Whether this editor may paste into `field` (as `FieldLock.resolve/3` left
  it): not while its rule locks it, and not a read-only field unless the
  editor is an admin.
  """
  @spec paste?(map(), map() | nil) :: boolean()
  def paste?(field, caps) do
    not FieldLock.locked?(field) and
      not (field["readOnly"] == true and not Caps.admin_affordance?(caps))
  end

  @doc "The desk's field events: `desk-field-copy` and `desk-field-paste`."
  def handle_event("desk-field-copy", %{"field" => name}, socket) when is_binary(name) do
    case copy(socket.assigns, name) do
      nil -> {:noreply, socket}
      answer -> {:noreply, push_event(socket, @copied, answer)}
    end
  end

  def handle_event("desk-field-paste", %{"field" => name, "clip" => clip}, socket)
      when is_binary(name) and is_binary(clip) do
    case target(socket.assigns, name) do
      nil ->
        {:noreply, socket}

      field ->
        current = stored(socket.assigns.editor_doc, name)

        case FieldPaste.plan(field, current, clip, &ref?(socket, &1, &2)) do
          {:save, params} ->
            # The typed edit's own way in, with the desk's guards (`EditorHost`).
            {:noreply, saved} = EditorHost.handle_event("autosave", params, socket)
            {:noreply, remount(saved, field)}

          :nothing ->
            {:noreply,
             push_event(socket, @toast, %{tone: "default", title: gettext("Nothing to paste")})}

          {:invalid, why} ->
            {:noreply,
             push_event(socket, @toast, %{
               tone: "critical",
               title: gettext("Invalid clipboard item"),
               description: why
             })}
        end
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # What the browser is told for a copy of field `name`: its three clipboard
  # types, or `empty`, the words that refuse it. nil when no document is open
  # or its schema has no such field.
  defp copy(%{editor_doc: %{} = doc} = assigns, name) do
    case shown(assigns, name) do
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

  # The field a paste may write: one of the open document's, shown by the
  # form and open to this editor. nil otherwise.
  defp target(assigns, name) do
    form = assigns[:editor_form] || %{}

    with %{} = field <- shown(assigns, name),
         true <- paste?(FieldLock.resolve(field, form, true), assigns[:caps]) do
      field
    else
      _ -> nil
    end
  end

  # The open document's field of that name, when the form shows it: in the
  # schema, and not hidden by its `visibleWhen`. nil otherwise.
  defp shown(%{editor_doc: %{}, editor_schema: %{fields: fields}} = assigns, name) do
    with %{} = field <- field(fields, name),
         true <- Visibility.visible?(field, assigns[:editor_form] || %{}) do
      field
    else
      _ -> nil
    end
  end

  defp shown(_assigns, _name), do: nil

  # Whether a document `id` of `type` exists for this editor, published or
  # draft: the scoped read every Studio handler makes.
  defp ref?(socket, type, id) do
    opts = Shared.hook_opts(socket)
    dataset = socket.assigns.dataset

    Enum.any?([id, DraftId.draft_id(id)], fn doc_id ->
      match?({:ok, %{}}, Content.get_document(doc_id, type, dataset, opts))
    end)
  end

  # A reference's input is a widget the patch leaves alone; it is drawn again
  # with the pasted value.
  defp remount(socket, %{"type" => type}) when type in @widget_types,
    do: assign(socket, :editor_form_gen, Shared.next_form_gen(socket, true))

  defp remount(socket, _field), do: socket

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
