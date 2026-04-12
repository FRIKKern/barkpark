defmodule SanityApiWeb.Studio.StudioLive do
  @moduledoc """
  Multi-pane studio — mirrors the TUI's pane drill-down.
  Structure → Type → Documents → Editor
  """
  use SanityApiWeb, :live_view

  alias SanityApi.{Content, Structure}

  @dataset "production"

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
    {:noreply, socket |> assign(nav_path: path) |> rebuild_panes()}
  end

  @impl true
  def handle_info({:document_changed, _}, socket) do
    {:noreply, rebuild_panes(socket)}
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
        # Navigate to the new doc
        pub_id = Content.published_id(doc.doc_id)
        new_path = [type, pub_id]
        {:noreply, push_patch(socket, to: studio_path(new_path))}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create")}
    end
  end

  def handle_event("save", %{"doc" => params}, socket) do
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
        {:ok, _} -> {:noreply, socket |> put_flash(:info, "Saved") |> rebuild_panes()}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Save failed")}
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
    schemas = Content.list_schemas(@dataset)

    # Pane 0: Structure list
    root_items = build_root_items(structure)
    root_pane = %{title: "Structure", items: root_items, selected: Enum.at(path, 0)}
    panes = [root_pane]
    editor = nil

    # Walk path to build pane chain
    {panes, editor} = case path do
      [] ->
        {panes, nil}

      [type_name | rest] ->
        schema = Enum.find(schemas, &(&1.name == type_name))
        if schema do
          docs = Content.list_documents(schema.name, @dataset, perspective: :drafts)
          doc_pane = %{
            title: schema.title,
            icon: schema.icon,
            type_name: schema.name,
            items: Enum.map(docs, fn doc ->
              pub_id = Content.published_id(doc.doc_id)
              %{type: :doc, id: pub_id, title: doc.title || "Untitled",
                is_draft: Content.draft?(doc.doc_id), status: doc.status}
            end),
            selected: Enum.at(rest, 0)
          }

          editor = case rest do
            [doc_id | _] ->
              {doc, is_draft, has_pub} = fetch_doc(schema.name, doc_id)
              if doc do
                %{doc: doc, schema: schema, type: schema.name,
                  is_draft: is_draft, has_published: has_pub,
                  form: doc_to_form(doc, schema)}
              end
            _ -> nil
          end

          {panes ++ [doc_pane], editor}
        else
          {panes, nil}
        end
    end

    assign(socket,
      panes: panes,
      editor_doc: editor && editor[:doc],
      editor_schema: editor && editor[:schema],
      editor_type: editor && editor[:type],
      editor_is_draft: (editor && editor[:is_draft]) || false,
      editor_has_published: (editor && editor[:has_published]) || false,
      editor_form: (editor && editor[:form]) || %{}
    )
  end

  defp build_root_items(structure) do
    Enum.flat_map(structure.items, fn node ->
      case node.type do
        :divider -> [%{type: :divider, id: node.id}]
        :list ->
          # Settings group — render as header + children
          [%{type: :header, id: node.id, title: node.title, icon: node.icon}] ++
          Enum.map(node.items, fn child ->
            %{type: :item, id: child.type_name || child.id, title: child.title, icon: child.icon}
          end)
        _ ->
          [%{type: :item, id: node.type_name || node.id, title: node.title, icon: node.icon}]
      end
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
    <div class="pane-layout">
      <%= for {pane, idx} <- Enum.with_index(@panes) do %>
        <div class="pane-column">
          <div class="pane-header">
            <span class="pane-header-title"><%= pane.title %></span>
            <%= if pane[:type_name] do %>
              <button class="pane-add-btn" phx-click="new-document" phx-value-type={pane.type_name}><i data-lucide="plus" style="width:14px;height:14px;"></i></button>
            <% end %>
          </div>
          <div class="pane-body">
            <%= for item <- pane.items do %>
              <%= case item.type do %>
                <% :divider -> %>
                  <div class="pane-divider"></div>
                <% :header -> %>
                  <div class="pane-section-header"><i data-lucide={SanityApiWeb.Icons.icon_name(item.icon)} style="width:12px;height:12px;display:inline;"></i> <%= item.title %></div>
                <% :doc -> %>
                  <div
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
                    class={"pane-item #{if item.id == pane[:selected], do: "selected"}"}
                    phx-click="select" phx-value-pane={idx} phx-value-id={item.id}
                  >
                    <span class="pane-item-icon"><i data-lucide={SanityApiWeb.Icons.icon_name(item.icon)} style="width:16px;height:16px;"></i></span>
                    <span class="pane-item-label"><%= item.title %></span>
                    <span class="pane-item-chevron"><i data-lucide="chevron-right" style="width:14px;height:14px;"></i></span>
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
                <i data-lucide={SanityApiWeb.Icons.icon_name(@editor_schema.icon)} style="width:14px;height:14px;"></i> <%= @editor_schema.title %> &middot; <%= length(@editor_schema.fields) %> fields
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
                    <%= render_input(assigns, field) %>
                  </div>
                <% end %>
              <% end %>
              <div class="editor-actions">
                <button type="submit" class="btn btn-primary btn-sm">Save</button>
              </div>
            </form>
          </div>
        </div>
      <% else %>
        <div class="editor-empty">
          <div style="color: var(--fg-dim); text-align: center;">
            <div style="margin-bottom: 12px; opacity: 0.4;"><i data-lucide="file-text" style="width:40px;height:40px;"></i></div>
            <div class="text-sm">Select a document to edit</div>
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
      .editor-actions { padding-top: 16px; border-top: 1px solid var(--border-muted); }
      .editor-empty {
        flex: 1; display: flex; align-items: center; justify-content: center;
        background: var(--bg);
      }
    </style>
    """
  end

  defp render_input(assigns, %{"type" => "select", "name" => name, "options" => opts}) when is_list(opts) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, opts: opts, v: val)
    ~H"""
    <select name={"doc[#{@n}]"} class="form-input">
      <%= for o <- @opts do %><option value={o} selected={o == @v}><%= o %></option><% end %>
    </select>
    """
  end

  defp render_input(assigns, %{"type" => t, "name" => name} = f) when t in ["text", "richText"] do
    val = Map.get(assigns.editor_form, name, "")
    rows = Map.get(f, "rows") || if(t == "richText", do: 6, else: 3)
    assigns = assign(assigns, n: name, v: val, rows: rows)
    ~H"""
    <textarea name={"doc[#{@n}]"} class="form-input" rows={@rows}><%= @v %></textarea>
    """
  end

  defp render_input(assigns, %{"type" => "boolean", "name" => name}) do
    checked = Map.get(assigns.editor_form, name, "") == "true"
    assigns = assign(assigns, n: name, c: checked)
    ~H"""
    <div class="form-checkbox">
      <input type="hidden" name={"doc[#{@n}]"} value="false" />
      <input type="checkbox" name={"doc[#{@n}]"} value="true" checked={@c} />
    </div>
    """
  end

  defp render_input(assigns, %{"type" => "color", "name" => name}) do
    val = Map.get(assigns.editor_form, name, "#3b82f6")
    assigns = assign(assigns, n: name, v: val)
    ~H"""
    <div style="display:flex;align-items:center;gap:10px;">
      <input type="color" name={"doc[#{@n}]"} value={@v} style="width:36px;height:36px;border:1px solid var(--input);border-radius:6px;cursor:pointer;background:transparent;" />
      <span style="font-family:var(--font-mono);font-size:13px;"><%= @v %></span>
    </div>
    """
  end

  defp render_input(assigns, %{"name" => name}) do
    val = Map.get(assigns.editor_form, name, "")
    assigns = assign(assigns, n: name, v: val)
    ~H"""
    <input type="text" name={"doc[#{@n}]"} value={@v} class="form-input" />
    """
  end
end
