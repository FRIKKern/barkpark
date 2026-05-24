defmodule BarkparkWeb.Studio.StudioLive do
  @moduledoc """
  Multi-pane studio — mirrors the TUI's pane drill-down.
  Structure → Type → Documents → Editor
  """
  use BarkparkWeb, :live_view

  alias Barkpark.{Content, Media, Structure}
  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Components.Fields.ArrayField
  alias BarkparkWeb.Presence
  alias BarkparkWeb.Studio.{PaneBuilder, PresenceState}

  # `raw/1` lives in Phoenix.HTML; the :live_view macro imports
  # Phoenix.HTML.Form but not the parent module, so import it here for the
  # in-Studio paper block view (mirrors PaperLive).
  import Phoenix.HTML, only: [raw: 1]

  @impl true
  def mount(_params, _session, socket) do
    # Read identity from client localStorage via connect params
    connect_params = get_connect_params(socket) || %{}
    user_id = connect_params["user_id"] || PresenceState.generate_user_id()
    stored_name = connect_params["user_name"]
    stored_color = connect_params["user_color"]

    user_name =
      if stored_name && stored_name != "",
        do: stored_name,
        else: "User #{String.slice(user_id, 0..3)}"

    user_color =
      if stored_color && stored_color != "",
        do: stored_color,
        else: PresenceState.pick_color(user_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, PresenceState.topic())
    end

    {:ok,
     socket
     |> assign(
       nav_section: :structure,
       page_title: "Studio",
       subscribed_doc: nil,
       image_picker_field: nil,
       media_files: [],
       ref_picker_field: nil,
       ref_candidates: [],
       ref_search: "",
       show_history: false,
       revisions: [],
       show_delete: false,
       delete_refs: [],
       user_id: user_id,
       user_name: user_name,
       user_color: user_color,
       presences: [],
       show_profile: false,
       validation_errors: %{},
       # ── Cross-field validations (Task barkpark-cgn) ──────────────────
       # Populated after every autosave by `Barkpark.Content.CrossValidator
       # .violations/2`. Each entry is a string-keyed map carrying name,
       # title, level (error|warning), and fields. The editor banner reads
       # this assign directly; non-rule schemas keep `[]` and never render
       # the banner row.
       cross_violations: [],
       confirm_modal: nil,
       nav_group: nil,
       # ── Content preview side-pane (Goal barkpark-G1, task s3) ─────────
       # Doc-type-agnostic. Pane is rendered iff a plugin's
       # `content_renderer/3` callback contributes iodata via
       # `Plugins.Registry.collect_content_renderer/3` AND the user has
       # not toggled the pane off. With plugins=[] this assign stays
       # nil → pane is absent from the layout (fresh-install
       # invariant, Goal `barkpark-G1`).
       content_preview_rendered: nil,
       content_preview_visible: true,
       # ── Document actions (Task barkpark-3yq) ─────────────────────────
       # E2 split-view: read-only secondary editor pane.
       secondary_doc: nil,
       secondary_schema: nil,
       secondary_type: nil,
       show_secondary_picker: false,
       secondary_search: "",
       secondary_candidates: [],
       # E3 bulk publish: per-pane multi-select MapSet of published ids.
       selected_doc_ids: MapSet.new(),
       bulk_status: nil,
       # ── Draft-vs-Published diff view (Task barkpark-uix) ─────────────
       # `diff_visible` toggles the editor pane between the form and the
       # field-level diff table. `published_doc` is the fetched published
       # twin of the current draft (nil when no draft is open, or when
       # the draft has no published counterpart). The toggle button in
       # the editor header only surfaces when both sides exist.
       diff_visible: false,
       published_doc: nil,
       # ── In-Studio live paper view (convergence/papers-in-studio) ─────
       # A paper opens LIVE inside the editor pane (read-only block stream),
       # NOT the field form. `editor_view` is `:paper` while a paper is open,
       # `:form` (the default) otherwise. The paper's per-doc topic is
       # subscribed at open; `{:paper_block,…}` / `{:paper_updated,…}` frames
       # update the pane in place with NO remount — mirroring PaperLive's
       # streaming. `paper_rev` tracks the last applied monotonic streaming
       # rev for gap detection; `paper_block_mode` flips false for HTML-only
       # papers (the raw-HTML fallback). `paper_topic` is the subscribed
       # topic so it can be unsubscribed on navigation.
       editor_view: :form,
       paper_doc: nil,
       paper_rev: 0,
       paper_html: "",
       paper_block_mode: false,
       paper_topic: nil,
       # ── In-Studio paper block editor (convergence/studio-paper-editor) ───
       # `paper_edit_mode` flips the paper pane between the read-only live
       # stream (View — the default, unchanged) and the block edit form (Edit).
       # In Edit mode each per-block control fires a `paper-*` event that maps
       # to ONE DocPatchOp and calls `Content.apply_paper_block_op/3`; the
       # resulting `{:paper_block,…}` delta flows through the SAME stream
       # handler that a remote viewer sees, so the View stays in sync and the
       # pane never remounts. `paper_edit_block` builds the edit form straight
       # from `paper_doc.content["blocks"]` (the source of truth, refetched
       # after every op) — it never bypasses the op pipeline.
       paper_edit_mode: false
     )
     |> stream(:paper_blocks, [])
     |> allow_upload(:image,
       accept: ~w(.jpg .jpeg .png .gif .webp .svg),
       max_entries: 1,
       max_file_size: 10_000_000
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    dataset = params["dataset"] || "production"
    path = Map.get(params, "path", [])
    desk = params["desk"]

    if connected?(socket) and socket.assigns[:dataset] != dataset do
      if old = socket.assigns[:dataset] do
        Phoenix.PubSub.unsubscribe(Barkpark.PubSub, "documents:#{old}")
      end

      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")
    end

    current_path =
      case uri do
        u when is_binary(u) ->
          case URI.parse(u) do
            %URI{path: p} when is_binary(p) -> p
            _ -> nil
          end

        _ ->
          nil
      end

    socket =
      socket
      |> assign(
        dataset: dataset,
        nav_path: path,
        nav_desk: desk,
        current_path: current_path
      )
      |> rebuild_panes()
      |> subscribe_to_doc()
      |> track_presence()

    {:noreply, socket}
  end

  # Doc-specific update — just patch the editor form, no rebuild
  @impl true
  def handle_info({:doc_updated, %{sender: sender, doc: doc_data}}, socket) do
    if sender != self() && socket.assigns[:editor_doc] do
      # Another user edited this doc — update form values live
      schema = socket.assigns[:editor_schema]
      updated_form = Content.doc_to_form(doc_data, schema)

      {:noreply,
       assign(socket, editor_form: updated_form, save_status: "Updated by another user")}
    else
      {:noreply, socket}
    end
  end

  # ── In-Studio live paper deltas (convergence/papers-in-studio) ──────────────
  #
  # A paper open in the editor pane subscribes to its per-doc topic
  # (`doc:<dataset>:paper:<slug>` == Content.paper_topic/2). These frames patch
  # the block stream / HTML in place — NO rebuild_panes, NO remount. Mirrors
  # PaperLive's delta handling so the Gate-B streaming property holds inside
  # the Studio. Frames that arrive while no paper is open are ignored.

  @impl true
  def handle_info({:paper_block, frame}, socket) do
    cond do
      socket.assigns[:editor_view] != :paper ->
        {:noreply, socket}

      # First block delta to a view still in HTML-only mode: no stream to
      # append onto — adopt the block list wholesale via a refetch.
      not socket.assigns.paper_block_mode ->
        {:noreply, refetch_paper(socket)}

      # Missed a frame — refetch the whole doc and re-stream from scratch.
      paper_gap?(socket.assigns.paper_rev, frame.rev) ->
        {:noreply, refetch_paper(socket)}

      true ->
        socket = apply_paper_delta(socket, frame)
        # In Edit mode the per-block form reads from `paper_doc.content`, so it
        # must track the new block list too — refresh just the in-memory doc
        # (the stream already advanced via apply_paper_delta). This keeps the
        # editor form correct whether the delta came from THIS pane's own op or
        # from another source (a remote viewer / the ingest endpoint), proving
        # edits-are-ops both ways.
        socket =
          if socket.assigns[:paper_edit_mode], do: sync_paper_edit_doc(socket), else: socket

        {:noreply, socket}
    end
  end

  def handle_info({:paper_updated, %{html: html} = msg}, socket) do
    if socket.assigns[:editor_view] == :paper do
      {:noreply,
       socket
       |> assign(:paper_html, html)
       |> assign(:paper_block_mode, false)
       |> assign(:paper_rev, msg[:rev] || socket.assigns.paper_rev)}
    else
      {:noreply, socket}
    end
  end

  # Presence updates
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, presences: PresenceState.list())}
  end

  # Global doc change — rebuild if we're viewing this type
  @impl true
  def handle_info({:document_changed, %{type: type}}, socket) do
    # Find which type we're viewing (may be nested under settings)
    viewing_type = socket.assigns[:editor_type] || Enum.at(socket.assigns.nav_path, 0)

    if viewing_type == type do
      {:noreply, rebuild_panes(socket)}
    else
      {:noreply, socket}
    end
  end

  # Autosave triggered programmatically (e.g. after image selection).
  # Indirection lets the picker close immediately (assign + close in the
  # click handler) and runs the save in a separate handle_info turn.
  @impl true
  def handle_info({:autosave_form, form}, socket) do
    {:noreply, do_autosave(socket, form)}
  end

  # Subscribe to the specific doc being edited
  defp subscribe_to_doc(socket) do
    old_sub = socket.assigns[:subscribed_doc]

    # Unsubscribe from old doc
    if old_sub do
      Phoenix.PubSub.unsubscribe(Barkpark.PubSub, old_sub)
    end

    # Subscribe to new doc if editing
    case socket.assigns do
      %{editor_type: type, editor_doc: %{doc_id: doc_id}} when not is_nil(type) ->
        topic = "doc:#{socket.assigns.dataset}:#{type}:#{Content.published_id(doc_id)}"
        Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
        assign(socket, subscribed_doc: topic)

      _ ->
        assign(socket, subscribed_doc: nil)
    end
  end

  defp track_presence(socket) do
    if connected?(socket) do
      # Determine what doc we're viewing
      doc_id =
        case socket.assigns do
          %{editor_doc: %{doc_id: did}, editor_type: type} when not is_nil(type) ->
            Content.published_id(did)

          _ ->
            nil
        end

      meta = %{
        doc_id: doc_id,
        type: socket.assigns[:editor_type],
        name: socket.assigns.user_name,
        color: socket.assigns.user_color,
        joined_at: System.system_time(:second)
      }

      # Use update if already tracked, track if new
      case Presence.get_by_key(PresenceState.topic(), socket.assigns.user_id) do
        [] -> Presence.track(self(), PresenceState.topic(), socket.assigns.user_id, meta)
        _ -> Presence.update(self(), PresenceState.topic(), socket.assigns.user_id, meta)
      end

      assign(socket, presences: PresenceState.list())
    else
      socket
    end
  end

  @impl true
  def handle_event("select", %{"pane" => pane_str, "id" => id}, socket) do
    pane_idx = String.to_integer(pane_str)
    new_path = Enum.take(socket.assigns.nav_path, pane_idx) ++ [id]
    {:noreply, push_patch(socket, to: studio_path(new_path, socket.assigns.dataset))}
  end

  # Schema-driven field-group tabs (Sanity Studio parity). Pure LV state —
  # no URL patch (decided against `?group=` in the task brief to keep the
  # route surface tight; the editor URL still uniquely identifies the doc).
  def handle_event("select-group", %{"group" => name}, socket) do
    {:noreply, assign(socket, nav_group: name)}
  end

  # Schema-declared desk groups (custom column filter chips on the
  # `:document_type_list` pane). The desk lives in the `?desk=…` query
  # param so the view is shareable/bookmarkable — switching desk
  # `push_patch`'s a new URL with the same nav_path. An empty/absent
  # desk drops the chip filter and reverts to the default flat list.
  def handle_event("select-desk", %{"desk" => name}, socket) do
    desk = if name == "" or name == socket.assigns[:nav_desk], do: nil, else: name

    {:noreply,
     push_patch(socket,
       to: studio_path(socket.assigns.nav_path, socket.assigns.dataset, desk: desk)
     )}
  end

  def handle_event("expand-pane", %{"idx" => idx_str}, socket) do
    # "Expand" a collapsed pane = truncate the nav path so this pane
    # becomes the active focus. Deeper drill-down (and the editor) drop
    # away, matching Sanity's breadcrumb-jump behavior.
    idx = String.to_integer(idx_str)
    new_path = Enum.take(socket.assigns.nav_path, idx)
    {:noreply, push_patch(socket, to: studio_path(new_path, socket.assigns.dataset))}
  end

  def handle_event("new-document", %{"type" => type}, socket) do
    id = "#{type}-#{:rand.uniform(999_999)}"

    case Content.create_document(
           type,
           %{"doc_id" => id, "title" => "Untitled"},
           socket.assigns.dataset,
           hook_opts(socket)
         ) do
      {:ok, doc} ->
        # The + button lives on the doc-list pane (a :document_type_list
        # node that carries type_name). We just append the new doc's
        # published id to the current nav path — this keeps any parent
        # filter view (e.g. "post/post-all") intact so walk_path can
        # resolve the editor. The old take_while logic dropped the
        # filter segment and produced a dead /post/<id> URL.
        pub_id = Content.published_id(doc.doc_id)
        new_path = socket.assigns.nav_path ++ [pub_id]
        {:noreply, push_patch(socket, to: studio_path(new_path, socket.assigns.dataset))}

      {:error, {:halted, reason}} ->
        {:noreply, put_flash(socket, :error, "Create cancelled: #{reason}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create")}
    end
  end

  def handle_event("save", %{"doc" => params}, socket) do
    socket = do_autosave(socket, params)

    case socket.assigns[:save_status] do
      "Saved" -> {:noreply, socket |> put_flash(:info, "Saved") |> rebuild_panes()}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("autosave", %{"doc" => params}, socket) do
    {:noreply, do_autosave(socket, params)}
  end

  # Toggle the content preview side-pane (Goal barkpark-G1, task s3).
  # Doc-type-agnostic — the button itself only renders when a plugin
  # contributed iodata for the open doc, so a stray event just flips a
  # hidden assign.
  def handle_event("toggle-content-preview", _, socket) do
    {:noreply, assign(socket, content_preview_visible: !socket.assigns.content_preview_visible)}
  end

  # Toggle the draft-vs-published diff view (Task barkpark-uix). The
  # button itself is rendered only when both a draft AND a published
  # twin exist (see studio_components.studio_editor_shell), so a stray
  # event when nothing is loaded just flips a hidden assign.
  def handle_event("toggle-diff", _, socket) do
    {:noreply, assign(socket, diff_visible: !socket.assigns.diff_visible)}
  end

  def handle_event("autosave", _params, socket) do
    {:noreply, socket}
  end

  # ── ArrayField reorder / add / remove events ───────────────────────────────
  #
  # ArrayField buttons (`+ Add`, `▲`, `▼`, `×`) all fire phx-click="array_op"
  # with phx-value-action ∈ {add_row, remove_row, move_up, move_down},
  # phx-value-field, and (for non-add ops) phx-value-index. This handler is
  # the bridge from those clicks into the public list helpers in
  # `BarkparkWeb.Components.Fields.ArrayField`, then autosaves the document
  # so the new structure lands in the DB.
  def handle_event("array_op", %{"action" => action} = params, socket) do
    path = parse_path(params["path"] || "")

    # path = [] means either path missing or path was just "doc[...]" with no
    # inner — fall back to flat field-name lookup so the original top-level
    # array op contract still works.
    {field, key_path} =
      case path do
        [] ->
          case params["field"] do
            name when is_binary(name) -> {find_field(socket, name), [name]}
            _ -> {nil, []}
          end

        _ ->
          {find_field_by_path(socket, path), path}
      end

    if is_nil(field) or key_path == [] do
      {:noreply, socket}
    else
      idx = parse_idx(params["index"])
      form = socket.assigns[:editor_form] || %{}
      current = list_value_at(form, key_path)

      new_list =
        case action do
          "add_row" -> ArrayField.add_row(current, empty_for_of(field))
          "remove_row" -> ArrayField.remove_row(current, idx)
          "move_up" -> ArrayField.move_up(current, idx)
          "move_down" -> ArrayField.move_down(current, idx)
          _ -> current
        end

      new_form = put_value_at(form, key_path, new_list)
      # Persist via the same path as autosave so panes + DB + validation all
      # stay in sync. do_autosave/2 assigns editor_form: new_form, so we
      # don't need a separate assign call.
      {:noreply, do_autosave(socket, new_form)}
    end
  end

  # ── Image field events ──────────────────────────────────────────────────────

  def handle_event("open-image-picker", %{"field" => field_name}, socket) do
    files = Media.list_files(socket.assigns.dataset, mime_type: "image/")
    {:noreply, assign(socket, image_picker_field: field_name, media_files: files)}
  end

  def handle_event("close-image-picker", _, socket) do
    {:noreply, assign(socket, image_picker_field: nil, media_files: [])}
  end

  def handle_event("select-media", %{"url" => url, "field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, url)
    socket = assign(socket, editor_form: form, image_picker_field: nil, media_files: [])
    # Trigger autosave with updated form
    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end

  def handle_event("clear-image", %{"field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, "")
    socket = assign(socket, editor_form: form)
    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end

  def handle_event("validate-upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload-image", %{"field" => field_name}, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
        plug_upload = %Plug.Upload{
          path: path,
          filename: entry.client_name,
          content_type: entry.client_type
        }

        case Media.upload(plug_upload, socket.assigns.dataset) do
          {:ok, file} -> {:ok, "/media/files/#{file.path}"}
          {:error, _} -> {:error, "upload failed"}
        end
      end)

    case uploaded_files do
      [url | _] ->
        form = Map.put(socket.assigns.editor_form, field_name, url)
        socket = assign(socket, editor_form: form, image_picker_field: nil, media_files: [])
        send(self(), {:autosave_form, form})
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Reference field events ─────────────────────────────────────────────────

  def handle_event("open-ref-picker", %{"field" => field_name, "ref-type" => ref_type}, socket) do
    docs = Content.list_documents(ref_type, socket.assigns.dataset, perspective: :drafts)

    candidates =
      Enum.map(docs, fn doc ->
        %{id: Content.published_id(doc.doc_id), title: doc.title || "Untitled"}
      end)

    {:noreply,
     assign(socket, ref_picker_field: field_name, ref_candidates: candidates, ref_search: "")}
  end

  def handle_event("close-ref-picker", _, socket) do
    {:noreply, assign(socket, ref_picker_field: nil, ref_candidates: [], ref_search: "")}
  end

  def handle_event("ref-search", %{"value" => query}, socket) do
    {:noreply, assign(socket, ref_search: query)}
  end

  def handle_event("select-ref", %{"id" => ref_id, "field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, ref_id)

    socket =
      assign(socket, editor_form: form, ref_picker_field: nil, ref_candidates: [], ref_search: "")

    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end

  # ── History events ──────────────────────────────────────────────────────────

  def handle_event("show-history", _, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      revisions = Content.list_revisions(doc.doc_id, type, socket.assigns.dataset, limit: 30)
      {:noreply, assign(socket, show_history: true, revisions: revisions)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-history", _, socket) do
    {:noreply, assign(socket, show_history: false, revisions: [])}
  end

  # ── Delete with reference check ─────────────────────────────────────────────

  def handle_event("delete-doc", _, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      refs = Content.find_referencing_docs(doc.doc_id, socket.assigns.dataset)
      {:noreply, assign(socket, show_delete: true, delete_refs: refs)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-delete", _, socket) do
    {:noreply, assign(socket, show_delete: false, delete_refs: [])}
  end

  def handle_event("confirm-delete", params, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      if params["disconnect"] == "true" do
        Content.disconnect_references(doc.doc_id, socket.assigns.dataset)
      end

      case Content.delete_document(doc.doc_id, type, socket.assigns.dataset, hook_opts(socket)) do
        {:error, {:halted, reason}} ->
          {:noreply,
           socket
           |> assign(show_delete: false, delete_refs: [])
           |> put_flash(:error, "Delete cancelled: #{reason}")}

        _ ->
          new_path = Enum.take(socket.assigns.nav_path, length(socket.assigns.nav_path) - 1)

          {:noreply,
           socket
           |> assign(show_delete: false, delete_refs: [])
           |> push_patch(to: studio_path(new_path, socket.assigns.dataset))}
      end
    else
      {:noreply, socket}
    end
  end

  # ── Profile edit events ──────────────────────────────────────────────────────

  def handle_event("show-profile", _, socket) do
    {:noreply, assign(socket, show_profile: true)}
  end

  def handle_event("close-profile", _, socket) do
    {:noreply, assign(socket, show_profile: false)}
  end

  def handle_event("jump-to-user", %{"type" => type, "doc-id" => doc_id}, socket) do
    # Build the path to that document — need to find it in the structure
    structure = Structure.build(socket.assigns.dataset)
    path = PaneBuilder.find_doc_path(structure, type, doc_id)
    {:noreply, push_patch(socket, to: studio_path(path, socket.assigns.dataset))}
  end

  def handle_event("preview-profile", %{"name" => name, "color" => color}, socket) do
    {:noreply, assign(socket, user_name: name, user_color: color)}
  end

  def handle_event("save-profile", %{"name" => name, "color" => color}, socket) do
    socket = assign(socket, user_name: name, user_color: color, show_profile: false)
    # Save to client localStorage via JS hook
    socket = push_event(socket, "save-identity", %{name: name, color: color})
    # Update presence with new identity
    {:noreply, track_presence(socket)}
  end

  def handle_event("restore-revision", %{"id" => rev_id}, socket) do
    type = socket.assigns[:editor_type]

    case Content.restore_revision(rev_id, type, socket.assigns.dataset, hook_opts(socket)) do
      {:ok, _doc} ->
        {:noreply,
         socket
         |> assign(show_history: false, revisions: [])
         |> put_flash(:info, "Restored from history")
         |> rebuild_panes()}

      {:error, {:halted, reason}} ->
        {:noreply, put_flash(socket, :error, "Restore cancelled: #{reason}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to restore")}
    end
  end

  def handle_event("clear-ref", %{"field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, "")
    socket = assign(socket, editor_form: form)
    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end

  def handle_event("publish", _, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      content = Content.build_content(socket.assigns.editor_form, socket.assigns[:editor_schema])
      title = Map.get(socket.assigns.editor_form, "title", doc.title)

      case Content.validate_document(type, title, content, socket.assigns.dataset) do
        {:error, errs} ->
          {:noreply,
           socket
           |> assign(validation_errors: errs)
           |> put_flash(:error, "Fix validation errors before publishing")}

        _ ->
          opts = hook_opts(socket)

          do_action(
            socket,
            fn d, t ->
              Content.publish_document(
                Content.published_id(d.doc_id),
                t,
                socket.assigns.dataset,
                opts
              )
            end,
            "Published"
          )
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("unpublish", _, socket) do
    opts = hook_opts(socket)

    do_action(
      socket,
      fn doc, type ->
        Content.unpublish_document(
          Content.published_id(doc.doc_id),
          type,
          socket.assigns.dataset,
          opts
        )
      end,
      "Unpublished"
    )
  end

  # ── E1. Duplicate ──────────────────────────────────────────────────────────
  # Clone the editor's currently-loaded doc into a fresh draft and patch
  # the nav path to land on it. The duplicate's published id replaces
  # the tail of nav_path so the editor pane reuses the same list pane.
  def handle_event("duplicate-doc", _, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      case Content.clone_document(doc, type, socket.assigns.dataset, hook_opts(socket)) do
        {:ok, new_doc} ->
          pub_id = Content.published_id(new_doc.doc_id)
          base = Enum.take(socket.assigns.nav_path, length(socket.assigns.nav_path) - 1)
          new_path = base ++ [pub_id]

          {:noreply,
           socket
           |> put_flash(:info, "Duplicated as #{pub_id}")
           |> push_patch(to: studio_path(new_path, socket.assigns.dataset))}

        {:error, {:halted, reason}} ->
          {:noreply, put_flash(socket, :error, "Duplicate cancelled: #{reason}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to duplicate")}
      end
    else
      {:noreply, socket}
    end
  end

  # ── E2. Open in new pane (read-only secondary editor) ──────────────────────
  # Picker opens a doc-search modal scoped to the editor_type. Selecting
  # an entry assigns secondary_doc and renders a read-only card next to
  # the primary editor. v1 is read-only — primary autosave still wins;
  # simultaneous-edit is a deliberate follow-up.
  def handle_event("open-secondary-picker", _, socket) do
    type = socket.assigns[:editor_type]

    candidates =
      if type do
        type
        |> Content.list_documents(socket.assigns.dataset, perspective: :drafts)
        |> Enum.map(fn d ->
          pub = Content.published_id(d.doc_id)
          %{id: pub, title: d.title || "Untitled", type: type}
        end)
        |> Enum.reject(fn c ->
          socket.assigns[:editor_doc] &&
            c.id == Content.published_id(socket.assigns.editor_doc.doc_id)
        end)
      else
        []
      end

    {:noreply,
     assign(socket,
       show_secondary_picker: true,
       secondary_search: "",
       secondary_candidates: candidates
     )}
  end

  def handle_event("close-secondary-picker", _, socket) do
    {:noreply, assign(socket, show_secondary_picker: false, secondary_search: "")}
  end

  def handle_event("secondary-search", %{"value" => q}, socket) do
    {:noreply, assign(socket, secondary_search: q)}
  end

  def handle_event("select-secondary", %{"id" => doc_id}, socket) do
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    case Content.fetch_doc_with_draft(type, doc_id, dataset) do
      {nil, _, _} ->
        {:noreply, put_flash(socket, :error, "Document not found")}

      {doc, _, _} ->
        schema =
          case Content.get_schema(type, dataset) do
            {:ok, s} -> s
            _ -> nil
          end

        {:noreply,
         assign(socket,
           secondary_doc: doc,
           secondary_schema: schema,
           secondary_type: type,
           show_secondary_picker: false,
           secondary_search: ""
         )}
    end
  end

  def handle_event("close-secondary", _, socket) do
    {:noreply, assign(socket, secondary_doc: nil, secondary_schema: nil, secondary_type: nil)}
  end

  # ── E3. Bulk publish (list pane multi-select) ──────────────────────────────
  # Checkboxes on each :doc list item toggle a MapSet of published ids.
  # The floating action bar appears when the set is non-empty and runs
  # the action over every selected id. Cross-pane selection isn't
  # gated — the active list pane is the only one rendering :doc rows.
  def handle_event("toggle-doc-checkbox", %{"id" => id}, socket) do
    current = socket.assigns.selected_doc_ids

    new =
      if MapSet.member?(current, id),
        do: MapSet.delete(current, id),
        else: MapSet.put(current, id)

    {:noreply, assign(socket, selected_doc_ids: new)}
  end

  def handle_event("bulk-clear", _, socket) do
    {:noreply, assign(socket, selected_doc_ids: MapSet.new())}
  end

  def handle_event("bulk-publish", _, socket) do
    {:noreply, bulk_action(socket, :publish)}
  end

  def handle_event("bulk-unpublish", _, socket) do
    {:noreply, bulk_action(socket, :unpublish)}
  end

  # ── Schema-declared document actions (Task #16 — action registry) ──────────
  #
  # Schemas advertise document-level actions via the `:actions` array on the
  # SchemaDefinition row. The editor pane renders a button per action; clicking
  # a `kind: "modal"` action lands here. The generic ConfirmModal opens with
  # the action's metadata; dry-run and real confirmations route through
  # `confirm-modal-dryrun` / `confirm-modal-real` below, each of which
  # dispatches into the plugin-owned action handler resolved via
  # `Plugins.Registry.collect_action_handlers/1`. `kind: "link"`
  # actions never hit this handler — they're rendered as anchor tags by
  # `StudioComponents.doc_action_button/1`, so a click is a plain HTTP
  # navigation.
  def handle_event("schema_action", %{"name" => name}, socket) do
    # Resolve the post-plugin doc-actions list and look the action up there
    # — a plugin's `resolve_doc_actions/2` may have rewritten or dropped it
    # since the button was rendered. If the action no longer exists in the
    # resolved list (e.g. a plugin filtered it out between render and click),
    # fall back to a no-op flash.
    action = find_resolved_doc_action(socket, name)

    case action do
      %{"kind" => "modal"} = a ->
        {:noreply,
         assign(socket,
           confirm_modal: %{
             action: a,
             stage: "initial",
             doc_id: doc_id_for_action(socket),
             dataset: socket.assigns[:dataset],
             preview: nil
           }
         )}

      _ ->
        {:noreply, put_flash(socket, :info, "Action #{name} not yet wired")}
    end
  end

  def handle_event("close-confirm-modal", _, socket) do
    {:noreply, assign(socket, confirm_modal: nil)}
  end

  # Dry-run confirmation — dispatch to the plugin action with `:dryrun`,
  # surface the preview in the modal without closing it. Errors are
  # rendered as a preview slice tagged `:error` so the user can fix and
  # retry without leaving the modal.
  def handle_event("confirm-modal-dryrun", _, socket) do
    case socket.assigns[:confirm_modal] do
      %{action: %{"name" => name}, doc_id: doc_id, dataset: dataset} = modal
      when is_binary(doc_id) and is_binary(dataset) ->
        result = dispatch_action(socket, name, doc_id, dataset, :dryrun)
        preview = preview_from_result(result)

        {:noreply,
         assign(socket, confirm_modal: Map.merge(modal, %{stage: "dryrun", preview: preview}))}

      _ ->
        {:noreply, socket}
    end
  end

  # Real confirmation — dispatch with `:real`, close the modal, flash the
  # outcome. On success we also rebuild panes so any pill / status that
  # reads from the document picks up the freshly-written `pending` marker.
  def handle_event("confirm-modal-real", _, socket) do
    case socket.assigns[:confirm_modal] do
      %{action: %{"name" => name}, doc_id: doc_id, dataset: dataset}
      when is_binary(doc_id) and is_binary(dataset) ->
        case dispatch_action(socket, name, doc_id, dataset, :real) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(confirm_modal: nil)
             |> put_flash(:info, "#{name} enqueued")
             |> rebuild_panes()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(confirm_modal: nil)
             |> put_flash(:error, "#{name} failed: #{format_action_error(reason)}")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ── In-Studio paper block editor events (convergence/studio-paper-editor) ───
  #
  # Every editing event below maps a form/button action to exactly ONE
  # DocPatchOp and routes it through `Content.apply_paper_block_op/3`. The op
  # pipeline renders the fragment, persists blocks + body_html, bumps the
  # streaming rev, and broadcasts a `{:paper_block,…}` delta — which the
  # existing stream handler applies with no remount. We NEVER write the DB
  # directly here and NEVER rebuild_panes (that would remount the view).
  #
  # patch.ex / render.ex are untouched; only the op maps we build vary.

  # View ⇄ Edit toggle. View is the read-only live stream; Edit renders the
  # per-block controls. Pure assign flip — no remount.
  #
  # Entering Edit tears the streamed `<article phx-update="stream">` container
  # out of the DOM (the editor branch renders instead). A LiveView stream is a
  # write-only changelog with no server-side snapshot, so once that container
  # is destroyed there is nothing to re-emit when it returns. Flipping the
  # assign back alone would re-render an EMPTY stream container — the View pane
  # would show zero blocks. So on the View transition we re-populate
  # `:paper_blocks` from the current `paper_doc` blocks (the source of truth,
  # kept fresh by `sync_paper_edit_doc/1` after every edit), reusing the same
  # `paper_stream_items/1` path the initial mount uses. `reset: true` discards
  # any stale client state so the View shows exactly the current blocks,
  # including edits made while in Edit mode. Still a pure stream/assign update
  # — no remount, no rebuild_panes.
  def handle_event("paper-toggle-edit", _params, socket) do
    if socket.assigns[:editor_view] == :paper do
      next_edit_mode = !socket.assigns[:paper_edit_mode]

      socket = assign(socket, paper_edit_mode: next_edit_mode)

      socket =
        if next_edit_mode or not socket.assigns[:paper_block_mode] do
          socket
        else
          # Switching back to View on a block-backed paper: rehydrate the stream.
          stream(socket, :paper_blocks, paper_stream_items(paper_top_level_blocks(socket)),
            reset: true
          )
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Edit a block's textual field(s) → patch-block with only the changed
  # field(s). Inline content (paragraph/callout) is plain text in the MVP:
  # the textarea value is wrapped as a single text inline node, which DROPS
  # any pre-existing inline marks (bold/italic/link) on that block — an
  # accepted MVP tradeoff (marks/slash-menu/drag-drop are deferred).
  def handle_event("paper-edit-block", %{"block_id" => id} = params, socket) do
    block = paper_block_by_id(socket, id)
    patch = build_block_patch(block, params)
    {:noreply, paper_op(socket, %{"op" => "patch-block", "id" => id, "patch" => patch})}
  end

  # Op forwarded by the <bp-paper-editor> Web Component via the
  # BarkparkPaperEditor JS hook. The WC owns the editing UX (debounced rich
  # text) and emits a portable-doc op verbatim; we route it through the same
  # canonical `paper_op/2` pipeline the form-based handlers use. The op arrives
  # JSON-decoded with string keys: %{"op"=>"patch-block","id"=>_,"patch"=>%{}}.
  # The server owns the model — `paper_op/2` applies, persists, broadcasts the
  # `{:paper_block,…}` delta, and re-syncs `paper_doc`. No echo to the WC.
  def handle_event("paper-op", %{"op" => _} = op, socket) do
    {:noreply, paper_op(socket, op)}
  end

  # Add a block. Default `insert-after` the focused block; `append-block` when
  # no anchor (empty doc or top-level add). A fresh immutable id is generated.
  def handle_event("paper-add-block", %{"block-type" => type} = params, socket) do
    new = default_block(type, new_block_id())

    op =
      case params["after-id"] do
        after_id when is_binary(after_id) and after_id != "" ->
          %{"op" => "insert-after", "afterId" => after_id, "block" => new}

        _ ->
          %{"op" => "append-block", "block" => new}
      end

    {:noreply, paper_op(socket, op)}
  end

  # Delete a block → remove-block by id.
  def handle_event("paper-delete-block", %{"id" => id}, socket) do
    {:noreply, paper_op(socket, %{"op" => "remove-block", "id" => id})}
  end

  # Reorder a top-level block one slot up/down. Implemented as two ops
  # (remove-block then insert-after the new neighbour) — the simplest correct
  # path that stays entirely on the op pipeline. Both ops broadcast their own
  # delta; the second arrives with the next rev so the stream applies in order.
  def handle_event("paper-move-block", %{"id" => id, "dir" => dir}, socket) do
    blocks = paper_top_level_blocks(socket)
    idx = Enum.find_index(blocks, fn b -> Map.get(b, "id") == id end)

    {:noreply, paper_reorder(socket, blocks, idx, dir)}
  end

  # ── paper editor helpers ────────────────────────────────────────────────────

  # Apply one op via the canonical pipeline, then refresh the in-memory
  # `paper_doc` so the edit form reflects the new block list. The op's own
  # `{:paper_block}` broadcast already advanced the read-only stream (and any
  # remote viewer); this just keeps THIS pane's edit controls in sync.
  defp paper_op(socket, op) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id
    dataset = socket.assigns.dataset

    cond do
      is_nil(slug) ->
        socket

      true ->
        case Content.apply_paper_block_op(slug, op, dataset) do
          {:ok, _result} ->
            sync_paper_edit_doc(socket)

          {:error, _reason} ->
            put_flash(socket, :error, "Edit failed")
        end
    end
  end

  # Reorder by removing then re-inserting after the neighbour in the target
  # direction. No-ops at the boundaries. Two sequential ops keep us on the
  # pipeline rather than mutating blocks directly.
  defp paper_reorder(socket, _blocks, nil, _dir), do: socket

  # Up: swap `moved` with its predecessor. Remove the predecessor, then
  # re-insert it directly after `moved`. After the remove, `moved` shifts up
  # one slot; the insert puts the old predecessor right below it — a clean
  # one-slot-up move that also works when the destination is the head slot.
  # `insert-after` is the only insertion op, so a swap is the simplest correct
  # path (no "insert-before" exists).
  defp paper_reorder(socket, blocks, idx, "up") when idx > 0 do
    moved = Enum.at(blocks, idx)
    pred = Enum.at(blocks, idx - 1)
    remove = %{"op" => "remove-block", "id" => Map.get(pred, "id")}
    insert = %{"op" => "insert-after", "afterId" => Map.get(moved, "id"), "block" => pred}
    socket |> paper_op(remove) |> paper_op(insert)
  end

  # Down: remove `moved`, re-insert it after the block that was below it. After
  # the remove the successor shifts up to `idx`; inserting `moved` after it
  # lands `moved` one slot lower.
  defp paper_reorder(socket, blocks, idx, "down") when idx < length(blocks) - 1 do
    moved = Enum.at(blocks, idx)
    anchor = Enum.at(blocks, idx + 1)
    anchor_id = Map.get(anchor, "id")
    remove = %{"op" => "remove-block", "id" => Map.get(moved, "id")}
    insert = %{"op" => "insert-after", "afterId" => anchor_id, "block" => moved}
    socket |> paper_op(remove) |> paper_op(insert)
  end

  defp paper_reorder(socket, _blocks, _idx, _dir), do: socket

  # Re-read the paper from the DB into `paper_doc` (block list = source of
  # truth). Used after a local op and on any delta while in edit mode.
  defp sync_paper_edit_doc(socket) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id

    case slug && Content.get_paper(slug, socket.assigns.dataset) do
      %{} = fresh -> assign(socket, paper_doc: fresh)
      _ -> socket
    end
  end

  # Top-level blocks of the currently-open paper (source of truth).
  defp paper_top_level_blocks(socket) do
    case socket.assigns[:paper_doc] do
      %{content: %{"blocks" => blocks}} when is_list(blocks) -> blocks
      _ -> []
    end
  end

  # Find a block by id anywhere in the tree (recurses sections), so a control
  # nested inside a section still resolves its block.
  defp paper_block_by_id(socket, id) do
    find_paper_block(paper_top_level_blocks(socket), id)
  end

  defp find_paper_block(blocks, id) when is_list(blocks) do
    Enum.find_value(blocks, fn b ->
      cond do
        Map.get(b, "id") == id -> b
        Map.get(b, "type") == "section" -> find_paper_block(Map.get(b, "blocks", []), id)
        true -> nil
      end
    end)
  end

  defp find_paper_block(_blocks, _id), do: nil

  # Build the patch map for a block from the submitted form params. Only the
  # editable field(s) for that block type are included; `id`/`type` are locked
  # by patch.ex regardless. Mirrors the EXACT block shapes in
  # Barkpark.PortableDoc.Render.compose_block/1.
  defp build_block_patch(%{"type" => "heading"}, params) do
    %{}
    |> put_if_present("text", params["text"])
    |> put_if_present("level", parse_level(params["level"]))
  end

  defp build_block_patch(%{"type" => "paragraph"}, params) do
    %{"content" => text_to_inline(params["text"] || "")}
  end

  defp build_block_patch(%{"type" => "callout"}, params) do
    %{}
    |> put_if_present("tone", params["tone"])
    |> Map.put("content", text_to_inline(params["text"] || ""))
    |> put_callout_title(params["title"])
  end

  defp build_block_patch(%{"type" => "code"}, params) do
    %{}
    |> put_if_present("lang", params["lang"])
    |> Map.put("value", params["value"] || "")
  end

  defp build_block_patch(%{"type" => "list"}, params) do
    # Each `item-N` param is one list item's plain text. Items keep their
    # 0-based order. An ordered/unordered toggle rides in `ordered`.
    items =
      params
      |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "item-") end)
      |> Enum.sort_by(fn {k, _v} -> k |> String.replace_prefix("item-", "") |> to_int(0) end)
      |> Enum.map(fn {_k, v} -> text_to_inline(v || "") end)

    %{}
    |> Map.put("items", items)
    |> put_if_present("ordered", parse_bool(params["ordered"]))
  end

  defp build_block_patch(%{"type" => "section"}, params) do
    put_if_present(%{}, "title", params["title"])
  end

  # Unknown / non-editable block type (image, table, divider) → no-op patch.
  defp build_block_patch(_block, _params), do: %{}

  # A callout title is optional; an empty string drops it back to untitled.
  defp put_callout_title(patch, title) when is_binary(title) do
    case String.trim(title) do
      "" -> Map.put(patch, "title", nil)
      t -> Map.put(patch, "title", t)
    end
  end

  defp put_callout_title(patch, _), do: patch

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp parse_level(nil), do: nil

  defp parse_level(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n in 1..6 -> n
      _ -> nil
    end
  end

  defp parse_level(_), do: nil

  defp parse_bool("true"), do: true
  defp parse_bool("on"), do: true
  defp parse_bool(true), do: true
  defp parse_bool(_), do: false

  defp to_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> default
    end
  end

  defp to_int(_, default), do: default

  # MVP inline handling: wrap plain text as a single text inline node. This
  # DROPS pre-existing marks (bold/italic/link) on the block when re-saved —
  # accepted for the MVP block editor (rich inline marks are deferred).
  defp text_to_inline(text) when is_binary(text) do
    [%{"type" => "text", "value" => text}]
  end

  # Render an InlineNode array back to plain text for a textarea/input: keep
  # only text-node values (and nested children of strong/em/link), concatenated.
  # Lossy by design — the inverse of text_to_inline/1 for the MVP.
  defp inline_to_text(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&inline_node_text/1)
    |> Enum.join("")
  end

  defp inline_to_text(_), do: ""

  defp inline_node_text(%{"type" => "text", "value" => v}) when is_binary(v), do: v
  defp inline_node_text(%{"value" => v}) when is_binary(v), do: v

  defp inline_node_text(%{"children" => children}) when is_list(children),
    do: inline_to_text(children)

  defp inline_node_text(s) when is_binary(s), do: s
  defp inline_node_text(_), do: ""

  # Generate a short unique, immutable block id. Block ids are never reused or
  # mutated once assigned (patch.ex locks `id`).
  defp new_block_id do
    "b-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))
  end

  # A fresh block of `type` with sensible empty defaults, in the EXACT shape
  # Render.compose_block/1 expects. `image`/`table`/`action` are not offered in
  # the Add menu (deferred), so they are not built here.
  defp default_block("heading", id),
    do: %{"id" => id, "type" => "heading", "text" => "New heading", "level" => 2}

  defp default_block("paragraph", id),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => ""}]}

  defp default_block("list", id),
    do: %{
      "id" => id,
      "type" => "list",
      "ordered" => false,
      "items" => [[%{"type" => "text", "value" => ""}]]
    }

  defp default_block("callout", id),
    do: %{
      "id" => id,
      "type" => "callout",
      "tone" => "info",
      "content" => [%{"type" => "text", "value" => ""}]
    }

  defp default_block("code", id),
    do: %{"id" => id, "type" => "code", "lang" => "", "value" => ""}

  defp default_block("divider", id),
    do: %{"id" => id, "type" => "divider"}

  defp default_block("section", id),
    do: %{"id" => id, "type" => "section", "title" => "New section", "blocks" => []}

  defp default_block(_unknown, id),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => ""}]}

  # Single autosave path consumed by handle_event "autosave",
  # handle_event "save", and handle_info :autosave_form. Delegates to
  # Content.upsert_draft/5 (validation + upsert + errors map) and
  # mutates pane titles in-memory to avoid an N+1 DB rebuild on every
  # keystroke.
  defp do_autosave(socket, params) do
    doc = socket.assigns[:editor_doc]
    schema = socket.assigns[:editor_schema]
    type = socket.assigns[:editor_type]

    if doc && type do
      case Content.upsert_draft(
             doc,
             type,
             schema,
             params,
             socket.assigns.dataset,
             hook_opts(socket)
           ) do
        {:ok, saved_doc, errs} ->
          new_title = Map.get(params, "title", doc.title)

          panes =
            PaneBuilder.update_title(
              socket.assigns.panes,
              Content.published_id(saved_doc.doc_id),
              new_title
            )

          assign(socket,
            panes: panes,
            editor_doc: saved_doc,
            editor_is_draft: Content.draft?(saved_doc.doc_id),
            editor_form: params,
            save_status: "Saved",
            validation_errors: errs,
            cross_violations: compute_cross_violations(schema, params)
          )
          |> maybe_refresh_content_preview()

        {:error, {:halted, reason}} ->
          # `before_save` hook vetoed the autosave (per plan §0 Q4). The
          # editor's form state is untouched; surface the reason in the
          # save_status indicator AND a flash so it can't be missed.
          socket
          |> assign(save_status: "Save cancelled")
          |> put_flash(:error, "Save cancelled: #{reason}")

        {:error, _} ->
          assign(socket, save_status: "Save failed")
      end
    else
      socket
    end
  end

  # Build the keyword list of lifecycle-hook context (`:source`,
  # `:user_id`) that every Content write call site in StudioLive passes
  # through. Centralised so the recursion guard (plan §0 Q5) is set
  # consistently — every Studio-originated write tags itself
  # `source: :studio` and threads the socket's user_id when present.
  defp hook_opts(socket) do
    [source: :studio, user_id: socket.assigns[:user_id]]
  end

  # ── Content preview side-pane (Goal barkpark-G1, task s3) ──────────
  # Doc-type-agnostic recompute. Runs at the end of `do_autosave/2`'s
  # success branch, and again from `rebuild_panes/1` so the preview
  # lands on first-mount (before any input event has fired).
  #
  # First-wins resolver: walks registered plugins via
  # `Plugins.Registry.collect_content_renderer/3` and uses the first
  # `{:ok, iodata}` it gets. When every plugin returns `:skip` (or
  # plugins=[]), `:none` ⇒ assign nil ⇒ pane is absent from the layout.
  # This is the host-side of the s3 refactor — Barkpark itself knows
  # nothing about `"book"` documents or ONIX XML; OnixEdit's plugin
  # module contributes the renderer.
  defp maybe_refresh_content_preview(socket) do
    doc_type = socket.assigns[:editor_type]

    case doc_type do
      type when is_binary(type) and type != "" ->
        content = socket.assigns[:editor_form] || %{}

        ctx = %{
          current_user: socket.assigns[:current_user],
          user_id: socket.assigns[:user_id],
          dataset: socket.assigns[:dataset],
          perspective: socket.assigns[:perspective]
        }

        case Barkpark.Plugins.Registry.collect_content_renderer(type, content, ctx) do
          {:ok, rendered} ->
            assign(socket, content_preview_rendered: rendered)

          :none ->
            assign(socket, content_preview_rendered: nil)
        end

      _ ->
        # No doc / no doc_type → clear any stale preview from a
        # previously-open doc so the pane closes cleanly.
        assign(socket, content_preview_rendered: nil)
    end
  end

  defp do_action(socket, action, msg) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      case action.(doc, type) do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, msg) |> rebuild_panes()}

        {:error, {:halted, reason}} ->
          # Lifecycle-hook veto (per plan §0 Q4). Surface as a red flash
          # banner so the editor sees why the action was cancelled.
          {:noreply, put_flash(socket, :error, "#{msg} cancelled: #{reason}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Action failed")}
      end
    else
      {:noreply, socket}
    end
  end

  # ── Bulk publish helpers (Task barkpark-3yq) ─────────────────────────────
  #
  # `bulk_action/2` iterates `selected_doc_ids`, dispatches the per-doc
  # publish/unpublish call, aggregates {ok, err} counts and surfaces a
  # single flash. `list_pane_type/1` finds the rightmost pane carrying a
  # `:type_name` — that's the document-list pane (PaneBuilder only puts
  # `:type_name` on `:document_type_list` panes), and is the implicit
  # scope of the selection set.
  defp bulk_action(socket, kind) do
    ids = MapSet.to_list(socket.assigns.selected_doc_ids)
    type = list_pane_type(socket)
    dataset = socket.assigns.dataset
    opts = hook_opts(socket)

    if type == nil or ids == [] do
      assign(socket, selected_doc_ids: MapSet.new())
    else
      # Aggregate three buckets: successful writes, halts (lifecycle-hook
      # vetoes — per plan §0 Q4 these are NOT errors, they're plugin
      # policy enforcement) and other failures. Surfacing the halt count
      # separately in the flash makes it obvious to the editor that the
      # cancelled rows weren't broken — a plugin chose to refuse them.
      {ok, halted, err} =
        Enum.reduce(ids, {0, 0, 0}, fn id, {ok, halted, err} ->
          result =
            case kind do
              :publish -> Content.publish_document(id, type, dataset, opts)
              :unpublish -> Content.unpublish_document(id, type, dataset, opts)
            end

          case result do
            {:ok, _} -> {ok + 1, halted, err}
            {:error, {:halted, _}} -> {ok, halted + 1, err}
            _ -> {ok, halted, err + 1}
          end
        end)

      verb = if kind == :publish, do: "Published", else: "Unpublished"

      flash =
        cond do
          halted > 0 and err == 0 ->
            "#{verb} #{ok} of #{length(ids)}. #{halted} cancelled by plugin rules."

          halted > 0 and err > 0 ->
            "#{verb} #{ok} of #{length(ids)}. #{halted} cancelled by plugin rules (#{err} failed)."

          err == 0 ->
            "#{verb} #{ok} of #{length(ids)}"

          true ->
            "#{verb} #{ok} of #{length(ids)} (#{err} failed)"
        end

      socket
      |> assign(selected_doc_ids: MapSet.new())
      |> put_flash(:info, flash)
      |> rebuild_panes()
    end
  end

  defp list_pane_type(socket) do
    socket.assigns
    |> Map.get(:panes, [])
    |> Enum.reverse()
    |> Enum.find_value(fn pane -> Map.get(pane, :type_name) end)
  end

  defp studio_path(path, dataset, opts \\ []), do: studio_path_for(path, dataset, opts)

  defp studio_path_for([], dataset, opts),
    do: append_desk_query("/studio/#{dataset}", opts)

  defp studio_path_for(segments, dataset, opts),
    do:
      append_desk_query(
        "/studio/#{dataset}/" <> Enum.join(segments, "/"),
        opts
      )

  defp append_desk_query(path, opts) do
    case Keyword.get(opts, :desk) do
      nil -> path
      "" -> path
      desk -> path <> "?desk=" <> URI.encode_www_form(to_string(desk))
    end
  end

  # Render-side helper — the chip href shows the URL the user would
  # land on if they clicked. (The actual navigation goes through
  # `phx-click="select-desk"` → `push_patch`, so JS isn't required;
  # the href makes the chip bookmarkable + middle-clickable.)
  defp desk_chip_href(nav_path, dataset, desk) do
    studio_path(nav_path, dataset, desk: desk)
  end

  # ── Schema-action helpers (Task #16 — action registry) ─────────────────────

  defp schema_actions(nil), do: []

  defp schema_actions(schema) do
    case Map.get(schema, :actions) || Map.get(schema, "actions") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # ── Doc-actions registry (Goal barkpark-cjs, s4) ───────────────────────────
  #
  # The editor-header action bar (Publish, Unpublish, Delete, History, Diff
  # toggle, Show/Hide XML, Duplicate, Open another, plus schema-declared
  # plugin actions like Export ONIX / Publish to Bokbasen) flows through
  # `Barkpark.Plugins.Registry.collect_doc_actions/1`. The host builds its
  # built-in list via `default_doc_actions/1`, passes it as `:baseline`, and
  # the resolver chain (each plugin's `resolve_doc_actions/2`) can drop,
  # reorder, or amend entries based on the live document payload.
  #
  # The proof for the refactor lands in s5: OnixEdit's resolver hides
  # "Publish to Bokbasen" when the book is mid-Bokbasen-submission
  # (`doc.content.bp_export_status.state` in
  # `~w(pending staging staged polling)`).
  #
  # Each action is a string-keyed map matching the `Barkpark.Plugin.doc_action`
  # typespec: `"name"`, `"label"`, `"kind"` (`"event"` | `"modal"` | `"link"`),
  # plus optional `"opts"` (per-kind payload — `"event"` name for `:event`,
  # `"href"` for `:link`, `"modal"` body for `:modal`).
  # Accepts either `%Phoenix.LiveView.Socket{}` (handle_event paths) or a
  # raw assigns map (render paths). Both flow through the same baseline +
  # resolver call so a plugin's filter applies whether the action is being
  # rendered or dispatched.
  defp resolved_doc_actions(socket_or_assigns) do
    assigns = socket_to_assigns(socket_or_assigns)
    ctx = doc_actions_ctx(assigns)
    baseline = default_doc_actions(assigns, ctx)
    Barkpark.Plugins.Registry.collect_doc_actions(baseline: baseline, ctx: ctx)
  end

  defp socket_to_assigns(%{assigns: assigns}), do: assigns
  defp socket_to_assigns(assigns) when is_map(assigns), do: assigns

  defp doc_actions_ctx(assigns) do
    %{
      dataset: assigns[:dataset],
      doc_id: doc_id_from_assigns(assigns),
      doc_type: assigns[:editor_type],
      doc: assigns[:editor_doc]
    }
  end

  defp doc_id_from_assigns(assigns) do
    case assigns[:editor_doc] do
      %{doc_id: doc_id} -> doc_id
      _ -> nil
    end
  end

  # Host's built-in editor-header doc-actions, seeded as `:baseline` for the
  # `resolve_doc_actions/2` resolver chain. The list mirrors what the editor
  # shell rendered as hardcoded HEEx before the refactor (History, Delete,
  # Publish/Unpublish, Show/Hide XML for books, Diff/Edit when a draft has a
  # published twin) plus the per-doc Duplicate / Open another buttons from
  # `:extra_actions` and the schema-declared actions (which the schema
  # author — including plugins like OnixEdit — registered via the schema's
  # `:actions` array). The conditional gating (draft vs published, book-only
  # XML toggle, diff-toggle availability) is expressed as the action being
  # in or out of the returned list.
  #
  # Order is rendering-order inside the editor-header `bp-overflow-menu`:
  # History → Delete → Publish/Unpublish → Show/Hide XML → Diff toggle →
  # Duplicate → Open another → schema actions.
  defp default_doc_actions(assigns, _ctx) do
    assigns = socket_to_assigns(assigns)
    editor_doc = assigns[:editor_doc]
    editor_schema = assigns[:editor_schema]
    is_draft = assigns[:editor_is_draft] == true
    published_doc = assigns[:published_doc]
    content_preview_visible = assigns[:content_preview_visible] == true
    content_preview_rendered = assigns[:content_preview_rendered]
    diff_visible = assigns[:diff_visible] == true

    has_published_twin = is_draft and not is_nil(published_doc)
    has_content_preview = not is_nil(content_preview_rendered)

    base = [
      %{
        "name" => "show-history",
        "label" => "History",
        "kind" => "event",
        "scope" => "editor_header",
        "opts" => %{
          "event" => "show-history",
          "class" => "btn btn-ghost btn-sm",
          "icon" => "history"
        }
      },
      %{
        "name" => "delete-doc",
        "label" => "Delete",
        "kind" => "event",
        "scope" => "editor_header",
        "opts" => %{
          "event" => "delete-doc",
          "class" => "btn btn-ghost btn-sm",
          "style" => "color: var(--destructive);",
          "icon" => "trash-2"
        }
      },
      if is_draft do
        %{
          "name" => "publish",
          "label" => "Publish",
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "publish",
            "class" => "btn btn-primary btn-sm",
            "icon" => "send"
          }
        }
      else
        %{
          "name" => "unpublish",
          "label" => "Unpublish",
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "unpublish",
            "class" => "btn btn-sm",
            "icon" => "archive"
          }
        }
      end,
      if has_content_preview do
        %{
          "name" => "toggle-content-preview",
          "label" => if(content_preview_visible, do: "Hide preview", else: "Show preview"),
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "toggle-content-preview",
            "class" => "btn btn-ghost btn-sm",
            "data_test_id" => "onix-preview-toggle",
            "icon" => "code"
          }
        }
      end,
      if has_published_twin do
        %{
          "name" => "toggle-diff",
          "label" => if(diff_visible, do: "Edit", else: "Diff"),
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "toggle-diff",
            "class" => "btn btn-ghost btn-sm",
            "data_test_id" => "draft-diff-toggle",
            "icon" => "git-compare"
          }
        }
      end,
      if editor_doc do
        %{
          "name" => "duplicate-doc",
          "label" => "Duplicate",
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "duplicate-doc",
            "class" => "btn btn-ghost btn-sm",
            "data_test_id" => "duplicate-doc",
            "icon" => "copy"
          }
        }
      end,
      if editor_doc do
        %{
          "name" => "open-secondary-picker",
          "label" => "Open another",
          "kind" => "event",
          "scope" => "editor_header",
          "opts" => %{
            "event" => "open-secondary-picker",
            "class" => "btn btn-ghost btn-sm",
            "data_test_id" => "open-secondary-picker",
            "icon" => "panel-right-open"
          }
        }
      end
    ]

    # Schema-declared actions land last. These are the entries plugins
    # already register today via SchemaDefinition `:actions` (e.g.
    # OnixEdit's `export_onix` link + `publish_to_bokbasen` modal). The
    # resolver chain runs over the combined list, so a plugin can still
    # filter its own schema-declared actions based on live doc state.
    schema_entries =
      editor_schema
      |> schema_actions()
      |> Enum.map(&Map.put(&1, "scope", "editor_header"))

    (base ++ schema_entries)
    |> Enum.reject(&is_nil/1)
  end

  defp find_resolved_doc_action(socket, name) do
    socket
    |> resolved_doc_actions()
    |> Enum.find(fn a -> Map.get(a, "name") == name end)
  end

  # Dispatch a named schema action to the plugin-owned handler. Each
  # plugin declares its handlers via the `Barkpark.Plugin.action_handlers/0`
  # callback (additive form) or `resolve_action_handlers/2` (resolver form);
  # `Plugins.Registry.collect_action_handlers/1` drives the resolver chain
  # seeded with the host's built-in handlers as `:baseline` (currently an
  # empty map — the host ships no built-in action handlers; the empty
  # map still flows so plugins can rely on `prev` being map-shaped).
  # Unknown names return a structured error so the caller can format a
  # flash instead of crashing.
  #
  # `:ctx` carries the dispatch identity (`%{dataset, doc_id, doc_type,
  # doc}`) sourced from `socket.assigns` so resolver plugins can return a
  # different handler — or no handler at all — depending on the live
  # document. `doc_type` and `doc` are read straight off
  # `:editor_type` / `:editor_doc`; modal dispatch always targets the
  # currently-open editor doc, so the assigns are guaranteed in scope.
  defp dispatch_action(socket, name, doc_id, dataset, mode) do
    ctx = action_handler_ctx(socket, doc_id, dataset)

    handlers =
      Barkpark.Plugins.Registry.collect_action_handlers(
        baseline: default_action_handlers(ctx),
        ctx: ctx
      )

    case Map.get(handlers, name) do
      handler when is_function(handler, 3) -> handler.(doc_id, dataset, mode)
      _ -> {:error, {:unknown_action, name}}
    end
  end

  # Host's built-in action handlers, seeded as `:baseline` for the
  # `resolve_action_handlers/2` resolver chain. Currently empty — every
  # production action handler today is plugin-owned (OnixEdit) — but
  # extracted to its own fn so the chain is wired symmetrically and a
  # future host-owned action lands here without touching the dispatch
  # call site.
  defp default_action_handlers(_ctx), do: %{}

  # Build the resolver `:ctx` for `collect_action_handlers/1`. The doc
  # type and doc payload come directly off `socket.assigns` — the modal
  # dispatch always fires against the currently-open editor pane, so
  # `:editor_type` / `:editor_doc` are the right values without a
  # separate DB lookup.
  defp action_handler_ctx(socket, doc_id, dataset) do
    %{
      dataset: dataset,
      doc_id: doc_id,
      doc_type: socket.assigns[:editor_type],
      doc: socket.assigns[:editor_doc]
    }
  end

  # Pull the canonical doc_id for the currently-open editor. Modal actions
  # always target the editor's open doc — there's no multi-select dispatch.
  defp doc_id_for_action(socket) do
    case socket.assigns[:editor_doc] do
      %{doc_id: doc_id} -> doc_id
      _ -> nil
    end
  end

  defp preview_from_result({:ok, %{kind: :xml} = preview}), do: preview

  defp preview_from_result({:error, reason}),
    do: %{kind: :error, message: format_action_error(reason)}

  defp preview_from_result(_), do: nil

  defp format_action_error({:xsd_invalid, reasons}) when is_list(reasons) do
    "ONIX failed XSD validation: " <> Enum.join(Enum.take(reasons, 3), "; ")
  end

  defp format_action_error(:no_doc), do: "No document loaded"

  defp format_action_error({:unknown_action, name}), do: "Unknown action: #{name}"

  defp format_action_error(other), do: inspect(other, limit: 100)

  # NOTE (Goal barkpark-cjs, s4): href interpolation for schema-declared
  # `"link"` actions now lives in `BarkparkWeb.Components.StudioComponents`
  # alongside `doc_action_button/1` — the editor shell renders link actions
  # directly from the resolved doc-action list. The old
  # `interpolate_action_href/3` private helper was removed; if a future
  # caller needs the same substitution, reuse the component-level helper.

  # ── ArrayField helpers (Studio reorder/add/remove wiring) ───────────────────
  #
  # `editor_schema.fields` is `{:array, :map}` — string-keyed raw maps as
  # stored on disk (SchemaDefinition). We never see %Field{} structs here.

  defp find_field(socket, field_name) do
    fields =
      case socket.assigns[:editor_schema] do
        %{fields: list} when is_list(list) -> list
        _ -> []
      end

    Enum.find(fields, fn f -> Map.get(f, "name") == field_name end)
  end

  defp parse_idx(idx) when is_integer(idx), do: idx

  defp parse_idx(idx) when is_binary(idx) do
    case Integer.parse(idx) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_idx(_), do: 0

  # ── Path-based navigation for nested arrayOf inside composites ─────────────
  #
  # The ArrayField component emits `phx-value-path` on every reorder button.
  # The string has the shape `doc[a][b].c[d]` — top-level uses bracket form
  # (from adapter.ex line 72: `"doc[#{name}]"`), composite descents use dot
  # form (from composite_field.ex `child_path`: `"#{parent}.#{child}"`),
  # and array rows append `[#{idx}]`. We strip the `doc[` envelope, then
  # tokenize on `]` / `.` / `[` to recover the key list.
  #
  # Numeric segments (array row indices) are PRESERVED as Elixir integers
  # so the data-access helpers (`do_get_in`, `put_value_at`) can descend
  # into lists via `Enum.at` / `List.replace_at`. The schema-descent helper
  # (`descend_field`) skips integer segments because the schema has no
  # per-row variation — an integer in the path tells us "we're inside an
  # arrayOf row," not which schema field to resolve to.
  #
  # Without the integer being preserved, walking
  # `productSupplies[0].market.territory.countries` would replace the
  # `productSupplies` list with a `%{"market" => …}` map — catastrophic
  # data corruption. See barkpark-i2d4.

  @doc false
  def parse_path("doc[" <> rest), do: parse_brackets(rest, [])
  def parse_path(""), do: []

  def parse_path(other) when is_binary(other) do
    # Accept paths from nested array_field / composite_field components
    # that don't carry the doc[ envelope. Routes through parse_dots so
    # brackets and dots both work, e.g.
    # `productSupplies[0].market.territory.countries`.
    parse_dots(other, [])
  end

  def parse_path(_), do: []

  defp parse_brackets("", acc), do: Enum.reverse(convert_indices(acc))

  defp parse_brackets(rest, acc) do
    case String.split(rest, "]", parts: 2) do
      [key, "[" <> more] -> parse_brackets(more, [key | acc])
      [key, "." <> more] -> parse_dots(more, [key | acc])
      [key, ""] -> Enum.reverse(convert_indices([key | acc]))
      _ -> Enum.reverse(convert_indices(acc))
    end
  end

  defp parse_dots(rest, acc) do
    case String.split(rest, ~r/[\.\[]/, parts: 2, include_captures: true) do
      [key, ".", more] -> parse_dots(more, [key | acc])
      [key, "[", more] -> parse_brackets(more, [key | acc])
      [key] when key != "" -> Enum.reverse(convert_indices([key | acc]))
      _ -> Enum.reverse(convert_indices(acc))
    end
  end

  # Drop empty segments (from malformed input like `doc[]`) and convert
  # numeric strings to Elixir integers in place. Integers stay in the path
  # so `put_value_at` / `do_get_in` can descend into list rows; named-field
  # resolution (`descend_field`) skips them.
  defp convert_indices(acc) do
    acc
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn s ->
      if is_binary(s) do
        case Integer.parse(s) do
          {n, ""} -> n
          _ -> s
        end
      else
        s
      end
    end)
  end

  # Walk `editor_schema.fields` by string-keyed name to find the field at the
  # deepest path position. `descend_field` traverses composite → fields and
  # arrayOf → of transparently so the caller's path doesn't need to mention
  # the `of` envelope. Integer segments (array row indices) are consumed
  # transparently — they carry no schema meaning.
  @doc false
  def find_field_by_path(socket, [head | rest]) when is_integer(head) do
    # Defensive: a path starting with an integer is nonsensical at the
    # schema root, but if it ever happens we just skip it and continue.
    find_field_by_path(socket, rest)
  end

  def find_field_by_path(socket, [head | rest]) do
    fields =
      case socket.assigns[:editor_schema] do
        %{fields: list} when is_list(list) -> list
        _ -> []
      end

    case Enum.find(fields, fn f -> Map.get(f, "name") == head end) do
      nil -> nil
      f -> descend_field(f, rest)
    end
  end

  def find_field_by_path(_, []), do: nil

  defp descend_field(field, []), do: field

  defp descend_field(field, [head | rest]) when is_integer(head) do
    # An integer index = "we're inside an arrayOf row." Drop it; the
    # schema-side descent stays on the named-field axis. The arrayOf
    # clause below will collapse `arrayOf → of` automatically if the
    # next segment is named.
    descend_field(field, rest)
  end

  defp descend_field(%{"type" => "composite", "fields" => subs}, [head | rest])
       when is_list(subs) do
    case Enum.find(subs, fn s -> Map.get(s, "name") == head end) do
      nil -> nil
      s -> descend_field(s, rest)
    end
  end

  defp descend_field(%{"type" => "arrayOf", "of" => of}, path), do: descend_field(of, path)
  defp descend_field(_, _), do: nil

  # Read the list value at the path from editor_form.
  @doc false
  def list_value_at(form, path) when is_list(path) do
    case do_get_in(form, path) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # Hand-rolled get_in that tolerates nil/non-map intermediates and walks
  # both maps (string-keyed) and lists (integer-indexed).
  defp do_get_in(value, []), do: value

  defp do_get_in(list, [idx | rest]) when is_list(list) and is_integer(idx) do
    case Enum.at(list, idx) do
      nil -> nil
      v -> do_get_in(v, rest)
    end
  end

  defp do_get_in(map, [key | rest]) when is_map(map),
    do: do_get_in(Map.get(map, key), rest)

  defp do_get_in(_, _), do: nil

  # Write the list value at the path in editor_form. Initializes missing
  # intermediate maps along the way so adding a row to a yet-unset nested
  # arrayOf works on first click. Integer segments descend into lists via
  # List.replace_at — out-of-bounds indices return the list unchanged
  # rather than corrupting the structure.
  @doc false
  def put_value_at(form, [], _value), do: form
  def put_value_at(nil, [key], value) when is_binary(key), do: %{key => value}
  def put_value_at(form, [key], value) when is_binary(key), do: Map.put(form || %{}, key, value)

  def put_value_at(list, [idx], value) when is_list(list) and is_integer(idx) do
    if idx >= 0 and idx < length(list) do
      List.replace_at(list, idx, value)
    else
      list
    end
  end

  def put_value_at(list, [idx | rest], value) when is_list(list) and is_integer(idx) do
    case Enum.at(list, idx) do
      nil ->
        # Out-of-bounds — leave the list alone. Better silent no-op than
        # auto-extending with placeholders the schema didn't ask for.
        list

      existing ->
        List.replace_at(list, idx, put_value_at(existing, rest, value))
    end
  end

  def put_value_at(form, [head | rest], value) when is_binary(head) do
    inner =
      case form do
        %{} -> Map.get(form, head)
        _ -> nil
      end

    cond do
      # If the existing value at `head` is a list and the next path step
      # is a string key (not an integer index), the caller's path is
      # malformed for the data shape. Silently leave the list alone
      # rather than replacing it with a map (the pre-fix data-loss bug).
      is_list(inner) and rest != [] and is_binary(hd(rest)) ->
        form || %{}

      true ->
        base =
          case inner do
            %{} -> inner
            list when is_list(list) -> list
            _ -> %{}
          end

        Map.put(form || %{}, head, put_value_at(base, rest, value))
    end
  end

  # Anything else (e.g. integer head into a non-list form) → no-op.
  def put_value_at(form, _, _), do: form

  # Empty-element factory — picks a sensible default for a freshly-added row
  # based on the arrayOf element's declared type. composite → empty map;
  # arrayOf → empty list; localizedText → empty map; everything else → nil.
  @doc false
  def empty_for_of(%{"of" => %{"type" => "composite"} = of}) do
    Enum.reduce(of["fields"] || [], %{}, fn sub, acc ->
      Map.put(acc, sub["name"], empty_for_type(sub["type"]))
    end)
  end

  def empty_for_of(%{"of" => %{"type" => "arrayOf"}}), do: []
  def empty_for_of(%{"of" => %{"type" => "codelist"}}), do: nil
  def empty_for_of(%{"of" => %{"type" => "localizedText"}}), do: %{}
  def empty_for_of(%{"of" => %{"type" => _}}), do: nil
  def empty_for_of(_), do: nil

  defp empty_for_type("composite"), do: %{}
  defp empty_for_type("arrayOf"), do: []
  defp empty_for_type("localizedText"), do: %{}
  # strings, codelists, booleans, datetimes, etc. — all start as nil so the
  # validator surfaces "required" errors instead of fake-empty values.
  defp empty_for_type(_), do: nil

  # ── Pane builder ───────────────────────────────────────────────────────────

  defp rebuild_panes(socket) do
    {panes, editor} =
      PaneBuilder.build(socket.assigns.dataset, socket.assigns.nav_path,
        desk: socket.assigns[:nav_desk]
      )

    new_schema = editor && editor[:schema]
    old_schema = socket.assigns[:editor_schema]
    nav_group = resolve_nav_group(socket.assigns[:nav_group], old_schema, new_schema)

    new_form = (editor && editor[:form]) || %{}

    editor_doc = editor && editor[:doc]
    editor_type = editor && editor[:type]
    is_draft = (editor && editor[:is_draft]) || false
    has_published = (editor && editor[:has_published]) || false

    socket =
      assign(socket,
        panes: panes,
        editor_doc: editor_doc,
        editor_schema: new_schema,
        editor_type: editor_type,
        editor_is_draft: is_draft,
        editor_has_published: has_published,
        editor_form: new_form,
        save_status: socket.assigns[:save_status] || "",
        nav_group: nav_group,
        cross_violations: compute_cross_violations(new_schema, new_form),
        published_doc:
          fetch_published_twin(
            editor_doc,
            editor_type,
            socket.assigns.dataset,
            is_draft,
            has_published
          ),
        diff_visible:
          socket.assigns[:diff_visible] &&
            editor_doc != nil && is_draft && has_published
      )
      |> maybe_refresh_content_preview()

    # When the pane builder resolved a `view: :paper` editor (a paper opened
    # in the editor pane), set up the live block view: stream the blocks (or
    # adopt the HTML-only fallback) and remember the streaming rev so deltas
    # apply in order. This is the only place the paper stream is (re)set — the
    # `{:paper_block,…}` delta path NEVER rebuilds panes, so it never remounts.
    case editor && editor[:view] do
      :paper -> setup_paper_view(socket, editor[:doc])
      _ -> clear_paper_view(socket)
    end
  end

  # ── In-Studio live paper view (convergence/papers-in-studio) ────────────────
  #
  # The editor pane renders a paper's blocks LIVE, reusing PaperLive's render +
  # delta logic. A block-backed paper streams each top-level block as a keyed
  # stream item; an HTML-only (legacy) paper falls back to a raw-HTML re-assign.
  # `{:paper_block,…}` / `{:paper_updated,…}` frames (handle_info below) patch
  # the stream / HTML in place — no rebuild_panes, no remount.

  defp setup_paper_view(socket, %{content: content} = paper) when is_map(content) do
    blocks = Map.get(content, "blocks")
    rev = Map.get(content, "rev") || 0
    html = Map.get(content, "body_html") || ""

    if is_list(blocks) do
      socket
      |> assign(
        editor_view: :paper,
        paper_doc: paper,
        paper_rev: rev,
        paper_html: html,
        paper_block_mode: true,
        # Opening (or jumping to) a paper always lands in read-only View mode.
        paper_edit_mode: false
      )
      |> stream(:paper_blocks, paper_stream_items(blocks), reset: true)
    else
      socket
      |> assign(
        editor_view: :paper,
        paper_doc: paper,
        paper_rev: rev,
        paper_html: html,
        paper_block_mode: false,
        paper_edit_mode: false
      )
      |> stream(:paper_blocks, [], reset: true)
    end
  end

  defp setup_paper_view(socket, _paper), do: clear_paper_view(socket)

  defp clear_paper_view(socket) do
    if socket.assigns[:editor_view] == :paper do
      assign(socket,
        editor_view: :form,
        paper_doc: nil,
        paper_rev: 0,
        paper_html: "",
        paper_block_mode: false,
        paper_edit_mode: false
      )
    else
      assign(socket, editor_view: :form)
    end
  end

  # Each stream item carries a stable id (the block id) and its rendered
  # fragment. Top-level blocks stream individually; a `section` renders as one
  # fragment (its children live inside it). Mirrors PaperLive.to_stream_items/1.
  defp paper_stream_items(blocks) do
    Enum.map(blocks, fn block ->
      %{id: Map.get(block, "id"), html: Render.render_block(block)}
    end)
  end

  # Stream dom ids are namespaced by the stream name (`:paper_blocks` →
  # `"paper_blocks-<id>"`, per Phoenix.LiveView.LiveStream.default_id/2), so a
  # remove-block delete-by-id must mirror that exact prefix — the UNDERSCORE in
  # `paper_blocks` matters; a hyphen here would silently never match.
  defp paper_block_dom_id(id), do: "paper_blocks-#{id}"

  # A gap is any received rev that is not exactly the next one we expect. The
  # first delta on a paper mounted at rev 0 (never-streamed) also refetches —
  # correct: there is nothing to append onto. Mirrors PaperLive.gap?/2.
  defp paper_gap?(last_rev, incoming_rev)
       when is_integer(last_rev) and is_integer(incoming_rev) do
    incoming_rev != last_rev + 1
  end

  defp paper_gap?(_last, _incoming), do: true

  defp apply_paper_delta(socket, %{op_kind: "remove-block", block_id: id} = frame) do
    socket
    |> stream_delete_by_dom_id(:paper_blocks, paper_block_dom_id(id))
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  defp apply_paper_delta(
         socket,
         %{op_kind: kind, block_id: id, fragment_html: html, position: pos} = frame
       )
       when kind in ["append-block", "insert-after"] and is_integer(pos) do
    # A NEW block enters the stream at its known top-level index so a
    # mid-document insert-after lands in order — not appended to the end.
    socket
    |> stream_insert(:paper_blocks, %{id: id, html: html}, at: pos)
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  defp apply_paper_delta(socket, %{block_id: id, fragment_html: html} = frame) do
    # patch-block / replace-block (and any new block whose top-level position is
    # unknown, e.g. one nested in a section): upsert by id, in place (no `at:`)
    # so editing a block never reorders it. The rev-gap path repairs residual
    # ordering on the next full refetch.
    socket
    |> stream_insert(:paper_blocks, %{id: id, html: html})
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  defp refetch_paper(socket) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id
    dataset = socket.assigns.dataset

    case slug && Content.get_paper(slug, dataset) do
      nil ->
        socket

      paper ->
        content = paper.content || %{}

        case Map.get(content, "blocks") do
          blocks when is_list(blocks) ->
            socket
            |> stream(:paper_blocks, paper_stream_items(blocks), reset: true)
            |> assign(:paper_doc, paper)
            |> assign(:paper_rev, Map.get(content, "rev") || 0)
            |> assign(:paper_block_mode, true)

          _ ->
            socket
            |> assign(:paper_doc, paper)
            |> assign(:paper_html, Map.get(content, "body_html") || "")
            |> assign(:paper_rev, Map.get(content, "rev") || 0)
            |> assign(:paper_block_mode, false)
        end
    end
  end

  # Fetch the published twin of the currently-open draft, if any. Returns
  # nil when the editor is closed, the open doc is not a draft, or no
  # published version exists (the toggle button is gated on these same
  # flags so the diff view never opens without both sides).
  #
  # Called from `rebuild_panes/1` so the data is ready on first render —
  # we deliberately don't refresh `published_doc` on autosave: the
  # published twin doesn't change while the user types, so refetching on
  # every keystroke would just burn DB round-trips.
  defp fetch_published_twin(nil, _type, _dataset, _is_draft, _has_published), do: nil
  defp fetch_published_twin(_doc, nil, _dataset, _is_draft, _has_published), do: nil
  defp fetch_published_twin(_doc, _type, _dataset, false, _has_published), do: nil
  defp fetch_published_twin(_doc, _type, _dataset, _is_draft, false), do: nil

  defp fetch_published_twin(doc, type, dataset, true, true) do
    case Content.get_document(Content.published_id(doc.doc_id), type, dataset) do
      {:ok, pub} -> pub
      _ -> nil
    end
  end

  # ── Cross-field validations (Task barkpark-cgn) ─────────────────────────────
  # Computes the list of unsatisfied cross-validations against the current
  # editor form using `Barkpark.Content.CrossValidator`. The form may be `nil`
  # or empty when no document is in scope — the validator already short-circuits
  # on `validate(_, doc)` non-map docs, but we hard-gate `nil` here to keep
  # the assign always a list (LiveView templates rely on enumeration).
  defp compute_cross_violations(nil, _), do: []
  defp compute_cross_violations(_, form) when not is_map(form), do: []

  defp compute_cross_violations(schema, form) do
    Barkpark.Content.CrossValidator.violations(schema, form)
  end

  # Pick the active tab when the editor pane re-renders. Sanity-Studio
  # default-tab semantics: when the schema changes (or first loads), reset
  # to the schema's first declared group; when the schema is unchanged,
  # keep whatever tab the user was on so autosave round-trips don't
  # snap them back to "Core" mid-edit. Schemas with no `groups:` get
  # `nil` here — that's the legacy/no-tab-bar path, and visible_fields/2
  # turns it into "show all fields" for back-compat.
  defp resolve_nav_group(_current, _old, nil), do: nil

  defp resolve_nav_group(current, old, new_schema) do
    cond do
      schema_id(new_schema) == schema_id(old) and current != nil -> current
      true -> first_group_name(new_schema)
    end
  end

  defp schema_id(nil), do: nil
  defp schema_id(schema), do: Map.get(schema, :name) || Map.get(schema, "name")

  defp first_group_name(schema) do
    case BarkparkWeb.StudioComponents.schema_groups(schema) do
      [%{"name" => name} | _] -> name
      _ -> nil
    end
  end

  # ── In-Studio live paper view (function component) ──────────────────────────
  #
  # Renders a paper LIVE inside the editor pane. Block-backed papers stream each
  # top-level block as a keyed `phx-update="stream"` item; HTML-only (legacy)
  # papers render `raw(@paper_html)`. The `#paper-sentinel` element is rendered
  # once OUTSIDE the streamed container so a `handle_info` DOM diff preserves it
  # — the same no-reload proof PaperLive uses, now inside the Studio. Read-only:
  # editing stays on the paper-ingest ops endpoint.
  attr :paper_doc, :map, default: nil
  attr :paper_rev, :integer, default: 0
  attr :paper_html, :string, default: ""
  attr :paper_block_mode, :boolean, default: false
  attr :paper_edit_mode, :boolean, default: false
  attr :dataset, :string, required: true
  attr :api_token_raw, :string, default: ""
  attr :streams, :map, required: true

  defp studio_paper_view(assigns) do
    slug = assigns.paper_doc && assigns.paper_doc.doc_id
    title = (assigns.paper_doc && assigns.paper_doc.title) || slug || "Paper"

    edit_blocks =
      case assigns.paper_doc do
        %{content: %{"blocks" => blocks}} when is_list(blocks) -> blocks
        _ -> []
      end

    assigns = assign(assigns, slug: slug, title: title, edit_blocks: edit_blocks)

    ~H"""
    <div class="editor-panel" data-test-id="studio-paper-editor">
      <.document_header dataset={@dataset} title={@title}>
        <:status_pill>
          <span class="badge badge-published">paper</span>
        </:status_pill>
        <:actions>
          <%!-- View ⇄ Edit toggle. View is the read-only live stream; Edit
                renders the per-block controls. Block-backed papers only. --%>
          <button
            :if={@slug && @paper_block_mode}
            type="button"
            class={"btn btn-sm " <> if(@paper_edit_mode, do: "btn-primary", else: "btn-ghost")}
            phx-click="paper-toggle-edit"
            data-test-id="paper-edit-toggle"
          >
            <.icon name={if @paper_edit_mode, do: "eye", else: "pencil"} size={14} />
            <%= if @paper_edit_mode, do: "View", else: "Edit" %>
          </button>
          <a
            :if={@slug}
            href={"/papers/#{@slug}"}
            class="btn btn-ghost btn-sm"
            target="_blank"
            rel="noopener"
            data-test-id="paper-open-standalone"
          >
            <.icon name="external-link" size={14} /> Open standalone
          </a>
        </:actions>
      </.document_header>

      <div class="editor-with-preview">
        <div class="editor-body editor-panel-main">
          <main class="bp-paper-shell" data-test-id="studio-paper-shell">
            <%!-- Sentinel: rendered once, OUTSIDE the streamed/re-assigned
                  container. It survives a handle_info DOM diff but would be
                  torn down by a remount/navigate — the no-reload proof. --%>
            <div id="paper-sentinel" data-slug={@slug} hidden></div>

            <%= cond do %>
              <% is_nil(@slug) -> %>
                <article id="paper-body" data-rev={@paper_rev}>
                  <p id="paper-empty">No paper selected.</p>
                </article>
              <% @paper_edit_mode && @paper_block_mode -> %>
                <.paper_block_editor
                  slug={@slug}
                  blocks={@edit_blocks}
                  paper_rev={@paper_rev}
                  dataset={@dataset}
                  api_token_raw={@api_token_raw}
                />
              <% @paper_block_mode -> %>
                <%!-- Block-backed: each top-level block is its own keyed stream
                      item. A delta patches/appends/deletes ONE of these.

                      The container id is keyed on the slug so jumping to a
                      DIFFERENT paper hands LiveView a NEW stream container —
                      it tears down the prior paper's block DOM instead of
                      reusing nodes whose block ids happen to collide across
                      papers (the "stale content after a jump" bug). Within
                      the SAME paper the id is stable, so `{:paper_block}`
                      deltas still diff in place with no remount. --%>
                <article
                  id={"paper-body-#{@slug}"}
                  data-rev={@paper_rev}
                  phx-update="stream"
                >
                  <div
                    :for={{dom_id, block} <- @streams.paper_blocks}
                    id={dom_id}
                    data-block-id={block.id}
                  >
                    {raw(block.html)}
                  </div>
                </article>
              <% true -> %>
                <%!-- HTML-only (legacy): whole opaque body, re-assigned on
                      update. Keyed on the slug too so a jump swaps the node. --%>
                <article id={"paper-body-#{@slug}"} data-rev={@paper_rev}>{raw(@paper_html)}</article>
            <% end %>
          </main>
        </div>
      </div>
    </div>
    """
  end

  # ── Paper block editor (function component) ─────────────────────────────────
  #
  # Edit mode for a block-backed paper. Renders per-block edit controls; each
  # control fires a `paper-*` event that maps to ONE DocPatchOp. The container
  # is keyed on the slug + rev so a jump or an op refreshes it cleanly. This is
  # plain assign-driven HTML (no stream) — the read-only View pane is the
  # streamed surface; this editor reads from `paper_doc.content["blocks"]`.
  attr :slug, :string, required: true
  attr :blocks, :list, required: true
  attr :paper_rev, :integer, default: 0
  attr :dataset, :string, default: "production"
  attr :api_token_raw, :string, default: ""

  defp paper_block_editor(assigns) do
    ~H"""
    <div id={"paper-editor-#{@slug}"} class="bp-paper-editor" data-test-id="studio-paper-block-editor">
      <p :if={@blocks == []} class="bp-paper-editor-empty">
        This paper has no blocks yet. Add one below.
      </p>

      <div :for={block <- @blocks} class="bp-paper-edit-block" data-edit-block-id={Map.get(block, "id")}>
        <div class="bp-paper-edit-toolbar">
          <span class="bp-paper-edit-kind"><%= Map.get(block, "type") %></span>
          <span class="bp-paper-edit-actions">
            <button
              type="button"
              class="btn btn-ghost btn-sm"
              title="Move up"
              phx-click="paper-move-block"
              phx-value-id={Map.get(block, "id")}
              phx-value-dir="up"
            >▲</button>
            <button
              type="button"
              class="btn btn-ghost btn-sm"
              title="Move down"
              phx-click="paper-move-block"
              phx-value-id={Map.get(block, "id")}
              phx-value-dir="down"
            >▼</button>
            <button
              type="button"
              class="btn btn-destructive btn-sm"
              title="Delete block"
              phx-click="paper-delete-block"
              phx-value-id={Map.get(block, "id")}
              data-test-id="paper-delete-block"
            >×</button>
          </span>
        </div>
        <.paper_block_fields block={block} dataset={@dataset} api_token_raw={@api_token_raw} />
      </div>

      <%!-- Add-block dropdown. The `+ Add` <select> fires append-block (no
            anchor) of the chosen type via paper-add-block. --%>
      <form
        class="bp-paper-add-block"
        phx-submit="paper-add-block"
        data-test-id="paper-add-block"
      >
        <label>
          + Add block
          <select name="block-type">
            <option value="paragraph">Paragraph</option>
            <option value="heading">Heading</option>
            <option value="list">List</option>
            <option value="callout">Callout</option>
            <option value="code">Code</option>
            <option value="divider">Divider</option>
            <option value="section">Section</option>
          </select>
        </label>
        <button type="submit" class="btn btn-primary btn-sm">Add</button>
      </form>
    </div>
    """
  end

  # Per-block-type edit fields. Each `<form phx-submit="paper-edit-block">`
  # carries a hidden `id` and submits its changed field(s); the handler maps
  # the params to a patch-block op. Paragraph/callout bodies are PLAIN TEXT in
  # the MVP (inline marks dropped on save).
  attr :block, :map, required: true
  attr :dataset, :string, default: "production"
  attr :api_token_raw, :string, default: ""

  defp paper_block_fields(assigns) do
    assigns =
      assign(assigns, id: Map.get(assigns.block, "id"), type: Map.get(assigns.block, "type"))

    ~H"""
    <%= case @type do %>
      <%!-- Rich-text blocks (paragraph / heading / list) are edited by the
            <bp-paper-editor> Web Component. The phx-update="ignore" wrapper
            keeps LiveView from re-diffing the WC's internal DOM (preserving
            the caret across server updates); its id is stable per block id so
            it survives re-renders. The WC reads its initial block from
            data-block and emits debounced `bp-op` events that the
            BarkparkPaperEditor hook forwards to the server's paper-op handler.
            field-type blocks (callout/code/list-as-fields/section/divider/…)
            keep their existing form-based editors below — out of scope here. --%>
      <% t when t in ["paragraph", "heading", "list"] -> %>
        <div
          phx-update="ignore"
          id={"paper-ed-" <> @id}
          phx-hook="BarkparkPaperEditor"
          class="bp-paper-edit-wc"
          data-test-id="paper-block-editor-wc"
        >
          <bp-paper-editor data-block={Jason.encode!(@block)}></bp-paper-editor>
        </div>
      <% "callout" -> %>
        <form class="bp-paper-edit-form" phx-submit="paper-edit-block">
          <input type="hidden" name="block_id" value={@id} />
          <select name="tone" class="bp-paper-edit-tone">
            <option :for={t <- ~w(info success warning danger neutral)} value={t} selected={Map.get(@block, "tone") == t}>
              <%= t %>
            </option>
          </select>
          <input
            type="text"
            name="title"
            class="bp-paper-edit-text"
            placeholder="Title (optional)"
            value={Map.get(@block, "title", "")}
          />
          <textarea
            name="text"
            class="bp-paper-edit-textarea"
            rows="3"
            data-test-id="paper-field-text"
          ><%= inline_to_text(Map.get(@block, "content", [])) %></textarea>
          <button type="submit" class="btn btn-sm">Save</button>
        </form>
      <% "code" -> %>
        <form class="bp-paper-edit-form" phx-submit="paper-edit-block">
          <input type="hidden" name="block_id" value={@id} />
          <input
            type="text"
            name="lang"
            class="bp-paper-edit-text"
            placeholder="lang"
            value={Map.get(@block, "lang", "")}
          />
          <textarea
            name="value"
            class="bp-paper-edit-textarea bp-paper-edit-code"
            rows="5"
            data-test-id="paper-field-value"
          ><%= Map.get(@block, "value", "") %></textarea>
          <button type="submit" class="btn btn-sm">Save</button>
        </form>
      <% "section" -> %>
        <form class="bp-paper-edit-form" phx-submit="paper-edit-block">
          <input type="hidden" name="block_id" value={@id} />
          <input
            type="text"
            name="title"
            class="bp-paper-edit-text"
            placeholder="Section title"
            value={Map.get(@block, "title", "")}
            data-test-id="paper-field-title"
          />
          <button type="submit" class="btn btn-sm">Save</button>
        </form>
      <% "divider" -> %>
        <p class="bp-paper-edit-readonly">— divider —</p>

      <%!-- field-* LEAF blocks (P2.1). Each renders a labelled native control
            inside a stable phx-update="ignore" wrapper mounted with the
            BarkparkFieldBlockBridge hook. The hook reads data-field-type to
            coerce the value, builds a patch-block op carrying {value:…}, and
            pushes it through the same `paper-op` pipeline the rich-text WC uses.
            phx-update="ignore" keeps LiveView from re-stamping the control's
            value mid-edit (server owns the model; no echo). --%>
      <% t when t in ["field-string", "field-slug"] -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <input type="text" class="bp-paper-edit-text" value={Map.get(@block, "value", "")}
                 data-test-id={"paper-field-" <> @type} />
        </div>

      <% "field-text" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <textarea class="bp-paper-edit-textarea" rows={Map.get(@block, "rows") || 3}
                    data-test-id="paper-field-field-text"><%= Map.get(@block, "value", "") %></textarea>
        </div>

      <% "field-boolean" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <input type="checkbox" checked={Map.get(@block, "value") == true}
                 data-test-id="paper-field-field-boolean" />
        </div>

      <% "field-select" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <select class="form-input" data-test-id="paper-field-field-select">
            <option :for={o <- Map.get(@block, "options", [])}
                    value={Map.get(o, "value")}
                    selected={Map.get(o, "value") == Map.get(@block, "value")}>
              <%= Map.get(o, "label", Map.get(o, "value", "")) %>
            </option>
          </select>
        </div>

      <% "field-datetime" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <input type="datetime-local" class="form-input" value={Map.get(@block, "value", "")}
                 data-test-id="paper-field-field-datetime" />
        </div>

      <% "field-color" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <input type="color" value={Map.get(@block, "value", "#000000")}
                 data-test-id="paper-field-field-color"
                 style="width:36px;height:36px;border:1px solid var(--input);border-radius:6px;cursor:pointer;background:transparent;" />
        </div>

      <%!-- field-reference / field-image PICKER blocks (P2.2). The Edit control
            is an existing picker Web Component (bp-reference-picker /
            bp-media-picker) rather than a native control. Each WC owns its own
            search / select / clear UX and emits a bubbling `bp-change`
            CustomEvent({detail:{value}}) on selection — the SAME event the
            classic field_inputs.ex renderer relies on. BarkparkFieldBlockBridge
            (root.html.heex) listens for that `bp-change` (in addition to native
            input/change) and pushes a {op:"patch-block",id,patch:{value}} op
            through the same `paper-op` pipeline. The reference WC reads its
            refType + dataset from inline block attrs; the media WC reads the
            raw bearer token from data-token (empty disables upload, browse +
            select still work). value is a plain string in both cases. --%>
      <% "field-reference" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <bp-reference-picker
            value={Map.get(@block, "value", "")}
            ref-type={Map.get(@block, "refType", "")}
            dataset={Map.get(@block, "dataset", @dataset)}
            data-test-id="paper-field-field-reference"
          ></bp-reference-picker>
        </div>

      <% "field-image" -> %>
        <div phx-update="ignore" id={"paper-fld-" <> @id} phx-hook="BarkparkFieldBlockBridge"
             data-block-id={@id} data-field-type={@type} class="bp-paper-edit-field">
          <label class="bp-paper-edit-fieldlabel"><%= Map.get(@block, "label", "") %></label>
          <bp-media-picker
            value={Map.get(@block, "value", "")}
            data-token={@api_token_raw}
            data-test-id="paper-field-field-image"
          ></bp-media-picker>
        </div>

      <% _ -> %>
        <%!-- image / table and any other type are read-only in the MVP. --%>
        <p class="bp-paper-edit-readonly">
          <%= @type %> blocks are not editable yet (view/delete/reorder only).
        </p>
    <% end %>
    """
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.presence_nav
      user_id={@user_id}
      user_name={@user_name}
      user_color={@user_color}
      presences={@presences}
      editor_doc={@editor_doc}
      dataset={@dataset}
    />

    <.pane_layout id="studio-panes">
      <% has_editor = @editor_doc != nil %>
      <% num_panes = length(@panes) %>
      <%= for {pane, idx} <- Enum.with_index(@panes) do %>
        <% collapsed = PaneBuilder.collapse?(idx, num_panes, has_editor) %>
        <.pane_column
          id={"pane-#{pane.title |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "-")}"}
          title={pane.title}
          collapsed={collapsed}
          phx_click={if collapsed, do: "expand-pane", else: nil}
          phx_value_idx={if collapsed, do: "#{idx}", else: nil}
        >
          <:header_actions>
            <%= if pane[:type_name] do %>
              <button
                class="pane-add-btn"
                phx-click="new-document"
                phx-value-type={pane.type_name}
              ><.icon name="plus" size={14} /></button>
            <% end %>
          </:header_actions>

          <%= if Map.get(pane, :desk_groups, []) != [] do %>
            <div class="bp-desk-filter" role="tablist" aria-label="Desk filters">
              <%= for grp <- pane.desk_groups do %>
                <% gname = Map.get(grp, "name") || Map.get(grp, :name) %>
                <% gtitle = Map.get(grp, "title") || Map.get(grp, :title) || gname %>
                <% active = to_string(gname) == to_string(pane[:active_desk] || "") %>
                <a
                  class={"bp-desk-chip " <> if(active, do: "is-active", else: "")}
                  role="tab"
                  aria-selected={active}
                  href={desk_chip_href(@nav_path, @dataset, gname)}
                  phx-click="select-desk"
                  phx-value-desk={gname}
                ><%= gtitle %></a>
              <% end %>
            </div>
          <% end %>

          <div class="pane-body">
            <%= for item <- pane.items do %>
              <%= case item.type do %>
                <% :divider -> %>
                  <%= if item[:label] && item[:label] != "" do %>
                    <div class="pane-divider pane-divider--labelled" role="separator" aria-label={item[:label]}>
                      <span class="pane-divider-label"><%= item[:label] %></span>
                    </div>
                  <% else %>
                    <.pane_divider />
                  <% end %>

                <% :header -> %>
                  <.pane_section_header>
                    <.icon name={item.icon} size={12} /> <%= item.title %>
                  </.pane_section_header>

                <% :plugin_link -> %>
                  <a
                    id={"plugin-link-#{item.id}"}
                    href={item.href}
                    class="pane-item nav-plugin-entry"
                    data-test-id="nav-plugin-entry"
                  >
                    <%= if item.icon do %>
                      <span class="pane-item-icon"><.icon name={item.icon} size={16} /></span>
                    <% end %>
                    <span class="pane-item-label"><%= item.title %></span>
                  </a>

                <% :doc -> %>
                  <% item_presences = PresenceState.on_doc(@presences, item.id) %>
                  <.pane_doc_item
                    id={"doc-#{item.id}"}
                    phx_click="select"
                    phx_value_pane={"#{idx}"}
                    phx_value_id={item.id}
                    title={item.title}
                    doc_id={item.id}
                    status={item.status || ""}
                    is_draft={item.is_draft}
                    selected={item.id == pane[:selected]}
                    selectable={pane[:type_name] != nil}
                    checked={MapSet.member?(@selected_doc_ids, item.id)}
                  >
                    <:trailing :if={item_presences != []}>
                      <%= for p <- item_presences do %>
                        <span class="presence-dot-sm" style={"background: #{p.color}"}></span>
                      <% end %>
                    </:trailing>
                  </.pane_doc_item>

                <% _ -> %>
                  <.pane_item
                    id={"item-#{item.id}"}
                    phx_click="select"
                    phx_value_id={item.id}
                    phx_value_pane={"#{idx}"}
                    selected={item.id == pane[:selected]}
                  >
                    <:icon><.icon name={item.icon} size={16} /></:icon>
                    <%= item.title %>
                    <:trailing :if={item[:drillable]}>
                      <.icon name="chevron-right" size={14} />
                    </:trailing>
                  </.pane_item>
              <% end %>
            <% end %>
          </div>
        </.pane_column>
      <% end %>

      <!-- TODO: editor column is hand-rolled because its header merges
           pane-header with editor-header and has presence dots + publish
           buttons. Migrating cleanly requires a custom-header slot on
           pane_column that fully replaces the default title row. See
           docs/superpowers/plans/2026-04-14-unified-pane-components.md. -->
      <!-- Editor — a paper opens as a LIVE read-only block view in this same
           pane (convergence/papers-in-studio); every other doc type opens the
           field form via studio_editor_shell. The left structure pane + the
           Papers list pane (rendered above) stay visible either way. -->
      <%= if @editor_view == :paper do %>
        <.studio_paper_view
          paper_doc={@paper_doc}
          paper_rev={@paper_rev}
          paper_html={@paper_html}
          paper_block_mode={@paper_block_mode}
          paper_edit_mode={@paper_edit_mode}
          dataset={@dataset}
          streams={@streams}
        />
      <% else %>
        <.studio_editor_shell
          editor_doc={@editor_doc}
          editor_schema={@editor_schema}
          editor_type={@editor_type}
          editor_form={@editor_form}
          editor_is_draft={@editor_is_draft}
          dataset={@dataset}
          validation_errors={@validation_errors}
          cross_violations={@cross_violations}
          save_status={@save_status}
          presences={@presences}
          parent_assigns={assigns}
          nav_group={@nav_group}
          content_preview_rendered={@content_preview_rendered}
          content_preview_visible={@content_preview_visible}
          diff_visible={@diff_visible}
          published_doc={@published_doc}
          doc_actions={resolved_doc_actions(assigns)}
        />
      <% end %>
      <!-- doc_actions flows through Registry.collect_doc_actions/1 with
           the host's `default_doc_actions/2` as :baseline. Plugins
           implementing resolve_doc_actions/2 can hide, reorder, or extend
           the editor-header action list. See Goal barkpark-cjs s4. -->

      <!-- E2 secondary editor (read-only) — sits in the layout flex
           row so it lands to the right of the primary editor pane. -->
      <.secondary_editor_card
        secondary_doc={@secondary_doc}
        secondary_schema={@secondary_schema}
        secondary_type={@secondary_type}
      />

      <!-- E2 secondary picker modal -->
      <.secondary_picker_modal
        show_secondary_picker={@show_secondary_picker}
        secondary_search={@secondary_search}
        secondary_candidates={@secondary_candidates}
      />

      <!-- E3 bulk publish floating action bar -->
      <.bulk_action_bar selected_doc_ids={@selected_doc_ids} />

      <!-- Schema-action ConfirmModal — gated by `confirm_modal` assign -->
      <%= if @confirm_modal do %>
        <% modal = @confirm_modal.action["modal"] || %{} %>
        <BarkparkWeb.Components.ConfirmModal.confirm_modal
          id="schema-action-confirm-modal"
          title={modal["title"] || @confirm_modal.action["label"]}
          body={modal["body"]}
          stage={@confirm_modal.stage}
          on_cancel="close-confirm-modal"
          on_confirm="confirm-modal-dryrun"
          on_real="confirm-modal-real"
        />
      <% end %>

      <!-- Profile + 4 content modals; all gated by their show/picker assigns -->
      <.studio_modals
        show_profile={@show_profile}
        user_name={@user_name}
        user_color={@user_color}
        image_picker_field={@image_picker_field}
        uploads={@uploads}
        media_files={@media_files}
        ref_picker_field={@ref_picker_field}
        ref_search={@ref_search}
        ref_candidates={@ref_candidates}
        show_history={@show_history}
        revisions={@revisions}
        show_delete={@show_delete}
        delete_refs={@delete_refs}
        editor_doc={@editor_doc}
      />
    </.pane_layout>

    """
  end
end
