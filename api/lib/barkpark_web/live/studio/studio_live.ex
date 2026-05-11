defmodule BarkparkWeb.Studio.StudioLive do
  @moduledoc """
  Multi-pane studio — mirrors the TUI's pane drill-down.
  Structure → Type → Documents → Editor
  """
  use BarkparkWeb, :live_view

  alias Barkpark.{Content, Media, Structure}
  alias BarkparkWeb.Components.Fields.ArrayField
  alias BarkparkWeb.Presence
  alias BarkparkWeb.Studio.{PaneBuilder, PresenceState}

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
       confirm_modal: nil
     )
     |> allow_upload(:image,
       accept: ~w(.jpg .jpeg .png .gif .webp .svg),
       max_entries: 1,
       max_file_size: 10_000_000
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    dataset = params["dataset"] || "production"
    path = Map.get(params, "path", [])

    if connected?(socket) and socket.assigns[:dataset] != dataset do
      if old = socket.assigns[:dataset] do
        Phoenix.PubSub.unsubscribe(Barkpark.PubSub, "documents:#{old}")
      end

      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")
    end

    socket =
      socket
      |> assign(dataset: dataset, nav_path: path)
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
           socket.assigns.dataset
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
  def handle_event(
        "array_op",
        %{"action" => action, "field" => field_name} = params,
        socket
      ) do
    field = find_field(socket, field_name)

    if is_nil(field) do
      {:noreply, socket}
    else
      idx = parse_idx(params["index"])
      form = socket.assigns[:editor_form] || %{}
      current = list_value(form, field_name)

      new_list =
        case action do
          "add_row" -> ArrayField.add_row(current, empty_for_of(field))
          "remove_row" -> ArrayField.remove_row(current, idx)
          "move_up" -> ArrayField.move_up(current, idx)
          "move_down" -> ArrayField.move_down(current, idx)
          _ -> current
        end

      new_form = Map.put(form, field_name, new_list)
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

      Content.delete_document(doc.doc_id, type, socket.assigns.dataset)
      new_path = Enum.take(socket.assigns.nav_path, length(socket.assigns.nav_path) - 1)

      {:noreply,
       socket
       |> assign(show_delete: false, delete_refs: [])
       |> push_patch(to: studio_path(new_path, socket.assigns.dataset))}
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

    case Content.restore_revision(rev_id, type, socket.assigns.dataset) do
      {:ok, _doc} ->
        {:noreply,
         socket
         |> assign(show_history: false, revisions: [])
         |> put_flash(:info, "Restored from history")
         |> rebuild_panes()}

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
          do_action(
            socket,
            fn d, t ->
              Content.publish_document(Content.published_id(d.doc_id), t, socket.assigns.dataset)
            end,
            "Published"
          )
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("unpublish", _, socket) do
    do_action(
      socket,
      fn doc, type ->
        Content.unpublish_document(Content.published_id(doc.doc_id), type, socket.assigns.dataset)
      end,
      "Unpublished"
    )
  end

  # ── Schema-declared document actions (Task #16 — action registry) ──────────
  #
  # Schemas advertise document-level actions via the `:actions` array on the
  # SchemaDefinition row. The editor pane renders a button per action; clicking
  # a `kind: "modal"` action lands here. The generic ConfirmModal opens with
  # the action's metadata; dry-run and real confirmations route through
  # `confirm-modal-dryrun` / `confirm-modal-real` below, each of which
  # dispatches into the plugin-owned action handler (e.g.
  # `Barkpark.Plugins.OnixEdit.Actions.publish_to_bokbasen/3`). `kind: "link"`
  # actions never hit this handler — they're rendered as anchor tags
  # interpolated with `interpolate_action_href/3`, so a click is a plain
  # HTTP navigation.
  def handle_event("schema_action", %{"name" => name}, socket) do
    action = find_schema_action(socket.assigns[:editor_schema], name)

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
        result = dispatch_action(name, doc_id, dataset, :dryrun)
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
        case dispatch_action(name, doc_id, dataset, :real) do
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
      case Content.upsert_draft(doc, type, schema, params, socket.assigns.dataset) do
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
            validation_errors: errs
          )

        {:error, _} ->
          assign(socket, save_status: "Save failed")
      end
    else
      socket
    end
  end

  defp do_action(socket, action, msg) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      case action.(doc, type) do
        {:ok, _} -> {:noreply, socket |> put_flash(:info, msg) |> rebuild_panes()}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Action failed")}
      end
    else
      {:noreply, socket}
    end
  end

  defp studio_path(path, dataset), do: studio_path_for(path, dataset)
  defp studio_path_for([], dataset), do: "/studio/#{dataset}"
  defp studio_path_for(segments, dataset), do: "/studio/#{dataset}/" <> Enum.join(segments, "/")

  # ── Schema-action helpers (Task #16 — action registry) ─────────────────────

  defp schema_actions(nil), do: []

  defp schema_actions(schema) do
    case Map.get(schema, :actions) || Map.get(schema, "actions") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp find_schema_action(schema, name) do
    schema
    |> schema_actions()
    |> Enum.find(fn a -> Map.get(a, "name") == name end)
  end

  # Dispatch a named schema action to the plugin-owned handler. The
  # registry only points at modal actions today (publish_to_bokbasen); the
  # `_` clause is the safety net so an unknown name returns a structured
  # error instead of a function-clause crash.
  defp dispatch_action("publish_to_bokbasen", doc_id, dataset, mode) do
    Barkpark.Plugins.OnixEdit.Actions.publish_to_bokbasen(doc_id, dataset, mode)
  end

  defp dispatch_action(name, _doc_id, _dataset, _mode) do
    {:error, {:unknown_action, name}}
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

  # Substitute `:dataset` and `:id` in an href template. The published id is
  # used (drafts. prefix stripped) so links always target the canonical URL.
  defp interpolate_action_href(nil, _doc, _dataset), do: "#"

  defp interpolate_action_href(href, doc, dataset) when is_binary(href) do
    id =
      case doc do
        %{doc_id: doc_id} -> Content.published_id(doc_id)
        _ -> ""
      end

    href
    |> String.replace(":dataset", to_string(dataset || ""))
    |> String.replace(":id", id)
  end

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

  defp list_value(form, field_name) do
    case Map.get(form, field_name) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # Empty-element factory — picks a sensible default for a freshly-added row
  # based on the arrayOf element's declared type. composite → empty map;
  # arrayOf → empty list; localizedText → empty map; everything else → nil.
  defp empty_for_of(%{"of" => %{"type" => "composite"} = of}) do
    Enum.reduce(of["fields"] || [], %{}, fn sub, acc ->
      Map.put(acc, sub["name"], empty_for_type(sub["type"]))
    end)
  end

  defp empty_for_of(%{"of" => %{"type" => "arrayOf"}}), do: []
  defp empty_for_of(%{"of" => %{"type" => "codelist"}}), do: nil
  defp empty_for_of(%{"of" => %{"type" => "localizedText"}}), do: %{}
  defp empty_for_of(%{"of" => %{"type" => _}}), do: nil
  defp empty_for_of(_), do: nil

  defp empty_for_type("composite"), do: %{}
  defp empty_for_type("arrayOf"), do: []
  defp empty_for_type("localizedText"), do: %{}
  # strings, codelists, booleans, datetimes, etc. — all start as nil so the
  # validator surfaces "required" errors instead of fake-empty values.
  defp empty_for_type(_), do: nil

  # ── Pane builder ───────────────────────────────────────────────────────────

  defp rebuild_panes(socket) do
    {panes, editor} = PaneBuilder.build(socket.assigns.dataset, socket.assigns.nav_path)

    assign(socket,
      panes: panes,
      editor_doc: editor && editor[:doc],
      editor_schema: editor && editor[:schema],
      editor_type: editor && editor[:type],
      editor_is_draft: (editor && editor[:is_draft]) || false,
      editor_has_published: (editor && editor[:has_published]) || false,
      editor_form: (editor && editor[:form]) || %{},
      save_status: socket.assigns[:save_status] || ""
    )
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

          <div class="pane-body">
            <%= for item <- pane.items do %>
              <%= case item.type do %>
                <% :divider -> %>
                  <.pane_divider />

                <% :header -> %>
                  <.pane_section_header>
                    <.icon name={item.icon} size={12} /> <%= item.title %>
                  </.pane_section_header>

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
      <!-- Editor -->
      <.studio_editor_shell
        editor_doc={@editor_doc}
        editor_schema={@editor_schema}
        editor_form={@editor_form}
        editor_is_draft={@editor_is_draft}
        dataset={@dataset}
        validation_errors={@validation_errors}
        save_status={@save_status}
        presences={@presences}
        parent_assigns={assigns}
      >
        <:extra_actions>
          <%= for action <- schema_actions(@editor_schema) do %>
            <%= case action["kind"] do %>
              <% "link" -> %>
                <a
                  href={interpolate_action_href(action["href"], @editor_doc, @dataset)}
                  class="btn btn-ghost btn-sm"
                  data-test-id={"schema-action-#{action["name"]}"}
                >
                  <%= action["label"] %>
                </a>
              <% _ -> %>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm"
                  phx-click="schema_action"
                  phx-value-name={action["name"]}
                  data-test-id={"schema-action-#{action["name"]}"}
                >
                  <%= action["label"] %>
                </button>
            <% end %>
          <% end %>
        </:extra_actions>
      </.studio_editor_shell>

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
