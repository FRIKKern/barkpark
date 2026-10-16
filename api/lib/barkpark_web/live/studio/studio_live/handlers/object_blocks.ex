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

  The dialog state lives in `socket.assigns.object_dialog`:

      %{field: "body", key: "a1b2c3d4e5f6", type: "quote", title: "Sitat",
        member: %Field{}, member_raw: %{...}, value: %{...}, stored: %{...},
        touched: MapSet.t()}
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
      blocks = PortableText.from_html(html, stored ++ [block])

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

    # The block keeps its identity whatever the form posted.
    value = Map.merge(value, Map.take(dialog.stored, ["_type", "_key"]))
    field = dialog.field

    stored =
      Enum.map(stored_body(socket, field), fn
        %{"_key" => k} when k == dialog.key -> value
        other -> other
      end)

    blocks =
      case Map.get(socket.assigns[:editor_form] || %{}, field) do
        html when is_binary(html) and html != "" -> PortableText.from_html(html, stored)
        _ -> stored
      end

    socket =
      socket
      |> write_body(field, blocks)
      |> push_event("bp:pt-block-update", %{
        field: field,
        key: dialog.key,
        html: PortableText.to_html([value])
      })
      |> assign(object_dialog: nil)

    {:noreply, socket}
  end

  def save(_params, socket), do: {:noreply, socket}

  def close(socket), do: {:noreply, assign(socket, object_dialog: nil)}

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

  defp dialog_for(socket, field, %{"_type" => type, "_key" => key} = block) do
    with {:ok, raw} <- member_raw(socket, type) do
      member = Adapter.field_struct(Map.put(raw, "name", type))

      {:ok,
       %{
         field: field,
         key: key,
         type: type,
         title: member.title || type,
         member: member,
         member_raw: raw,
         value: block,
         stored: block,
         touched: MapSet.new()
       }}
    end
  end

  defp dialog_for(_socket, _field, _block), do: :error

  defp member_raw(socket, type) do
    Schema.object_type_field(type, socket.assigns.dataset, ScopeHelpers.scope_opts(socket))
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
      PortableText.from_html(html, stored) == stored -> socket
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
