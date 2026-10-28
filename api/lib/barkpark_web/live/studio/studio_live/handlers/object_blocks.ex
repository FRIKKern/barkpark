defmodule BarkparkWeb.Studio.StudioLive.Handlers.ObjectBlocks do
  @moduledoc """
  The block dialog of the Classic rich-text editor (task-19392d1e6fc661e6).

  A Portable Text body (an imported Sanity article body) holds custom blocks
  such as a `mediaModule` or a `quote`. The editor shows each as a box that
  names its `_key` (`Barkpark.Content.PortableText`). Clicking a box opens the
  block's fields in a dialog, in the same object form a page-builder item uses
  (`BarkparkWeb.Components.Fields.ObjectForm`). Saving the dialog writes the
  block back into the body by its `_key`; every other block keeps its stored
  bytes. "Insert block" in the toolbar adds a new block of a type the field's
  `blocks.of` declares, at the caret, with a fresh `_key`, and opens it.

  The body's text stays the editor's HTML in the form buffer. A block save
  rebuilds the body from that HTML (`PortableText.from_html/2`) against the
  stored body with the edited block in place, so a text edit the editor has
  made and the block edit both land.

  The same dialog edits the two other kinds of object a Portable Text value
  holds, when the field declares them in its `blocks` vocabulary (stage S3 of
  the Portable Text plan):

    * an annotation (a mark definition such as a `docLink`, a `link` or a
      `linkAnnotation`), with the fields its `blocks.annotations` entry
      declares. A declared `link` with no fields has Sanity's `href`. No
      field is required, so a `linkAnnotation` saves without `linkType`. The
      dialog's Remove takes the annotation off its text.
    * an inline object (a `blocks.inline` entry, such as a `docBreak`), with
      the fields its entry declares, or else the fields of the object type it
      names.

  The editor makes the new annotation's or inline object's `_key` and puts it
  in its HTML; the server adds the object under that key, writes the body and
  opens the dialog.

  The dialog state lives in `socket.assigns.object_dialog`:

      %{kind: :block, field: "body", key: "a1b2c3d4e5f6", type: "quote",
        title: "Sitat", member: %Field{}, member_raw: %{...}, value: %{...},
        stored: %{...}, touched: MapSet.t()}

  `kind` is `:block`, `:annotation` or `:inline`.
  """
  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content.{Forms, PortableText, Schema}
  alias BarkparkWeb.Components.Fields.ArrayField
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Plugins.Adapter
  alias BarkparkWeb.Studio.StudioLive.{Path, Shared}

  # The input-name prefix of the dialog's fields: `doc[__object].quote`,
  # `doc[__object].author.label`. A `doc[...]` envelope followed by dotted
  # segments arrives from the browser as one flat params key, which
  # `Path.parse_path/1` reads (the same shape the document form posts).
  @prefix "doc[__object]"
  @root "__object"

  @doc false
  def prefix, do: @prefix

  # ── open ────────────────────────────────────────────────────────────────

  def open(%{"field" => field, "key" => key} = params, socket)
      when is_binary(field) and is_binary(key) do
    socket = flush_html(socket, field, params["html"])

    with {:ok, _field_def} <- portable_text_field(socket, field),
         %{} = block <- stored_block(socket, field, key),
         {:ok, dialog} <- dialog_for(socket, field, block) do
      {:noreply, assign(socket, object_dialog: dialog)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("This block cannot be opened in a form."))}
    end
  end

  def open(_params, socket), do: {:noreply, socket}

  # ── insert ──────────────────────────────────────────────────────────────

  def insert(%{"field" => field, "type" => type, "pending" => pending, "html" => html}, socket)
      when is_binary(field) and is_binary(type) and is_binary(pending) and is_binary(html) do
    with {:ok, field_def} <- portable_text_field(socket, field),
         true <- type in Enum.map(insertable_types(field_def), & &1.name),
         {:ok, member_raw} <- member_raw(socket, type) do
      block =
        member_raw
        |> Map.get("fields", [])
        |> Path.seed_defaults()
        |> Map.put("_type", type)
        |> Map.put("_key", Path.new_key())

      box = PortableText.to_html([block])
      html = replace_pending(html, pending, box)
      stored = stored_body(socket, field)
      blocks = PortableText.from_html(html, stored ++ [block], field: field_def)

      socket =
        socket
        |> write_body(field, blocks)
        |> push_event("bp:pt-block-ready", %{
          field: field,
          pending: pending,
          key: block["_key"],
          html: box
        })

      case dialog_for(socket, field, block) do
        {:ok, dialog} -> {:noreply, assign(socket, object_dialog: dialog)}
        _ -> {:noreply, socket}
      end
    else
      _ ->
        {:noreply,
         socket
         |> push_event("bp:pt-block-ready", %{field: field, pending: pending, key: nil, html: ""})
         |> put_flash(:error, gettext("This block type cannot be inserted here."))}
    end
  end

  def insert(_params, socket), do: {:noreply, socket}

  # ── annotations ─────────────────────────────────────────────────────────

  @doc "Open the dialog of the annotation (mark definition) with this `_key`."
  def open_def(%{"field" => field, "key" => key} = params, socket)
      when is_binary(field) and is_binary(key) do
    socket = flush_html(socket, field, params["html"])

    with {:ok, field_def} <- portable_text_field(socket, field),
         %{"_type" => _} = def <- PortableText.find_def(stored_body(socket, field), key),
         {:ok, dialog} <- dialog_for(socket, field_def, :annotation, def) do
      {:noreply, assign(socket, object_dialog: dialog)}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("This annotation cannot be opened in a form."))}
    end
  end

  def open_def(_params, socket), do: {:noreply, socket}

  @doc """
  Add an annotation of a declared type under the `_key` the editor made, on
  the text the editor marked with it, and open its dialog.
  """
  def insert_def(%{"field" => field, "type" => type, "key" => key, "html" => html}, socket)
      when is_binary(field) and is_binary(type) and is_binary(key) and is_binary(html) do
    with {:ok, field_def} <- portable_text_field(socket, field),
         true <- type in declared_names(field_def, :annotation),
         true <- fresh_key?(socket, field, key),
         {:ok, raw} <- member_raw_for(socket, field_def, :annotation, type) do
      def = new_object(raw, type, key)
      stored = stored_body(socket, field)
      blocks = PortableText.from_html(html, stored, field: field_def, defs: %{key => def})

      socket =
        socket
        |> write_body(field, blocks)
        |> push_event("bp:pt-def-ready", %{field: field, key: key, ok: true})

      case dialog_for(socket, field_def, :annotation, def) do
        {:ok, dialog} -> {:noreply, assign(socket, object_dialog: dialog)}
        _ -> {:noreply, socket}
      end
    else
      _ ->
        {:noreply,
         socket
         |> push_event("bp:pt-def-ready", %{field: field, key: key, ok: false})
         |> put_flash(:error, gettext("This annotation cannot be added here."))}
    end
  end

  def insert_def(_params, socket), do: {:noreply, socket}

  # ── inline objects ──────────────────────────────────────────────────────

  @doc "Open the dialog of the inline object with this `_key`."
  def open_inline(%{"field" => field, "key" => key} = params, socket)
      when is_binary(field) and is_binary(key) do
    socket = flush_html(socket, field, params["html"])

    with {:ok, field_def} <- portable_text_field(socket, field),
         %{"_type" => _} = object <- PortableText.find_inline(stored_body(socket, field), key),
         {:ok, dialog} <- dialog_for(socket, field_def, :inline, object) do
      {:noreply, assign(socket, object_dialog: dialog)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("This item cannot be opened in a form."))}
    end
  end

  def open_inline(_params, socket), do: {:noreply, socket}

  @doc """
  Add an inline object of a declared type under the `_key` the editor made,
  where the editor put its placeholder, and open its dialog.
  """
  def insert_inline(%{"field" => field, "type" => type, "key" => key, "html" => html}, socket)
      when is_binary(field) and is_binary(type) and is_binary(key) and is_binary(html) do
    with {:ok, field_def} <- portable_text_field(socket, field),
         true <- type in declared_names(field_def, :inline),
         true <- fresh_key?(socket, field, key),
         {:ok, raw} <- member_raw_for(socket, field_def, :inline, type) do
      object = new_object(raw, type, key)
      stored = stored_body(socket, field)
      blocks = PortableText.from_html(html, stored, field: field_def, objects: %{key => object})

      socket =
        socket
        |> write_body(field, blocks)
        |> push_event("bp:pt-inline-ready", %{
          field: field,
          key: key,
          html: PortableText.inline_html(object)
        })

      case dialog_for(socket, field_def, :inline, object) do
        {:ok, dialog} -> {:noreply, assign(socket, object_dialog: dialog)}
        _ -> {:noreply, socket}
      end
    else
      _ ->
        {:noreply,
         socket
         |> push_event("bp:pt-inline-ready", %{field: field, key: key, html: nil})
         |> put_flash(:error, gettext("This item cannot be inserted here."))}
    end
  end

  def insert_inline(_params, socket), do: {:noreply, socket}

  @doc """
  Remove the open annotation from its text: the mark definition goes from
  every block and its mark from every span. The text stays.
  """
  def remove(%{assigns: %{object_dialog: %{kind: :annotation} = dialog}} = socket) do
    field = dialog.field
    stored = PortableText.drop_def(stored_body(socket, field), dialog.key)

    blocks =
      case Map.get(socket.assigns[:editor_form] || %{}, field) do
        html when is_binary(html) and html != "" ->
          PortableText.from_html(html, stored, field_opts(socket, field))

        _ ->
          stored
      end

    {:noreply,
     socket
     |> write_body(field, blocks)
     |> push_event("bp:pt-def-remove", %{field: field, key: dialog.key})
     |> assign(object_dialog: nil)}
  end

  def remove(socket), do: {:noreply, socket}

  # ── change, array buttons, save, close ──────────────────────────────────

  def change(params, %{assigns: %{object_dialog: %{} = dialog}} = socket) do
    dialog = track_touched(dialog, params)
    posted = fold(params, dialog)
    value = Forms.object_from_form(dialog.member_raw, posted, dialog.stored)
    {:noreply, assign(socket, object_dialog: %{dialog | value: value})}
  end

  def change(_params, socket), do: {:noreply, socket}

  def array_op(%{"action" => action} = params, %{assigns: %{object_dialog: %{} = d}} = socket) do
    path =
      case Path.parse_path(params["path"] || "") do
        [@root | rest] -> rest
        _ -> []
      end

    field =
      if path == [], do: nil, else: Path.field_at(d.member_raw["fields"] || [], path, d.value)

    if is_nil(field) do
      {:noreply, socket}
    else
      idx = Shared.parse_idx(params["index"])
      current = Path.list_value_at(d.value, path)

      list =
        case action do
          "add_row" ->
            # The block itself carries a `_key`, so a list inside it is Sanity-shaped.
            BarkparkWeb.Studio.StudioLive.Handlers.Fields.add_row(
              current,
              field,
              params["member"],
              true
            )

          "remove_row" ->
            ArrayField.remove_row(current, idx)

          "move_up" ->
            ArrayField.move_up(current, idx)

          "move_down" ->
            ArrayField.move_down(current, idx)

          _ ->
            current
        end

      {:noreply,
       assign(socket, object_dialog: %{d | value: Path.put_value_at(d.value, path, list)})}
    end
  end

  def array_op(_params, socket), do: {:noreply, socket}

  def save(params, %{assigns: %{object_dialog: %{} = dialog}} = socket) do
    dialog = track_touched(dialog, params)

    value =
      case params do
        %{} = p when map_size(p) > 0 ->
          Forms.object_from_form(dialog.member_raw, fold(p, dialog), dialog.stored)

        _ ->
          dialog.value
      end

    # The object keeps its identity whatever the form posted.
    value = Map.merge(value, Map.take(dialog.stored, ["_type", "_key"]))
    field = dialog.field
    body = stored_body(socket, field)

    stored =
      case dialog.kind do
        :annotation ->
          PortableText.put_def(body, dialog.key, value)

        :inline ->
          PortableText.put_inline(body, dialog.key, value)

        :block ->
          Enum.map(body, fn
            %{"_key" => k} when k == dialog.key -> value
            other -> other
          end)
      end

    blocks =
      case Map.get(socket.assigns[:editor_form] || %{}, field) do
        html when is_binary(html) and html != "" ->
          PortableText.from_html(html, stored, field_opts(socket, field))

        _ ->
          stored
      end

    socket =
      socket
      |> write_body(field, blocks)
      |> push_update(dialog, value)
      |> assign(object_dialog: nil)

    {:noreply, socket}
  end

  def save(_params, socket), do: {:noreply, socket}

  def close(socket), do: {:noreply, assign(socket, object_dialog: nil)}

  defp push_update(socket, %{kind: :annotation} = dialog, value) do
    push_event(socket, "bp:pt-def-update", %{
      field: dialog.field,
      key: dialog.key,
      href: PortableText.def_href(value)
    })
  end

  defp push_update(socket, %{kind: :inline} = dialog, value) do
    push_event(socket, "bp:pt-inline-update", %{
      field: dialog.field,
      key: dialog.key,
      html: PortableText.inline_html(value)
    })
  end

  defp push_update(socket, dialog, value) do
    push_event(socket, "bp:pt-block-update", %{
      field: dialog.field,
      key: dialog.key,
      html: PortableText.to_html([value])
    })
  end

  # ── what the editor offers ──────────────────────────────────────────────

  @doc """
  The custom block types a richText field offers in "Insert block", in
  declaration order: the `blocks.of` entries that name a type (`"quote"`,
  `{"name": "quote", "title": "Sitat"}`). The built-in PortableDoc block names
  (`paragraph`, `heading`, …) are not custom blocks and are left out.
  """
  def insertable_types(%{"blocks" => %{"of" => of}}) when is_list(of) do
    builtin = Barkpark.PortableDoc.FieldVocabulary.default_declaration()["of"] || []
    builtin = Enum.flat_map(List.wrap(builtin), &List.wrap(entry_name(&1)))

    for entry <- of,
        name = entry_name(entry),
        is_binary(name),
        name not in builtin do
      %{name: name, title: entry_title(entry) || name}
    end
    |> Enum.uniq_by(& &1.name)
  end

  def insertable_types(_), do: []

  defp entry_name(name) when is_binary(name), do: name
  defp entry_name(%{"name" => name}) when is_binary(name), do: name
  defp entry_name(%{"type" => name}) when is_binary(name), do: name
  defp entry_name(_), do: nil

  defp entry_title(%{"title" => t}) when is_binary(t) and t != "", do: t
  defp entry_title(_), do: nil

  # ── internals ───────────────────────────────────────────────────────────

  # The field must be a richText whose stored value is Portable Text, or empty.
  defp portable_text_field(socket, field) do
    case Shared.find_field(socket, field) do
      %{"type" => "richText"} = f ->
        case stored_body_raw(socket, field) do
          nil -> {:ok, f}
          [] -> {:ok, f}
          list -> if PortableText.value?(list), do: {:ok, f}, else: :error
        end

      _ ->
        :error
    end
  end

  defp field_opts(socket, field) do
    case Shared.find_field(socket, field) do
      %{} = f -> [field: f]
      _ -> []
    end
  end

  defp stored_body_raw(socket, field) do
    case socket.assigns[:editor_doc] do
      %{content: %{} = content} -> Map.get(content, field)
      _ -> nil
    end
  end

  defp stored_body(socket, field) do
    case stored_body_raw(socket, field) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp stored_block(socket, field, key) do
    Enum.find(stored_body(socket, field), &match?(%{"_key" => ^key}, &1))
  end

  defp dialog_for(socket, field, %{"_type" => type} = block) do
    with {:ok, raw} <- member_raw(socket, type), do: dialog_from(field, :block, raw, block)
  end

  defp dialog_for(_socket, _field, _block), do: :error

  defp dialog_for(socket, %{"name" => field} = field_def, kind, %{"_type" => type} = object) do
    with {:ok, raw} <- member_raw_for(socket, field_def, kind, type),
         do: dialog_from(field, kind, raw, object)
  end

  defp dialog_for(_socket, _field_def, _kind, _object), do: :error

  defp dialog_from(field, kind, raw, %{"_type" => type, "_key" => key} = object) do
    member = Adapter.field_struct(Map.put(raw, "name", type))

    {:ok,
     %{
       kind: kind,
       field: field,
       key: key,
       type: type,
       title: member.title || type,
       member: member,
       member_raw: raw,
       value: object,
       stored: object,
       touched: MapSet.new()
     }}
  end

  defp dialog_from(_field, _kind, _raw, _object), do: :error

  defp member_raw(socket, type) do
    Schema.object_type_field(type, socket.assigns.dataset, ScopeHelpers.scope_opts(socket))
  end

  # Sanity's default `link` annotation, for a field that declares `link`
  # without fields (or leaves annotations to the Sanity default).
  @default_link_fields [%{"name" => "href", "type" => "url", "title" => "URL"}]

  # The form of an annotation or inline object: the fields its vocabulary
  # entry declares, else the fields of the object type it names.
  defp member_raw_for(socket, field_def, kind, type) do
    entry =
      field_def
      |> Map.get("blocks", %{})
      |> case do
        %{} = b -> List.wrap(b[vocabulary_key(kind)])
        _ -> []
      end
      |> Enum.find(&(entry_name(&1) == type))

    fields =
      case entry do
        %{"fields" => [_ | _] = fields} -> Enum.filter(fields, &is_map/1)
        _ -> []
      end

    cond do
      fields != [] ->
        {:ok, composite(type, entry_title(entry), fields)}

      kind == :annotation and type == "link" ->
        {:ok, composite(type, entry_title(entry), @default_link_fields)}

      true ->
        member_raw(socket, type)
    end
  end

  defp composite(type, title, fields) do
    %{"type" => "composite", "name" => type, "title" => title || type, "fields" => fields}
  end

  defp vocabulary_key(:annotation), do: "annotations"
  defp vocabulary_key(:inline), do: "inline"

  # The annotation or inline object type names the field declares.
  defp declared_names(field_def, kind) do
    key = if kind == :annotation, do: "annotations", else: "inline"

    case PortableText.editor_vocabulary(field_def) do
      %{^key => entries} -> Enum.map(entries, & &1["name"])
      _ -> []
    end
  end

  # A key the editor made: a short token no block, span, mark definition or
  # inline object of the body already holds.
  defp fresh_key?(socket, field, key) do
    Regex.match?(~r/\A[A-Za-z0-9_-]{4,64}\z/, key) and
      not Enum.any?(stored_body(socket, field), fn block ->
        block["_key"] == key or
          Enum.any?(List.wrap(block["markDefs"]) ++ List.wrap(block["children"]), fn
            %{"_key" => ^key} -> true
            _ -> false
          end)
      end)
  end

  defp new_object(raw, type, key) do
    raw
    |> Map.get("fields", [])
    |> Path.seed_defaults()
    |> Map.put("_type", type)
    |> Map.put("_key", key)
  end

  # The editor's latest HTML, written before the dialog reads the stored body,
  # so the dialog and the next save start from what the editor shows.
  defp flush_html(socket, field, html) when is_binary(html) and html != "" do
    stored = stored_body(socket, field)

    cond do
      Map.get(socket.assigns[:editor_form] || %{}, field) == html -> socket
      # The browser serialises the same body a little differently (entities,
      # attribute order); a body that converts back to the stored blocks is
      # not an edit, and writing it would make a draft identical to the
      # published document.
      PortableText.from_html(html, stored, field_opts(socket, field)) == stored -> socket
      true -> Shared.do_autosave(socket, %{field => html}, :pt_block)
    end
  end

  defp flush_html(socket, _field, _html), do: socket

  # Write the body as blocks, then keep the form buffer an HTML string: the
  # Classic input is a contenteditable that edits HTML.
  defp write_body(socket, field, blocks) do
    socket = Shared.do_autosave(socket, %{field => blocks}, :pt_block)
    form = socket.assigns[:editor_form] || %{}
    assign(socket, editor_form: Map.put(form, field, PortableText.to_html(blocks)))
  end

  defp replace_pending(html, pending, box) do
    pattern = ~r/<div[^>]*data-pt-pending="#{Regex.escape(pending)}"[^>]*>.*?<\/div>/s

    if Regex.match?(pattern, html),
      do: Regex.replace(pattern, html, box, global: false),
      else: html <> box
  end

  # `_target` names the input that fired the change; an input the editor never
  # touched that holds nothing stored is not written (no phantom `""`/`false`).
  defp track_touched(dialog, params) do
    targets =
      params
      |> Map.get("_target")
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    %{dialog | touched: MapSet.union(dialog.touched, MapSet.new(targets))}
  end

  defp fold(params, dialog) do
    params
    |> Path.unmangle_params()
    |> Enum.filter(fn {k, _v} -> is_binary(k) and String.starts_with?(k, @prefix) end)
    |> Enum.reduce(dialog.value, fn {k, v}, acc ->
      case Path.parse_path(k) do
        [@root | [_ | _] = path] ->
          if keep?(k, v, path, dialog), do: Path.put_value_at(acc, path, v), else: acc

        _ ->
          acc
      end
    end)
  end

  defp keep?(_key, nil, _path, _dialog), do: false

  defp keep?(key, v, path, dialog) do
    MapSet.member?(dialog.touched, key) or not is_nil(get_path(dialog.stored, path)) or
      (v not in ["", "false"] and not untouched_default?(v, path, dialog))
  end

  # A select or radio that shows its declared default posts it untouched.
  defp untouched_default?(v, path, dialog) do
    case Path.field_at(dialog.member_raw["fields"] || [], path, dialog.value) do
      %{"default" => d} -> to_string(d) == v
      _ -> false
    end
  end

  defp get_path(v, []), do: v
  defp get_path(%{} = m, [k | rest]) when is_binary(k), do: get_path(Map.get(m, k), rest)

  defp get_path(l, [i | rest]) when is_list(l) and is_integer(i),
    do: get_path(Enum.at(l, i), rest)

  defp get_path(_, _), do: nil
end
