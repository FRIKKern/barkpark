defmodule BarkparkWeb.Studio.StudioLive.Handlers.Fields do
  @moduledoc """
  Document lifecycle (new/save/autosave) + editor toggles + ArrayField ops.
  Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias BarkparkWeb.Components.Fields.ArrayField
  alias BarkparkWeb.Studio.StudioLive
  alias BarkparkWeb.Studio.StudioLive.Shared

  # The Studio's display default for a brand-new row's `title` FIELD.
  @untitled "Untitled"

  # Types whose title is NOT a plain field but the text of a locked title
  # BLOCK. Mirrors `Writer.maybe_apply_paper_template/2`, which seeds the paper
  # template for "paper" and nothing else.
  #
  # [untitled-is-a-fallback-not-a-seed] A paper is born WITHOUT a title, on
  # purpose. `Papers.Template.template_blocks/1` copies the attrs title
  # verbatim into the locked `tpl-title` heading's `"text"`, so seeding
  # "Untitled" here did not write chrome — it wrote CONTENT, into the one block
  # the author is about to type in, and the caret landing after it made the
  # first keystroke APPEND ("UntitledHand walk…"). Every display site already
  # renders `doc.title || "Untitled"` (pane_builder, components, secondary,
  # refs, editor_fields, modals), so a nil title still reads "Untitled" on the
  # desk, the breadcrumb and the tab — while the title block itself starts
  # empty and the editor paints its own heading placeholder. `derive_title/2`
  # then fills the row title from the block the moment the author types, which
  # is the single-truth contract the literal was quietly pre-empting.
  @block_titled_types ["paper"]

  def new_document(%{"type" => type}, socket) do
    # No hand-rolled `doc_id`: the old `"#{type}-#{:rand.uniform(999_999)}"`
    # drew from a 1M-value space, so on a populated dataset a collision landed
    # in the writer's UPDATE branch and SILENTLY overwrote an unrelated doc (or
    # failed as an opaque "Failed to create"). Omitting `"doc_id"` lets
    # `Content.create_document` mint one via the canonical `generate_id/1`
    # (`<type>-<64 bits of strong entropy>`) — same readable shape, negligible
    # collision odds. See [doc-id-collision-overwrite] in content/writer.ex.
    case Content.create_document(
           type,
           new_document_attrs(type),
           socket.assigns.dataset,
           Shared.hook_opts(socket)
         ) do
      {:ok, doc} ->
        pub_id = Content.published_id(doc.doc_id)
        new_path = socket.assigns.nav_path ++ [pub_id]

        {:noreply,
         push_patch(socket, to: Shared.studio_path(socket, new_path, socket.assigns.dataset))}

      {:error, {:halted, reason}} ->
        {:noreply, put_flash(socket, :error, "Create cancelled: #{reason}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create")}
    end
  end

  # See [untitled-is-a-fallback-not-a-seed] above.
  defp new_document_attrs(type) do
    attrs = %{"content" => Shared.seed_new_doc_content(type)}

    if type in @block_titled_types,
      do: attrs,
      else: Map.put(attrs, "title", @untitled)
  end

  def save(params, socket) when is_map(params) do
    case fold_dot_paths(params) do
      %{"doc" => doc} -> do_save(doc, socket)
      _ -> {:noreply, socket}
    end
  end

  def save(_params, socket), do: {:noreply, socket}

  defp do_save(params, socket) do
    socket = Shared.do_autosave(socket, params)

    case socket.assigns[:save_status] do
      "Saved" ->
        # An explicit save reloads the editor from the just-persisted row —
        # the local buffer is now clean, so drop the dirty flag and any
        # stale concurrent-edit banner.
        socket =
          socket
          |> put_flash(:info, "Saved")
          |> Shared.rebuild_panes()
          |> assign(editor_dirty: false, doc_conflict: false)

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # Reload the open doc from the DB after a concurrent edit by another user,
  # discarding the local buffer. Clears the conflict banner + dirty flag.
  def reload_remote_doc(socket) do
    socket =
      socket
      |> Shared.rebuild_panes()
      |> assign(editor_dirty: false, doc_conflict: false)

    {:noreply, socket}
  end

  def slug_generate(%{"field" => field}, socket) do
    title =
      case Map.get(socket.assigns[:editor_form] || %{}, "title") do
        t when is_binary(t) and t != "" -> t
        _ -> socket.assigns[:editor_doc] && socket.assigns.editor_doc.title
      end

    case title do
      t when is_binary(t) and t != "" ->
        {:noreply,
         mark_dirty(Shared.do_autosave(socket, %{field => Barkpark.Tenancy.slugify(t)}))}

      _ ->
        {:noreply, socket}
    end
  end

  def autosave(params, socket) when is_map(params) do
    case fold_dot_paths(params) do
      %{"doc" => doc} -> {:noreply, mark_dirty(Shared.do_autosave(socket, doc))}
      _ -> {:noreply, socket}
    end
  end

  def autosave(_params, socket) do
    {:noreply, socket}
  end

  # ── The dot-path fold (S9 crit 3, task-6d80c6cc7d97b1d1) ────────────────────
  #
  # `LocalizedTextField` renders its per-language inputs with a BRACKET
  # envelope followed by a DOT segment — `name="doc[altText].nob"` — and the
  # nested composite / array renderers compose the same shape.
  # `Plug.Conn.Query.decode/1`, which Phoenix applies to the serialized form,
  # only nests BRACKET segments: a trailing `.nob` is not one, so that input
  # arrives as a FLAT top-level key `"doc[altText].nob"` and never lands inside
  # the `"doc"` map `Shared.do_autosave/2` writes from.
  #
  # The value was therefore DISCARDED on every save. That is why an editor
  # still could not write alt text once the asset panel opened: the field
  # rendered, took the keystrokes, and dropped them.
  #
  # `StudioLive.parse_path/1` already understands exactly this shape — it is
  # what `array_op/2` parses its `phx-value-path` with, and it strips the
  # `doc[` envelope itself. Folding here reuses that parser rather than adding
  # a second reading of the same syntax, and it changes NOTHING that is
  # rendered: the input names stay as they are, so the paper-canvas and ONIX
  # surfaces that also emit them keep their markup and simply start persisting.
  #
  # Fold only when there is something to fold: an untouched params map must
  # come back byte-identical, or a payload with no `"doc"` key at all would
  # gain an empty one and save a blank document over a real one.
  defp fold_dot_paths(params) do
    {dotted, rest} =
      Enum.split_with(params, fn {k, _v} ->
        is_binary(k) and String.starts_with?(k, "doc[")
      end)

    if dotted == [] do
      params
    else
      rest = Map.new(rest)
      doc = Map.get(rest, "doc", %{})

      doc =
        Enum.reduce(dotted, doc, fn {key, value}, acc ->
          case StudioLive.parse_path(key) do
            [] -> acc
            path -> StudioLive.put_value_at(acc, path, value)
          end
        end)

      Map.put(rest, "doc", doc)
    end
  end

  def toggle_content_preview(socket) do
    {:noreply, assign(socket, content_preview_visible: !socket.assigns.content_preview_visible)}
  end

  def toggle_diff(socket) do
    {:noreply, assign(socket, diff_visible: !socket.assigns.diff_visible)}
  end

  def editor_set_mode(%{"mode" => mode}, socket) do
    next =
      case mode do
        "beta" -> if Shared.beta_editable?(socket), do: :beta, else: :classic
        _ -> :classic
      end

    socket =
      if next == :beta, do: Shared.sync_editor_blocks(socket), else: socket

    {:noreply, assign(socket, editor_mode: next)}
  end

  def array_op(%{"action" => action} = params, socket) do
    path = StudioLive.parse_path(params["path"] || "")

    {field, key_path} =
      case path do
        [] ->
          case params["field"] do
            name when is_binary(name) -> {Shared.find_field(socket, name), [name]}
            _ -> {nil, []}
          end

        _ ->
          {Shared.find_field_by_path(socket, path), path}
      end

    if is_nil(field) or key_path == [] do
      {:noreply, socket}
    else
      idx = Shared.parse_idx(params["index"])
      form = socket.assigns[:editor_form] || %{}
      current = StudioLive.list_value_at(form, key_path)

      new_list =
        case action do
          "add_row" -> ArrayField.add_row(current, StudioLive.empty_for_of(field))
          "remove_row" -> ArrayField.remove_row(current, idx)
          "move_up" -> ArrayField.move_up(current, idx)
          "move_down" -> ArrayField.move_down(current, idx)
          _ -> current
        end

      new_form = StudioLive.put_value_at(form, key_path, new_list)
      {:noreply, mark_dirty(Shared.do_autosave(socket, new_form))}
    end
  end

  # A user-driven form edit leaves the browser buffer ahead of the last remote
  # snapshot. `editor_dirty` gates the concurrent-edit clobber in
  # `Handlers.Lifecycle.doc_updated/2` + `document_changed/2`: while it's set, a
  # remote save surfaces a "reload?" banner instead of overwriting the buffer.
  # Reset on navigation (finish_handle_params), explicit save, and reload.
  defp mark_dirty(socket), do: assign(socket, editor_dirty: true)
end
