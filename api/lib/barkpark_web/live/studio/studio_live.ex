defmodule BarkparkWeb.Studio.StudioLive do
  @moduledoc """
  Multi-pane studio — mirrors the TUI's pane drill-down.
  Structure → Type → Documents → Editor
  """
  use BarkparkWeb, :live_view

  alias Barkpark.{Content, Media, Structure}

  @dataset "production"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")
    end
    {:ok, socket
     |> assign(page_title: "Studio", subscribed_doc: nil, image_picker_field: nil, media_files: [], ref_picker_field: nil, ref_candidates: [], ref_search: "", show_history: false, revisions: [])
     |> allow_upload(:image, accept: ~w(.jpg .jpeg .png .gif .webp .svg), max_entries: 1, max_file_size: 10_000_000)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    path = Map.get(params, "path", [])
    socket = socket |> assign(nav_path: path) |> rebuild_panes() |> subscribe_to_doc()
    {:noreply, socket}
  end

  # Doc-specific update — just patch the editor form, no rebuild
  @impl true
  def handle_info({:doc_updated, %{sender: sender, doc: doc_data}}, socket) do
    if sender != self() && socket.assigns[:editor_doc] do
      # Another user edited this doc — update form values live
      schema = socket.assigns[:editor_schema]
      updated_form = doc_data_to_form(doc_data, schema)
      {:noreply, assign(socket, editor_form: updated_form, save_status: "Updated by another user")}
    else
      {:noreply, socket}
    end
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

  # Autosave triggered programmatically (e.g. after image selection)
  @impl true
  def handle_info({:autosave_form, form}, socket) do
    doc = socket.assigns[:editor_doc]
    schema = socket.assigns[:editor_schema]
    type = socket.assigns[:editor_type]
    if doc && type do
      content = build_content(form, schema)
      attrs = %{
        "doc_id" => Content.draft_id(Content.published_id(doc.doc_id)),
        "title" => Map.get(form, "title", doc.title),
        "status" => Map.get(form, "status", doc.status),
        "content" => content
      }
      case Content.upsert_document(type, attrs, @dataset) do
        {:ok, saved_doc} ->
          panes = update_doc_title_in_panes(socket.assigns.panes, Content.published_id(saved_doc.doc_id), Map.get(form, "title", doc.title))
          {:noreply, assign(socket,
            panes: panes,
            editor_doc: saved_doc,
            editor_is_draft: Content.draft?(saved_doc.doc_id),
            editor_form: form,
            save_status: "Saved")}
        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
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
        topic = "doc:#{@dataset}:#{type}:#{Content.published_id(doc_id)}"
        Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
        assign(socket, subscribed_doc: topic)

      _ ->
        assign(socket, subscribed_doc: nil)
    end
  end

  defp doc_data_to_form(doc_data, schema) do
    base = %{"title" => doc_data.title || "", "status" => doc_data.status || "draft"}
    if schema do
      Enum.reduce(schema.fields, base, fn field, acc ->
        key = field["name"]
        val = if key in ["title", "status"], do: Map.get(acc, key), else: get_in(doc_data.content || %{}, [key]) || ""
        Map.put(acc, key, val)
      end)
    else
      base
    end
  end

  @impl true
  def handle_event("select", %{"pane" => pane_str, "id" => id}, socket) do
    pane_idx = String.to_integer(pane_str)
    new_path = Enum.take(socket.assigns.nav_path, pane_idx) ++ [id]
    {:noreply, push_patch(socket, to: studio_path(new_path))}
  end

  def handle_event("new-document", %{"type" => type}, socket) do
    id = "#{type}-#{:rand.uniform(999_999)}"
    case Content.create_document(type, %{"doc_id" => id, "title" => "Untitled"}, @dataset) do
      {:ok, doc} ->
        # Find the pane that owns this type and build path from there
        pub_id = Content.published_id(doc.doc_id)
        path = socket.assigns.nav_path
        # The type pane is the last path segment before the doc
        new_path = Enum.take_while(path, &(&1 != type)) ++ [type, pub_id]
        {:noreply, push_patch(socket, to: studio_path(new_path))}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create")}
    end
  end

  def handle_event("save", %{"doc" => params}, socket) do
    save_doc(socket, params, "Saved")
  end

  def handle_event("autosave", %{"doc" => params}, socket) do
    doc = socket.assigns[:editor_doc]
    schema = socket.assigns[:editor_schema]
    type = socket.assigns[:editor_type]
    if doc && type do
      content = build_content(params, schema)
      new_title = Map.get(params, "title", doc.title)
      attrs = %{
        "doc_id" => Content.draft_id(Content.published_id(doc.doc_id)),
        "title" => new_title,
        "status" => Map.get(params, "status", doc.status),
        "content" => content
      }
      case Content.upsert_document(type, attrs, @dataset) do
        {:ok, saved_doc} ->
          # Update doc list item title without full pane rebuild (avoids resetting inputs)
          panes = update_doc_title_in_panes(socket.assigns.panes, Content.published_id(saved_doc.doc_id), new_title)
          {:noreply, assign(socket,
            panes: panes,
            editor_doc: saved_doc,
            editor_is_draft: Content.draft?(saved_doc.doc_id),
            editor_form: params,
            save_status: "Saved")}
        {:error, _} ->
          {:noreply, assign(socket, save_status: "Save failed")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("autosave", _params, socket) do
    {:noreply, socket}
  end

  # ── Image field events ──────────────────────────────────────────────────────

  def handle_event("open-image-picker", %{"field" => field_name}, socket) do
    files = Media.list_files(@dataset, mime_type: "image/")
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
        case Media.upload(plug_upload, @dataset) do
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
    docs = Content.list_documents(ref_type, @dataset, perspective: :drafts)
    candidates = Enum.map(docs, fn doc ->
      %{id: Content.published_id(doc.doc_id), title: doc.title || "Untitled"}
    end)
    {:noreply, assign(socket, ref_picker_field: field_name, ref_candidates: candidates, ref_search: "")}
  end

  def handle_event("close-ref-picker", _, socket) do
    {:noreply, assign(socket, ref_picker_field: nil, ref_candidates: [], ref_search: "")}
  end

  def handle_event("ref-search", %{"value" => query}, socket) do
    filtered = Enum.filter(socket.assigns.ref_candidates, fn c ->
      String.contains?(String.downcase(c.title), String.downcase(query))
    end)
    {:noreply, assign(socket, ref_search: query, ref_filtered: filtered)}
  end

  def handle_event("select-ref", %{"id" => ref_id, "field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, ref_id)
    socket = assign(socket, editor_form: form, ref_picker_field: nil, ref_candidates: [], ref_search: "")
    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end

  # ── History events ──────────────────────────────────────────────────────────

  def handle_event("show-history", _, socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]
    if doc && type do
      revisions = Content.list_revisions(doc.doc_id, type, @dataset, limit: 30)
      {:noreply, assign(socket, show_history: true, revisions: revisions)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-history", _, socket) do
    {:noreply, assign(socket, show_history: false, revisions: [])}
  end

  def handle_event("restore-revision", %{"id" => rev_id}, socket) do
    type = socket.assigns[:editor_type]
    case Content.restore_revision(rev_id, type, @dataset) do
      {:ok, doc} ->
        {:noreply, socket
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

  defp save_doc(socket, params, flash_msg) do
    doc = socket.assigns[:editor_doc]
    schema = socket.assigns[:editor_schema]
    type = socket.assigns[:editor_type]
    if doc && type do
      content = build_content(params, schema)
      attrs = %{
        "doc_id" => Content.draft_id(Content.published_id(doc.doc_id)),
        "title" => Map.get(params, "title", doc.title),
        "status" => Map.get(params, "status", doc.status),
        "content" => content
      }
      case Content.upsert_document(type, attrs, @dataset) do
        {:ok, _} ->
          socket = assign(socket, save_status: "Saved")
          socket = if flash_msg, do: put_flash(socket, :info, flash_msg), else: socket
          {:noreply, rebuild_panes(socket)}
        {:error, _} ->
          {:noreply, assign(socket, save_status: "Save failed")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("publish", _, socket) do
    do_action(socket, fn doc, type ->
      Content.publish_document(Content.published_id(doc.doc_id), type, @dataset)
    end, "Published")
  end

  def handle_event("unpublish", _, socket) do
    do_action(socket, fn doc, type ->
      Content.unpublish_document(Content.published_id(doc.doc_id), type, @dataset)
    end, "Unpublished")
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

  defp studio_path([]), do: "/studio"
  defp studio_path(segments), do: "/studio/" <> Enum.join(segments, "/")

  defp build_content(params, schema) do
    if schema do
      Enum.reduce(schema.fields, %{}, fn field, acc ->
        key = field["name"]
        val = Map.get(params, key, "")
        if key in ["title", "status"] or val == "", do: acc, else: Map.put(acc, key, val)
      end)
    else
      %{}
    end
  end

  # ── Pane builder ───────────────────────────────────────────────────────────

  defp rebuild_panes(socket) do
    path = socket.assigns.nav_path
    structure = Structure.build(@dataset)

    # Pane 0: root structure list
    root_pane = %{title: structure.title, items: build_list_items(structure), selected: Enum.at(path, 0)}
    panes = [root_pane]

    # Walk path through the structure tree, building panes at each depth
    {panes, editor} = walk_path(path, 0, structure, panes, nil)

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

  # Recursively walk the path, resolving each segment against the current node's children.
  # Mirrors the TUI's rebuildPanes() loop through path segments.
  defp walk_path([], _depth, _current, panes, editor), do: {panes, editor}
  defp walk_path([id | rest], depth, current, panes, _editor) do
    # Find the matching child node (check id first, then type_name)
    found = Enum.find(current.items, fn node ->
      node.id == id || node.type_name == id
    end)

    case found do
      nil ->
        {panes, nil}

      %{type: :list} = node ->
        # Sub-list (e.g. Settings) — add a new list pane column, keep walking
        list_pane = %{title: node.title, items: build_list_items(node), selected: Enum.at(rest, 0)}
        walk_path(rest, depth + 1, node, panes ++ [list_pane], nil)

      %{type: :document_type_list, type_name: type_name} = node ->
        # Document list — add doc list pane, then resolve doc editor if path continues
        schema = case Content.get_schema(type_name, @dataset) do
          {:ok, s} -> s
          _ -> nil
        end

        opts = [perspective: :drafts]
        opts = if node.filter, do: opts ++ [filter: node.filter], else: opts
        docs = Content.list_documents(type_name, @dataset, opts)
        doc_pane = %{
          title: node.title || (schema && schema.title) || type_name,
          icon: node.icon || (schema && schema.icon),
          type_name: type_name,
          items: Enum.map(docs, fn doc ->
            pub_id = Content.published_id(doc.doc_id)
            %{type: :doc, id: pub_id, title: doc.title || "Untitled",
              is_draft: Content.draft?(doc.doc_id), status: doc.status}
          end),
          selected: Enum.at(rest, 0)
        }

        editor = case rest do
          [doc_id | _] ->
            {doc, is_draft, has_pub} = fetch_doc(type_name, doc_id)
            if doc && schema do
              %{doc: doc, schema: schema, type: type_name,
                is_draft: is_draft, has_published: has_pub,
                form: doc_to_form(doc, schema)}
            end
          _ -> nil
        end

        {panes ++ [doc_pane], editor}

      %{type: :document, type_name: type_name} ->
        # Singleton — open editor directly
        schema = case Content.get_schema(type_name, @dataset) do
          {:ok, s} -> s
          _ -> nil
        end

        if schema do
          # Singletons use the type name as the doc ID
          {doc, is_draft, has_pub} = fetch_doc(type_name, type_name)
          editor = if doc do
            %{doc: doc, schema: schema, type: type_name,
              is_draft: is_draft, has_published: has_pub,
              form: doc_to_form(doc, schema)}
          end
          {panes, editor}
        else
          {panes, nil}
        end

      _ ->
        {panes, nil}
    end
  end

  defp build_list_items(node) do
    Enum.flat_map(node.items, fn child ->
      case child.type do
        :divider -> [%{type: :divider, id: child.id}]
        _ ->
          [%{type: :item, id: child.id, title: child.title, icon: child.icon}]
      end
    end)
  end

  defp filter_ref_candidates(candidates, ""), do: candidates
  defp filter_ref_candidates(candidates, nil), do: candidates
  defp filter_ref_candidates(candidates, query) do
    q = String.downcase(query)
    Enum.filter(candidates, fn c ->
      String.contains?(String.downcase(c.title), q) or String.contains?(String.downcase(c.id), q)
    end)
  end

  # Update a doc's title in the pane items list without rebuilding from DB
  defp update_doc_title_in_panes(panes, doc_id, new_title) do
    Enum.map(panes, fn pane ->
      updated_items = Enum.map(pane.items, fn item ->
        if Map.get(item, :type) == :doc && Map.get(item, :id) == doc_id do
          %{item | title: new_title}
        else
          item
        end
      end)
      %{pane | items: updated_items}
    end)
  end

  defp fetch_doc(type, doc_id) do
    draft_r = Content.get_document(Content.draft_id(doc_id), type, @dataset)
    pub_r = Content.get_document(Content.published_id(doc_id), type, @dataset)
    {doc, is_draft} = case draft_r do
      {:ok, d} -> {d, true}
      _ -> case pub_r do
        {:ok, d} -> {d, false}
        _ -> {nil, false}
      end
    end
    {doc, is_draft, match?({:ok, _}, pub_r)}
  end

  defp doc_to_form(nil, _), do: %{}
  defp doc_to_form(doc, schema) do
    base = %{"title" => doc.title || "", "status" => doc.status || "draft"}
    if schema do
      Enum.reduce(schema.fields, base, fn field, acc ->
        key = field["name"]
        val = if key in ["title", "status"], do: Map.get(acc, key), else: get_in(doc.content || %{}, [key]) || ""
        Map.put(acc, key, val)
      end)
    else
      base
    end
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="pane-layout" id="studio-panes">
      <%= for {pane, idx} <- Enum.with_index(@panes) do %>
        <div class="pane-column" id={"pane-#{pane.title |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "-")}"}>
          <div class="pane-header">
            <span class="pane-header-title"><%= pane.title %></span>
            <%= if pane[:type_name] do %>
              <button class="pane-add-btn" phx-click="new-document" phx-value-type={pane.type_name}><.icon name="plus" size={14} /></button>
            <% end %>
          </div>
          <div class="pane-body">
            <%= for item <- pane.items do %>
              <%= case item.type do %>
                <% :divider -> %>
                  <div class="pane-divider"></div>
                <% :header -> %>
                  <div class="pane-section-header"><.icon name={item.icon} size={12} /> <%= item.title %></div>
                <% :doc -> %>
                  <div
                    id={"doc-#{item.id}"}
                    class={"pane-doc-item #{if item.id == pane[:selected], do: "selected"}"}
                    phx-click="select" phx-value-pane={idx} phx-value-id={item.id}
                  >
                    <div class="pane-doc-title">
                      <span class={"pane-doc-dot #{if item.is_draft, do: "draft", else: item.status}"}></span>
                      <%= item.title %>
                    </div>
                    <div class="pane-doc-id"><%= item.id %></div>
                  </div>
                <% _ -> %>
                  <div
                    id={"item-#{item.id}"}
                    class={"pane-item #{if item.id == pane[:selected], do: "selected"}"}
                    phx-click="select" phx-value-pane={idx} phx-value-id={item.id}
                  >
                    <span class="pane-item-icon"><.icon name={item.icon} size={16} /></span>
                    <span class="pane-item-label"><%= item.title %></span>
                    <span class="pane-item-chevron"><.icon name="chevron-right" size={14} /></span>
                  </div>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Editor -->
      <%= if @editor_doc do %>
        <div class="editor-panel">
          <div class="pane-header editor-header">
            <div style="display: flex; align-items: center; gap: 8px;">
              <span class={"badge badge-#{if @editor_is_draft, do: "draft", else: @editor_doc.status}"}>
                <%= if @editor_is_draft, do: "draft", else: @editor_doc.status %>
              </span>
              <span class="pane-header-title"><%= @editor_doc.title || "Untitled" %></span>
            </div>
            <div style="display: flex; gap: 6px;">
              <button class="btn btn-ghost btn-sm" phx-click="show-history">History</button>
              <%= if @editor_is_draft do %>
                <button class="btn btn-primary btn-sm" phx-click="publish">Publish</button>
              <% else %>
                <button class="btn btn-sm" phx-click="unpublish">Unpublish</button>
              <% end %>
            </div>
          </div>

          <div class="editor-body">
            <%= if @editor_schema do %>
              <div class="editor-meta">
                <.icon name={@editor_schema.icon} size={14} /> <%= @editor_schema.title %> &middot; <%= length(@editor_schema.fields) %> fields
              </div>
            <% end %>

            <form phx-submit="save" phx-change="autosave" id="editor-form">
              <div class="editor-field">
                <label class="editor-field-label">Title</label>
                <input type="text" name="doc[title]" value={@editor_form["title"]} class="form-input" phx-debounce="300" />
              </div>
              <%= if @editor_schema do %>
                <%= for field <- Enum.reject(@editor_schema.fields, & &1["name"] == "title") do %>
                  <div class="editor-field">
                    <label class="editor-field-label">
                      <%= field["title"] || field["name"] %>
                      <span class="editor-field-type"><%= field["type"] %></span>
                    </label>
                    <%= render_input(assigns, field) %>
                  </div>
                <% end %>
              <% end %>
              <div class="editor-actions">
                <span class="save-status"><%= @save_status %></span>
              </div>
            </form>
          </div>
        </div>
      <% else %>
        <div class="editor-empty">
          <div style="color: var(--fg-dim); text-align: center;">
            <div style="margin-bottom: 12px; opacity: 0.4;"><.icon name="file-text" size={40} /></div>
            <div class="text-sm">Select a document to edit</div>
          </div>
        </div>
      <% end %>

      <!-- Image picker modal (outside editor form to avoid nested forms) -->
      <%= if @image_picker_field do %>
        <div class="image-picker-overlay" phx-click="close-image-picker"></div>
        <div class="image-picker">
          <div class="image-picker-header">
            <span style="font-weight: 600; font-size: 14px;">Select Image</span>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="close-image-picker">x</button>
          </div>
          <div class="image-picker-upload">
            <form phx-change="validate-upload" phx-submit="upload-image" phx-value-field={@image_picker_field} id="upload-form">
              <.live_file_input upload={@uploads.image} class="image-file-input" />
              <%= for entry <- @uploads.image.entries do %>
                <div class="image-upload-entry">
                  <.live_img_preview entry={entry} width="60" height="60" />
                  <span class="text-sm"><%= entry.client_name %></span>
                  <button type="submit" class="btn btn-primary btn-sm">Upload</button>
                </div>
              <% end %>
            </form>
          </div>
          <div class="image-picker-grid">
            <%= if @media_files == [] do %>
              <div class="text-sm text-muted" style="padding: 16px; text-align: center;">No images yet. Upload one above.</div>
            <% end %>
            <%= for file <- @media_files do %>
              <div class="image-picker-item" phx-click="select-media" phx-value-url={"/media/files/#{file.path}"} phx-value-field={@image_picker_field}>
                <img src={"/media/files/#{file.path}"} alt={file.original_name} />
                <div class="image-picker-name"><%= file.original_name %></div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Reference picker modal -->
      <%= if @ref_picker_field do %>
        <div class="image-picker-overlay" phx-click="close-ref-picker"></div>
        <div class="image-picker">
          <div class="image-picker-header">
            <span style="font-weight: 600; font-size: 14px;">Select reference</span>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="close-ref-picker">x</button>
          </div>
          <div style="padding: 10px 16px; border-bottom: 1px solid var(--border-muted);">
            <input type="text" placeholder="Search..." class="form-input" phx-keyup="ref-search" phx-debounce="200" value={@ref_search} />
          </div>
          <div style="max-height: 400px; overflow-y: auto;">
            <%= for candidate <- filter_ref_candidates(@ref_candidates, @ref_search) do %>
              <div class="ref-candidate" phx-click="select-ref" phx-value-id={candidate.id} phx-value-field={@ref_picker_field}>
                <span class="ref-candidate-title"><%= candidate.title %></span>
                <span class="ref-candidate-id"><%= candidate.id %></span>
              </div>
            <% end %>
            <%= if filter_ref_candidates(@ref_candidates, @ref_search) == [] do %>
              <div class="text-sm text-muted" style="padding: 20px; text-align: center;">No documents found</div>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- History modal -->
      <%= if @show_history do %>
        <div class="image-picker-overlay" phx-click="close-history"></div>
        <div class="history-modal">
          <div class="image-picker-header">
            <span style="font-weight: 600; font-size: 14px;">Document history</span>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="close-history">x</button>
          </div>
          <div class="history-list">
            <%= if @revisions == [] do %>
              <div class="text-sm text-muted" style="padding: 24px; text-align: center;">No history yet</div>
            <% end %>
            <%= for rev <- @revisions do %>
              <div class="history-item">
                <div class="history-item-info">
                  <div class="history-item-action">
                    <span class={"history-action-badge history-action-#{rev.action}"}><%= rev.action %></span>
                    <span class="history-item-title"><%= rev.title || "Untitled" %></span>
                  </div>
                  <div class="history-item-time"><%= format_history_time(rev.inserted_at) %></div>
                </div>
                <button class="btn btn-sm" phx-click="restore-revision" phx-value-id={rev.id} data-confirm="Restore this version? Current changes will be overwritten.">Restore</button>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>

    <style>
      .pane-layout {
        display: flex; flex: 1; overflow: hidden;
      }
      .pane-column {
        width: 260px; min-width: 200px; flex-shrink: 0;
        border-right: 1px solid var(--border-muted);
        display: flex; flex-direction: column;
        background: var(--bg-card);
      }
      .pane-header {
        height: 42px; min-height: 42px;
        display: flex; align-items: center; justify-content: space-between;
        padding: 0 14px; border-bottom: 1px solid var(--border-muted);
      }
      .pane-header-title { font-size: 13px; font-weight: 600; }
      .pane-add-btn {
        width: 24px; height: 24px; border-radius: 6px; border: none;
        background: var(--primary); color: var(--primary-fg);
        font-size: 14px; font-weight: 700; cursor: pointer;
        display: flex; align-items: center; justify-content: center;
      }
      .pane-add-btn:hover { background: var(--primary-hover); }
      .pane-body { flex: 1; overflow-y: auto; }

      .pane-item {
        display: flex; align-items: center; gap: 10px;
        padding: 9px 14px; cursor: pointer;
        border-left: 3px solid transparent; color: var(--fg-muted);
        transition: all 0.1s; font-size: 13px;
      }
      .pane-item:hover { background: var(--bg-muted); color: var(--fg); }
      .pane-item.selected { background: var(--bg-accent); color: var(--fg); border-left-color: var(--primary); }
      .pane-item-icon { width: 18px; text-align: center; font-size: 15px; }
      .pane-item-label { flex: 1; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .pane-item-chevron { color: var(--fg-dim); font-size: 14px; }

      .pane-section-header {
        padding: 14px 14px 6px; font-size: 11px; font-weight: 600;
        color: var(--fg-dim); text-transform: uppercase; letter-spacing: 0.05em;
      }
      .pane-divider { border-top: 1px solid var(--border-muted); margin: 4px 0; }

      .pane-doc-item {
        padding: 10px 14px; cursor: pointer;
        border-left: 3px solid transparent; transition: all 0.1s;
      }
      .pane-doc-item:hover { background: var(--bg-muted); }
      .pane-doc-item.selected { background: var(--bg-accent); border-left-color: var(--primary); }
      .pane-doc-title { font-size: 13px; font-weight: 500; display: flex; align-items: center; gap: 8px; }
      .pane-doc-dot { width: 7px; height: 7px; border-radius: 50%; flex-shrink: 0; }
      .pane-doc-dot.published { background: var(--success); }
      .pane-doc-dot.draft { background: var(--warning); }
      .pane-doc-dot.active { background: var(--primary); }
      .pane-doc-dot.completed { background: var(--success); }
      .pane-doc-dot.planning { background: var(--fg-dim); }
      .pane-doc-id { font-size: 11px; color: var(--fg-dim); font-family: var(--font-mono); margin-top: 2px; margin-left: 15px; }

      /* Editor */
      .editor-panel { flex: 1; display: flex; flex-direction: column; background: var(--bg); overflow: hidden; }
      .editor-header { justify-content: space-between; background: var(--bg); }
      .editor-body { flex: 1; overflow-y: auto; padding: 20px 24px; max-width: 720px; }
      .editor-meta { font-size: 12px; color: var(--fg-dim); margin-bottom: 20px; }
      .editor-field { margin-bottom: 20px; }
      .editor-field-label {
        display: block; margin-bottom: 6px; font-size: 12px; font-weight: 600;
        color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.04em;
      }
      .editor-field-type { font-weight: 400; text-transform: none; letter-spacing: 0; color: var(--fg-dim); margin-left: 6px; font-size: 11px; }
      .editor-actions { padding-top: 16px; border-top: 1px solid var(--border-muted); display: flex; align-items: center; gap: 12px; }
      .save-status { font-size: 12px; color: var(--success); opacity: 0.8; transition: opacity 0.3s; }
      .editor-empty {
        flex: 1; display: flex; align-items: center; justify-content: center;
        background: var(--bg);
      }

      /* Image field */
      .image-field { position: relative; }
      .image-preview { position: relative; border-radius: var(--radius-sm); overflow: hidden; border: 1px solid var(--border-muted); }
      .image-preview img { width: 100%; max-height: 200px; object-fit: cover; display: block; }
      .image-preview-actions { display: flex; gap: 6px; padding: 8px; background: var(--bg-card); border-top: 1px solid var(--border-muted); }
      .image-upload-zone {
        display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 6px;
        padding: 24px; border: 2px dashed var(--border); border-radius: var(--radius-sm);
        cursor: pointer; color: var(--fg-muted); transition: all 0.15s;
      }
      .image-upload-zone:hover { border-color: var(--primary); color: var(--fg); background: hsl(217.2 91.2% 59.8% / 0.03); }
      .image-upload-icon { font-size: 24px; font-weight: 300; width: 36px; height: 36px; border-radius: 50%; border: 1px solid var(--border); display: flex; align-items: center; justify-content: center; }
      .image-upload-text { font-size: 13px; }
      .image-picker-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.5); z-index: 50; }
      .image-picker {
        position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%);
        width: 560px; max-height: 70vh; background: var(--bg-card); border: 1px solid var(--border);
        border-radius: var(--radius-lg); z-index: 51; display: flex; flex-direction: column; overflow: hidden;
      }
      .image-picker-header { display: flex; align-items: center; justify-content: space-between; padding: 14px 16px; border-bottom: 1px solid var(--border-muted); }
      .image-picker-upload { padding: 12px 16px; border-bottom: 1px solid var(--border-muted); }
      .image-file-input { font-size: 13px; color: var(--fg-muted); }
      .image-upload-entry { display: flex; align-items: center; gap: 10px; margin-top: 8px; }
      .image-upload-entry img { border-radius: 4px; object-fit: cover; }
      .image-picker-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; padding: 12px 16px; overflow-y: auto; }
      .image-picker-item { cursor: pointer; border: 2px solid transparent; border-radius: var(--radius-sm); overflow: hidden; transition: border-color 0.1s; }
      .image-picker-item:hover { border-color: var(--primary); }
      .image-picker-item img { width: 100%; height: 100px; object-fit: cover; display: block; }
      .image-picker-name { font-size: 11px; color: var(--fg-muted); padding: 4px 6px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

      /* Reference field */
      .ref-field { position: relative; }
      .ref-selected {
        display: flex; align-items: center; justify-content: space-between;
        padding: 10px 12px; border: 1px solid var(--border-muted);
        border-radius: var(--radius-sm); background: var(--bg-card);
      }
      .ref-selected-info { display: flex; flex-direction: column; gap: 2px; }
      .ref-selected-title { font-size: 14px; font-weight: 500; }
      .ref-selected-type { font-size: 11px; color: var(--fg-dim); }
      .ref-candidate {
        display: flex; align-items: center; justify-content: space-between;
        padding: 10px 16px; cursor: pointer; border-bottom: 1px solid var(--border-muted);
        transition: background 0.1s;
      }
      .ref-candidate:hover { background: var(--bg-muted); }
      .ref-candidate:last-child { border-bottom: none; }
      .ref-candidate-title { font-size: 14px; font-weight: 500; }
      .ref-candidate-id { font-size: 11px; color: var(--fg-dim); font-family: var(--font-mono); }

      /* History */
      .history-modal {
        position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%);
        width: 520px; max-height: 70vh; background: var(--bg-card); border: 1px solid var(--border);
        border-radius: var(--radius-lg); z-index: 51; display: flex; flex-direction: column; overflow: hidden;
      }
      .history-list { overflow-y: auto; flex: 1; }
      .history-item {
        display: flex; align-items: center; justify-content: space-between;
        padding: 12px 16px; border-bottom: 1px solid var(--border-muted);
      }
      .history-item:last-child { border-bottom: none; }
      .history-item-info { display: flex; flex-direction: column; gap: 4px; }
      .history-item-action { display: flex; align-items: center; gap: 8px; }
      .history-item-title { font-size: 13px; font-weight: 500; }
      .history-item-time { font-size: 11px; color: var(--fg-dim); }
      .history-action-badge {
        font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em;
        padding: 2px 6px; border-radius: 4px;
      }
      .history-action-create { background: hsl(217.2 91.2% 59.8% / 0.12); color: var(--primary); }
      .history-action-update { background: hsl(240 3.7% 15.9%); color: var(--fg-muted); }
      .history-action-publish { background: hsl(142 71% 45% / 0.12); color: var(--success); }
      .history-action-unpublish { background: hsl(38 92% 50% / 0.12); color: var(--warning); }
    </style>
    """
  end

  defp render_input(assigns, %{"type" => "select", "name" => name, "options" => opts}) when is_list(opts) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, opts: opts, v: val)
    ~H"""
    <select name={"doc[#{@n}]"} class="form-input" phx-debounce="300">
      <%= for o <- @opts do %><option value={o} selected={o == @v}><%= o %></option><% end %>
    </select>
    """
  end

  defp render_input(assigns, %{"type" => t, "name" => name} = f) when t in ["text", "richText"] do
    val = Map.get(assigns.editor_form, name, "")
    rows = Map.get(f, "rows") || if(t == "richText", do: 6, else: 3)
    assigns = assign(assigns, n: name, v: val, rows: rows)
    ~H"""
    <textarea name={"doc[#{@n}]"} class="form-input" rows={@rows} phx-debounce="500"><%= @v %></textarea>
    """
  end

  defp render_input(assigns, %{"type" => "boolean", "name" => name}) do
    checked = Map.get(assigns.editor_form, name, "") == "true"
    assigns = assign(assigns, n: name, c: checked)
    ~H"""
    <div class="form-checkbox">
      <input type="hidden" name={"doc[#{@n}]"} value="false" />
      <input type="checkbox" name={"doc[#{@n}]"} value="true" checked={@c} phx-debounce="100" />
    </div>
    """
  end

  defp render_input(assigns, %{"type" => "color", "name" => name}) do
    val = Map.get(assigns.editor_form, name, "#3b82f6")
    assigns = assign(assigns, n: name, v: val)
    ~H"""
    <div style="display:flex;align-items:center;gap:10px;">
      <input type="color" name={"doc[#{@n}]"} value={@v} phx-debounce="300" style="width:36px;height:36px;border:1px solid var(--input);border-radius:6px;cursor:pointer;background:transparent;" />
      <span style="font-family:var(--font-mono);font-size:13px;"><%= @v %></span>
    </div>
    """
  end

  defp render_input(assigns, %{"type" => "reference", "name" => name, "refType" => ref_type}) do
    val = Map.get(assigns.editor_form, name, "")
    has_ref = val != "" and val != nil
    # Resolve the referenced doc title for display
    ref_title = if has_ref do
      case Content.get_document(val, ref_type, "production") do
        {:ok, doc} -> doc.title || val
        _ ->
          case Content.get_document("drafts.#{val}", ref_type, "production") do
            {:ok, doc} -> doc.title || val
            _ -> val
          end
      end
    end
    assigns = assign(assigns, n: name, v: val, has_ref: has_ref, ref_title: ref_title, ref_type: ref_type)
    ~H"""
    <input type="hidden" name={"doc[#{@n}]"} value={@v} />
    <div class="ref-field">
      <%= if @has_ref do %>
        <div class="ref-selected">
          <div class="ref-selected-info">
            <span class="ref-selected-title"><%= @ref_title %></span>
            <span class="ref-selected-type"><%= @ref_type %></span>
          </div>
          <div style="display: flex; gap: 6px;">
            <button type="button" class="btn btn-sm" phx-click="open-ref-picker" phx-value-field={@n} phx-value-ref-type={@ref_type}>Change</button>
            <button type="button" class="btn btn-destructive btn-sm" phx-click="clear-ref" phx-value-field={@n}>Remove</button>
          </div>
        </div>
      <% else %>
        <button type="button" class="btn btn-sm" phx-click="open-ref-picker" phx-value-field={@n} phx-value-ref-type={@ref_type} style="width: 100%; justify-content: flex-start; color: var(--fg-muted);">
          Select <%= @ref_type %>...
        </button>
      <% end %>
    </div>
    """
  end

  defp render_input(assigns, %{"type" => "image", "name" => name}) do
    val = Map.get(assigns.editor_form, name, "")
    has_image = val != "" and val != nil
    assigns = assign(assigns, n: name, v: val, has_image: has_image)
    ~H"""
    <input type="hidden" name={"doc[#{@n}]"} value={@v} />
    <div class="image-field">
      <%= if @has_image do %>
        <div class="image-preview">
          <img src={@v} alt="" />
          <div class="image-preview-actions">
            <button type="button" class="btn btn-sm" phx-click="open-image-picker" phx-value-field={@n}>Change</button>
            <button type="button" class="btn btn-destructive btn-sm" phx-click="clear-image" phx-value-field={@n}>Remove</button>
          </div>
        </div>
      <% else %>
        <div class="image-upload-zone" phx-click="open-image-picker" phx-value-field={@n}>
          <div class="image-upload-icon">+</div>
          <div class="image-upload-text">Select or upload image</div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_input(assigns, %{"name" => name}) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val)
    ~H"""
    <input type="text" name={"doc[#{@n}]"} value={@v} class="form-input" phx-debounce="500" />
    """
  end

  defp format_history_time(dt) do
    Calendar.strftime(dt, "%b %d, %Y at %H:%M:%S")
  end
end
