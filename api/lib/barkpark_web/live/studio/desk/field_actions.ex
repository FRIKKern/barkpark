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

  ONE MENU FOR THE FORM. Each field draws its button only; the menu is drawn
  once (`shared_menu/1`), so a form of 40 fields carries 40 buttons and one
  menu, not 40 menus. The button's three dots are drawn by the sheet
  (`Desk.DocStyle`), not by an svg in every field.

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
  paste for it is dropped and the editor is told, since a rule can lock or hide
  a field while its menu is open. So is one for a field the form is hiding.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.LiveView, only: [push_event: 3]

  alias Barkpark.Content
  alias Barkpark.Content.DraftId
  alias BarkparkWeb.Components.Fields.Visibility
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.Desk.DocUndo
  alias BarkparkWeb.Studio.Desk.FieldClip
  alias BarkparkWeb.Studio.Desk.FieldLock
  alias BarkparkWeb.Studio.Desk.Menu
  alias BarkparkWeb.Studio.StudioLive.Handlers.FieldPaste
  alias BarkparkWeb.Studio.StudioLive.PostIdentity
  alias BarkparkWeb.Studio.StudioLive.Shared
  alias Phoenix.LiveView.JS

  # The form's one menu, and what the browser owns on each button: whether its
  # menu is open, and the anchor the open menu is placed by.
  @menu_id "field-actions-menu"
  @keep JS.ignore_attributes(["aria-expanded", "style"])

  @copied "desk:field-copied"
  @toast "desk:field-toast"

  # The field types whose input is a widget LiveView does not patch
  # (`Shared.widget_values_changed?/3`): a new value remounts them.
  @widget_types ~w(richText reference image)

  attr :name, :string, required: true, doc: "the field's name in the schema"
  attr :paste, :boolean, default: true, doc: "whether this editor may paste into the field"

  @doc """
  A field's "…" button. It opens the form's one menu (`shared_menu/1`) and
  names its field for it (`data-desk-field`).
  """
  def menu(assigns) do
    assigns = assign(assigns, menu_id: @menu_id, keep: @keep)

    ~H"""
    <div class="field-actions" data-desk-field-actions>
      <button
        type="button"
        id={"field-actions-#{@name}-button"}
        class="icon-btn"
        popovertarget={@menu_id}
        aria-haspopup="menu"
        aria-expanded="false"
        phx-mounted={@keep}
        aria-label={gettext("Field actions")}
        data-tip={gettext("Field actions")}
        data-desk-field={@name}
        data-desk-paste-off={!@paste}
      ></button>
    </div>
    """
  end

  @doc """
  The form's one Field actions menu, opened by every field's button. Which
  field it acts on is the browser's to say: `bp-desk.js` writes the opening
  button's field on it (`data-desk-field`), anchors it to that button and
  turns Paste off for a field that takes none; `bp-desk-field-actions.js`
  puts that field on the item as it is pressed. A patch leaves all of that
  alone. The server trusts none of it: each event names a field and is
  checked as before.
  """
  def shared_menu(assigns) do
    assigns = assign(assigns, :id, @menu_id)

    ~H"""
    <div
      id={@id}
      popover
      role="menu"
      aria-label={gettext("Field actions")}
      class="dk-field-menu dk-doc-menu-list dk-menu"
      phx-mounted={JS.ignore_attributes(["data-desk-field"])}
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
        data-desk-field-copy
      >{gettext("Copy field")}</Menu.item>
      <Menu.item
        role="menuitem"
        tabindex="-1"
        icon="clipboard"
        popovertarget={@id}
        popovertargetaction="hide"
        phx-click="desk-field-paste"
        phx-mounted={JS.ignore_attributes(["disabled", "aria-disabled"])}
        data-desk-field-paste
        data-desk-nothing={gettext("Nothing to paste")}
        data-desk-invalid={gettext("Invalid clipboard item")}
        data-desk-denied={gettext("The browser did not let this page read the clipboard")}
      >{gettext("Paste field")}</Menu.item>
    </div>
    """
  end

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

  @doc "The desk's field events: `desk-field-copy`, `desk-field-paste` and `desk-field-revert`."
  def handle_event("desk-field-copy", %{"field" => name}, socket) when is_binary(name) do
    case copy(socket.assigns, name) do
      nil -> {:noreply, socket}
      answer -> {:noreply, push_event(socket, @copied, answer)}
    end
  end

  # The paste names the document of the form its menu was pressed in
  # (`PostIdentity`): the clipboard is read first, and the pane may have
  # opened another document by the time the event is here.
  def handle_event("desk-field-paste", %{"field" => name, "clip" => clip} = params, socket)
      when is_binary(name) and is_binary(clip) do
    if PostIdentity.ours?(params, socket),
      do: paste(name, clip, socket),
      else: {:noreply, socket}
  end

  # Review changes' Revert (`ReviewChanges`), a field's write of its own.
  def handle_event("desk-field-revert", params, socket),
    do: BarkparkWeb.Studio.Desk.ReviewChanges.revert(params, socket)

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp paste(name, clip, socket) do
    case target(socket.assigns, name) do
      # The page offered a paste the form no longer allows (a rule locked or
      # hid the field since): said, not dropped in silence. A name the
      # schema does not have is nobody's field and is not answered.
      nil ->
        if known?(socket.assigns, name),
          do:
            {:noreply,
             push_event(socket, @toast, %{
               tone: "critical",
               title: gettext("This field cannot be edited, so nothing was pasted")
             })},
          else: {:noreply, socket}

      field ->
        current = stored(socket.assigns.editor_doc, name)

        case FieldPaste.plan(field, current, clip, &ref?(socket, &1, &2)) do
          {:save, params} ->
            # The typed edit's own way in, with the desk's guards, and a step
            # of the document's undo (`DocUndo.write_built/2`). The params
            # are built here for the open document: no browser post.
            {:noreply, saved} = DocUndo.write_built(params, socket)
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

  @doc """
  The field a paste may write: one of the open document's, shown by the
  form and open to this editor (`paste?/2`). nil otherwise.
  """
  @spec target(map(), String.t()) :: map() | nil
  def target(assigns, name) do
    form = assigns[:editor_form] || %{}

    with %{} = field <- shown(assigns, name),
         true <- paste?(FieldLock.resolve(field, form, true), assigns[:caps]) do
      field
    else
      _ -> nil
    end
  end

  defp known?(%{editor_doc: %{}, editor_schema: %{fields: fields}}, name),
    do: field(fields, name) != nil

  defp known?(_assigns, _name), do: false

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

  @doc """
  Whether a document `id` of `type` exists for this editor, published or
  draft: the scoped read every Studio handler makes.
  """
  @spec ref?(Phoenix.LiveView.Socket.t(), String.t(), String.t()) :: boolean()
  def ref?(socket, type, id) do
    opts = Shared.hook_opts(socket)
    dataset = socket.assigns.dataset

    Enum.any?([id, DraftId.draft_id(id)], fn doc_id ->
      match?({:ok, %{}}, Content.get_document(doc_id, type, dataset, opts))
    end)
  end

  # A reference's input is a widget the patch leaves alone; it is drawn again
  # with the pasted value.
  defp remount(socket, %{"type" => type}) when type in @widget_types,
    do:
      socket
      |> assign(:editor_form_gen, Shared.next_form_gen(socket, true))
      |> BarkparkWeb.Studio.StudioLive.Handlers.TextConfirmed.redrawn(socket)

  defp remount(socket, _field), do: socket

  # The schema's field of that name. The form's Title input stands for a
  # `title` the schema need not declare.
  defp field(fields, name) do
    Enum.find(List.wrap(fields), &(is_map(&1) and &1["name"] == name)) ||
      if name == "title", do: %{"name" => "title", "type" => "string"}
  end

  @doc "A field's stored value: the title is the document's own column, every other field is in its content."
  @spec stored(map(), String.t()) :: term()
  def stored(doc, "title"), do: Map.get(doc, :title)
  def stored(doc, name), do: Map.get(Map.get(doc, :content) || %{}, name)
end
