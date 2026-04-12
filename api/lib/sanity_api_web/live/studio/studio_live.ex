defmodule SanityApiWeb.Studio.StudioLive do
  @moduledoc """
  Multi-pane studio interface — mirrors the TUI's pane drill-down.
  One LiveView manages the full pane chain: Structure → Type → Documents → Editor.
  """
  use SanityApiWeb, :live_view

  alias SanityApi.{Content, Structure}

  @dataset "production"

  # ── Mount ──────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SanityApi.PubSub, "documents:#{@dataset}")
    end

    {:ok, assign(socket, page_title: "Studio")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    path = Map.get(params, "path", [])
    socket = socket |> assign(nav_path: path) |> rebuild_panes()
    {:noreply, socket}
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:document_changed, _}, socket) do
    {:noreply, rebuild_panes(socket)}
  end

  @impl true
  def handle_event("select", %{"pane" => pane_idx_str, "id" => id}, socket) do
    pane_idx = String.to_integer(pane_idx_str)
    # Trim path to this pane and append the new selection
    new_path = Enum.take(socket.assigns.nav_path, pane_idx) ++ [id]
    {:noreply, push_patch(socket, to: "/studio/#{Enum.join(new_path, "/")}")}
  end

  def handle_event("new-document", %{"type" => type}, socket) do
    id = "#{type}-#{:rand.uniform(999_999)}"
    case Content.create_document(type, %{"doc_id" => id, "title" => "Untitled"}, @dataset) do
      {:ok, doc} ->
        pub_id = Content.published_id(doc.doc_id)
        new_path = find_type_path(socket.assigns.nav_path, type) ++ [pub_id]
        {:noreply, push_patch(socket, to: "/studio/#{Enum.join(new_path, "/")}")}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create")}
    end
  end

  def handle_event("save", %{"doc" => params}, socket) do
    case socket.assigns[:editor_doc] do
      nil -> {:noreply, socket}
      doc ->
        schema = socket.assigns[:editor_schema]
        content = if schema do
          Enum.reduce(schema.fields, %{}, fn field, acc ->
            key = field["name"]
            val = Map.get(params, key, "")
            if key in ["title", "status"], do: acc, else: (if val != "", do: Map.put(acc, key, val), else: acc)
          end)
        else
          %{}
        end

        attrs = %{
          "doc_id" => Content.draft_id(Content.published_id(doc.doc_id)),
          "title" => Map.get(params, "title", doc.title),
          "status" => Map.get(params, "status", doc.status),
          "content" => content
        }

        type = socket.assigns[:editor_type]
        case Content.upsert_document(type, attrs, @dataset) do
          {:ok, _} -> {:noreply, socket |> put_flash(:info, "Saved") |> rebuild_panes()}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to save")}
        end
    end
  end

  def handle_event("publish", _params, socket) do
    with doc when not is_nil(doc) <- socket.assigns[:editor_doc],
         type when not is_nil(type) <- socket.assigns[:editor_type],
         {:ok, _} <- Content.publish_document(Content.published_id(doc.doc_id), type, @dataset) do
      {:noreply, socket |> put_flash(:info, "Published") |> rebuild_panes()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to publish")}
    end
  end

  def handle_event("unpublish", _params, socket) do
    with doc when not is_nil(doc) <- socket.assigns[:editor_doc],
         type when not is_nil(type) <- socket.assigns[:editor_type],
         {:ok, _} <- Content.unpublish_document(Content.published_id(doc.doc_id), type, @dataset) do
      {:noreply, socket |> put_flash(:info, "Unpublished") |> rebuild_panes()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed")}
    end
  end

  # ── Pane builder (mirrors TUI's rebuildPanes) ─────────────────────────────

  defp rebuild_panes(socket) do
    path = socket.assigns.nav_path
    structure = Structure.build(@dataset)
    schemas = Content.list_schemas(@dataset)

    # Build pane chain by walking the path
    {panes, editor_state} = build_pane_chain(structure, schemas, path)

    assign(socket,
      panes: panes,
      editor_doc: editor_state[:doc],
      editor_schema: editor_state[:schema],
      editor_type: editor_state[:type],
      editor_is_draft: editor_state[:is_draft] || false,
      editor_has_published: editor_state[:has_published] || false,
      editor_form: editor_state[:form] || %{}
    )
  end

  defp build_pane_chain(structure, schemas, path) do
    # Pane 0: root structure list
    root_pane = %{
      id: "root",
      title: "Structure",
      items: Enum.map(structure.items, fn node ->
        case node.type do
          :divider -> %{type: :divider, id: node.id}
          :list -> %{type: :group, id: node.id, title: node.title, icon: node.icon, items: node.items}
          _ -> %{type: :item, id: node.type_name || node.id, title: node.title, icon: node.icon, has_child: true}
        end
      end),
      selected: Enum.at(path, 0)
    }

    panes = [root_pane]
    editor = %{}

    # Walk the path to build deeper panes
    {panes, editor} = walk_path(path, 0, schemas, panes, editor)
    {panes, editor}
  end

  defp walk_path([], _depth, _schemas, panes, editor), do: {panes, editor}
  defp walk_path([current | rest], depth, schemas, panes, editor) do
    # Find what `current` refers to
    schema = Enum.find(schemas, &(&1.name == current))

    if schema do
      # It's a document type — show document list pane
      docs = Content.list_documents(schema.name, @dataset, perspective: :drafts)
      doc_pane = %{
        id: schema.name,
        title: schema.title,
        icon: schema.icon,
        type_name: schema.name,
        items: Enum.map(docs, fn doc ->
          %{
            type: :doc,
            id: Content.published_id(doc.doc_id),
            title: doc.title || "Untitled",
            is_draft: Content.draft?(doc.doc_id),
            status: doc.status,
            has_child: true
          }
        end),
        selected: Enum.at(rest, 0)
      }

      panes = panes ++ [doc_pane]

      # If there's a next path segment, it's a doc_id — open editor
      case rest do
        [doc_id | _] ->
          {doc, is_draft, has_pub} = load_doc(schema.name, doc_id)
          editor = %{
            doc: doc,
            schema: schema,
            type: schema.name,
            is_draft: is_draft,
            has_published: has_pub,
            form: doc_to_form(doc, schema)
          }
          {panes, editor}

        [] ->
          {panes, editor}
      end
    else
      # Could be a settings group — check if it matches a private schema
      private_schema = Enum.find(schemas, &(&1.name == current && &1.visibility == "private"))
      if private_schema do
        # Singleton — open editor directly
        {doc, is_draft, has_pub} = load_doc(private_schema.name, private_schema.name)
        editor = %{
          doc: doc,
          schema: private_schema,
          type: private_schema.name,
          is_draft: is_draft,
          has_published: has_pub,
          form: doc_to_form(doc, private_schema)
        }
        {panes, editor}
      else
        {panes, editor}
      end
    end
  end

  defp load_doc(type, doc_id) do
    draft_id = Content.draft_id(doc_id)
    pub_id = Content.published_id(doc_id)
    draft_result = Content.get_document(draft_id, type, @dataset)
    pub_result = Content.get_document(pub_id, type, @dataset)

    {doc, is_draft} = case draft_result do
      {:ok, d} -> {d, true}
      _ -> case pub_result do
        {:ok, d} -> {d, false}
        _ -> {nil, false}
      end
    end

    {doc, is_draft, match?({:ok, _}, pub_result)}
  end

  defp doc_to_form(nil, _), do: %{}
  defp doc_to_form(doc, schema) do
    base = %{"title" => doc.title || "", "status" => doc.status || "draft"}
    if schema do
      Enum.reduce(schema.fields, base, fn field, acc ->
        key = field["name"]
        val = case key do
          k when k in ["title", "status"] -> Map.get(acc, key, "")
          _ -> get_in(doc.content || %{}, [key]) || ""
        end
        Map.put(acc, key, val)
      end)
    else
      base
    end
  end

  defp find_type_path(nav_path, type) do
    idx = Enum.find_index(nav_path, &(&1 == type))
    if idx, do: Enum.take(nav_path, idx + 1), else: [type]
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="pane-layout">
      <!-- Pane columns -->
      <%= for {pane, idx} <- Enum.with_index(@panes) do %>
        <div class={"pane-column #{if idx == length(@panes) - 1 && !@editor_doc, do: "pane-column-active"}"}>
          <div class="pane-header">
            <span class="pane-header-title"><%= pane.title %></span>
            <%= if pane[:type_name] do %>
              <button class="btn btn-primary btn-sm" style="height: 24px; padding: 0 8px; font-size: 11px;" phx-click="new-document" phx-value-type={pane.type_name}>+</button>
            <% end %>
          </div>
          <div class="pane-body">
            <%= for item <- pane.items do %>
              <%= render_pane_item(assigns, item, idx, pane[:selected]) %>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Editor panel -->
      <%= if @editor_doc do %>
        <div class="editor-panel">
          <div class="pane-header" style="justify-content: space-between;">
            <div style="display: flex; align-items: center; gap: 8px;">
              <span class={"badge badge-#{if @editor_is_draft, do: "draft", else: @editor_doc.status}"}>
                <%= if @editor_is_draft, do: "draft", else: @editor_doc.status %>
              </span>
              <span class="pane-header-title"><%= @editor_doc.title || "Untitled" %></span>
            </div>
            <div class="toolbar">
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
                <span><%= @editor_schema.icon %> <%= @editor_schema.title %></span>
                <span>&middot;</span>
                <span><%= length(@editor_schema.fields) %> fields</span>
              </div>
            <% end %>

            <form phx-submit="save">
              <%= if @editor_schema do %>
                <%= for field <- @editor_schema.fields do %>
                  <div class="editor-field">
                    <label class="editor-field-label">
                      <%= field["title"] || field["name"] %>
                      <span class="editor-field-type"><%= field["type"] %></span>
                    </label>
                    <%= render_field(assigns, field) %>
                  </div>
                <% end %>
              <% end %>
              <div class="editor-actions">
                <button type="submit" class="btn btn-primary btn-sm">Save</button>
              </div>
            </form>
          </div>
        </div>
      <% end %>
    </div>

    <style>
      .pane-layout {
        display: flex; height: calc(100vh - var(--header-h, 52px) - 48px);
        margin: -24px; overflow: hidden;
      }
      .pane-column {
        width: 260px; min-width: 260px; flex-shrink: 0;
        border-right: 1px solid var(--border-muted);
        display: flex; flex-direction: column;
        background: var(--bg-card);
      }
      .pane-column-active { background: var(--bg); }
      .pane-header {
        height: 44px; min-height: 44px;
        display: flex; align-items: center; justify-content: space-between;
        padding: 0 14px;
        border-bottom: 1px solid var(--border-muted);
        gap: 8px;
      }
      .pane-header-title { font-size: 13px; font-weight: 600; }
      .pane-body { flex: 1; overflow-y: auto; }

      .pane-item {
        display: flex; align-items: center; gap: 10px;
        padding: 8px 14px; cursor: pointer;
        border-left: 3px solid transparent;
        transition: all 0.1s;
        font-size: 13px; color: var(--fg-muted);
      }
      .pane-item:hover { background: var(--bg-muted); color: var(--fg); }
      .pane-item.selected { background: var(--bg-accent); color: var(--fg); border-left-color: var(--primary); }
      .pane-item-icon { width: 20px; text-align: center; font-size: 14px; }
      .pane-item-title { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 500; }
      .pane-item-chevron { color: var(--fg-dim); font-size: 12px; }
      .pane-item-subtitle { font-size: 11px; color: var(--fg-dim); }
      .pane-divider { border-top: 1px solid var(--border-muted); margin: 4px 14px; }

      .pane-doc-item {
        display: flex; flex-direction: column; gap: 2px;
        padding: 10px 14px; cursor: pointer;
        border-left: 3px solid transparent;
        transition: all 0.1s;
      }
      .pane-doc-item:hover { background: var(--bg-muted); }
      .pane-doc-item.selected { background: var(--bg-accent); border-left-color: var(--primary); }
      .pane-doc-title { font-size: 13px; font-weight: 500; display: flex; align-items: center; gap: 6px; }
      .pane-doc-status { width: 7px; height: 7px; border-radius: 50%; flex-shrink: 0; }
      .pane-doc-status.published { background: var(--success); }
      .pane-doc-status.draft { background: var(--warning); }
      .pane-doc-status.active { background: var(--primary); }

      /* Editor */
      .editor-panel {
        flex: 1; display: flex; flex-direction: column;
        overflow: hidden; background: var(--bg);
      }
      .editor-body { flex: 1; overflow-y: auto; padding: 20px 24px; }
      .editor-meta {
        display: flex; gap: 6px; align-items: center;
        font-size: 12px; color: var(--fg-dim); margin-bottom: 20px;
      }
      .editor-field { margin-bottom: 20px; }
      .editor-field-label {
        display: block; margin-bottom: 6px;
        font-size: 12px; font-weight: 600; color: var(--fg-muted);
        text-transform: uppercase; letter-spacing: 0.04em;
      }
      .editor-field-type {
        font-weight: 400; text-transform: none; letter-spacing: 0;
        color: var(--fg-dim); margin-left: 6px; font-size: 11px;
      }
      .editor-actions {
        padding-top: 16px; border-top: 1px solid var(--border-muted);
      }
    </style>
    """
  end

  defp render_pane_item(assigns, %{type: :divider}, _pane_idx, _selected) do
    ~H"""
    <div class="pane-divider"></div>
    """
  end

  defp render_pane_item(assigns, %{type: :group} = item, pane_idx, _selected) do
    assigns = assign(assigns, item: item, pane_idx: pane_idx)
    ~H"""
    <div style="padding: 10px 14px 4px; font-size: 11px; font-weight: 600; color: var(--fg-dim); text-transform: uppercase; letter-spacing: 0.05em;">
      <%= @item.icon %> <%= @item.title %>
    </div>
    <%= for child <- @item.items do %>
      <div
        class={"pane-item #{if child.type_name == @panes |> Enum.at(@pane_idx) |> Map.get(:selected), do: "selected"}"}
        phx-click="select"
        phx-value-pane={@pane_idx}
        phx-value-id={child.type_name || child.id}
      >
        <span class="pane-item-icon"><%= child.icon %></span>
        <span class="pane-item-title"><%= child.title %></span>
        <span class="pane-item-chevron">&#8250;</span>
      </div>
    <% end %>
    """
  end

  defp render_pane_item(assigns, %{type: :doc} = item, pane_idx, selected) do
    assigns = assign(assigns, item: item, pane_idx: pane_idx, is_selected: item.id == selected)
    ~H"""
    <div
      class={"pane-doc-item #{if @is_selected, do: "selected"}"}
      phx-click="select"
      phx-value-pane={@pane_idx}
      phx-value-id={@item.id}
    >
      <div class="pane-doc-title">
        <span class={"pane-doc-status #{if @item.is_draft, do: "draft", else: @item.status}"}></span>
        <%= @item.title %>
      </div>
      <div class="pane-item-subtitle"><%= @item.id %></div>
    </div>
    """
  end

  defp render_pane_item(assigns, %{type: :item} = item, pane_idx, selected) do
    assigns = assign(assigns, item: item, pane_idx: pane_idx, is_selected: item.id == selected)
    ~H"""
    <div
      class={"pane-item #{if @is_selected, do: "selected"}"}
      phx-click="select"
      phx-value-pane={@pane_idx}
      phx-value-id={@item.id}
    >
      <span class="pane-item-icon"><%= @item.icon %></span>
      <span class="pane-item-title"><%= @item.title %></span>
      <span class="pane-item-chevron">&#8250;</span>
    </div>
    """
  end

  defp render_pane_item(_, _, _, _), do: ""

  defp render_field(assigns, %{"type" => "select", "name" => name, "options" => options}) when is_list(options) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, name: name, options: options, val: val)
    ~H"""
    <select name={"doc[#{@name}]"} class="form-input">
      <%= for opt <- @options do %>
        <option value={opt} selected={opt == @val}><%= opt %></option>
      <% end %>
    </select>
    """
  end

  defp render_field(assigns, %{"type" => type, "name" => name} = field) when type in ["text", "richText"] do
    val = Map.get(assigns.editor_form, name, "")
    rows = Map.get(field, "rows") || if(type == "richText", do: 6, else: 3)
    assigns = assign(assigns, name: name, val: val, rows: rows)
    ~H"""
    <textarea name={"doc[#{@name}]"} class="form-input" rows={@rows}><%= @val %></textarea>
    """
  end

  defp render_field(assigns, %{"type" => "boolean", "name" => name}) do
    checked = Map.get(assigns.editor_form, name, "") == "true"
    assigns = assign(assigns, name: name, checked: checked)
    ~H"""
    <div class="form-checkbox">
      <input type="hidden" name={"doc[#{@name}]"} value="false" />
      <input type="checkbox" name={"doc[#{@name}]"} value="true" checked={@checked} />
    </div>
    """
  end

  defp render_field(assigns, %{"type" => "color", "name" => name}) do
    val = Map.get(assigns.editor_form, name, "#3b82f6")
    assigns = assign(assigns, name: name, val: val)
    ~H"""
    <div style="display: flex; align-items: center; gap: 10px;">
      <input type="color" name={"doc[#{@name}]"} value={@val}
        style="width: 36px; height: 36px; border: 1px solid var(--input); border-radius: var(--radius-sm); cursor: pointer; background: transparent;" />
      <span class="text-sm" style="font-family: var(--font-mono);"><%= @val %></span>
    </div>
    """
  end

  defp render_field(assigns, %{"name" => name}) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, name: name, val: val)
    ~H"""
    <input type="text" name={"doc[#{@name}]"} value={@val} class="form-input" />
    """
  end
end
