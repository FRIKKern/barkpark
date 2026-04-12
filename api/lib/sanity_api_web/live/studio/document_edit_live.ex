defmodule SanityApiWeb.Studio.DocumentEditLive do
  use SanityApiWeb, :live_view

  alias SanityApi.Content

  @dataset "production"

  @impl true
  def mount(%{"type" => type, "doc_id" => doc_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SanityApi.PubSub, "documents:#{@dataset}")
    end

    schema = case Content.get_schema(type, @dataset) do
      {:ok, s} -> s
      _ -> nil
    end

    pub_id = Content.published_id(doc_id)
    socket =
      socket
      |> assign(type: type, doc_id: pub_id, schema: schema)
      |> load_document()

    {:ok, socket}
  end

  @impl true
  def handle_info({:document_changed, %{type: type, doc_id: changed_id}}, socket) do
    if type == socket.assigns.type && Content.published_id(changed_id) == socket.assigns.doc_id do
      {:noreply, load_document(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"doc" => params}, socket) do
    type = socket.assigns.type
    doc_id = socket.assigns.doc_id
    schema = socket.assigns.schema

    content =
      if schema do
        Enum.reduce(schema.fields, %{}, fn field, acc ->
          key = field["name"]
          val = Map.get(params, key, "")
          case key do
            k when k in ["title", "status"] -> acc
            _ -> if val != "", do: Map.put(acc, key, val), else: acc
          end
        end)
      else
        %{}
      end

    attrs = %{
      "doc_id" => Content.draft_id(doc_id),
      "title" => Map.get(params, "title", ""),
      "status" => Map.get(params, "status", "draft"),
      "content" => content
    }

    case Content.upsert_document(type, attrs, @dataset) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Changes saved") |> load_document()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to save")}
    end
  end

  def handle_event("publish", _params, socket) do
    case Content.publish_document(socket.assigns.doc_id, socket.assigns.type, @dataset) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Document published") |> load_document()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to publish")}
    end
  end

  def handle_event("unpublish", _params, socket) do
    case Content.unpublish_document(socket.assigns.doc_id, socket.assigns.type, @dataset) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Document unpublished") |> load_document()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to unpublish")}
    end
  end

  def handle_event("discard-draft", _params, socket) do
    case Content.discard_draft(socket.assigns.doc_id, socket.assigns.type, @dataset) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Draft discarded") |> load_document()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "No draft to discard")}
    end
  end

  defp load_document(socket) do
    type = socket.assigns.type
    doc_id = socket.assigns.doc_id
    schema = socket.assigns.schema
    draft_id = Content.draft_id(doc_id)
    pub_id = Content.published_id(doc_id)

    draft_result = Content.get_document(draft_id, type, @dataset)
    pub_result = Content.get_document(pub_id, type, @dataset)

    {doc, is_draft} =
      case draft_result do
        {:ok, d} -> {d, true}
        _ ->
          case pub_result do
            {:ok, d} -> {d, false}
            _ -> {nil, false}
          end
      end

    assign(socket,
      doc: doc,
      is_draft: is_draft,
      has_published: match?({:ok, _}, pub_result),
      form_data: doc_to_form(doc, schema),
      page_title: (doc && doc.title) || "New Document"
    )
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="main-header" style="margin: -24px -24px 24px; padding: 0 24px;">
      <div class="main-header-left">
        <a href={"/studio/#{@type}"} class="btn btn-ghost btn-sm">&larr;</a>
        <div>
          <h1 class="h2"><%= (@doc && @doc.title) || "New Document" %></h1>
          <div class="toolbar" style="gap: 6px; margin-top: 2px;">
            <span class="text-xs text-muted">
              <%= if @schema, do: "#{@schema.icon} #{@schema.title}", else: @type %>
            </span>
            <span class={"badge badge-#{if @is_draft, do: "draft", else: (@doc && @doc.status || "draft")}"}>
              <%= if @is_draft, do: "draft", else: (@doc && @doc.status || "draft") %>
            </span>
          </div>
        </div>
      </div>
      <div class="main-header-right">
        <%= if @is_draft do %>
          <button class="btn btn-primary btn-sm" phx-click="publish">Publish</button>
          <%= if @has_published do %>
            <button class="btn btn-ghost btn-sm" phx-click="discard-draft" data-confirm="Discard this draft?">Discard draft</button>
          <% end %>
        <% else %>
          <button class="btn btn-sm" phx-click="unpublish">Unpublish</button>
        <% end %>
      </div>
    </div>

    <div class="card" style="max-width: 720px;">
      <!-- Schema info bar (matches TUI header) -->
      <%= if @schema do %>
        <div class="card-header">
          <span class="text-sm text-muted">
            <%= @schema.icon %> <%= @schema.title %> &middot; <%= length(@schema.fields) %> fields
          </span>
          <span class="text-xs text-dim" style="font-family: var(--font-mono);">
            id: <%= @doc_id %>
          </span>
        </div>
      <% end %>

      <form phx-submit="save" style="padding: 24px;">
        <%= if @schema do %>
          <%= for field <- @schema.fields do %>
            <div class="form-group">
              <label class="form-label">
                <%= field["title"] || field["name"] %>
                <span class="text-xs text-dim" style="font-weight: 400; margin-left: 6px;"><%= field["type"] %></span>
              </label>
              <%= render_field_input(field, @form_data) %>
            </div>
          <% end %>
        <% else %>
          <div class="form-group">
            <label class="form-label">Title</label>
            <input type="text" name="doc[title]" value={@form_data["title"]} class="form-input" />
          </div>
        <% end %>

        <div style="display: flex; gap: 8px; padding-top: 16px; border-top: 1px solid var(--border-muted);">
          <button type="submit" class="btn btn-primary">Save changes</button>
          <a href={"/studio/#{@type}"} class="btn">Cancel</a>
        </div>
      </form>
    </div>
    """
  end

  defp render_field_input(%{"type" => "select", "name" => name, "options" => options}, form_data) when is_list(options) do
    current = Map.get(form_data, name, "")
    assigns = %{name: name, options: options, current: current}
    ~H"""
    <select name={"doc[#{@name}]"} class="form-input">
      <%= for opt <- @options do %>
        <option value={opt} selected={opt == @current}><%= opt %></option>
      <% end %>
    </select>
    """
  end

  defp render_field_input(%{"type" => type, "name" => name} = field, form_data) when type in ["text", "richText"] do
    val = Map.get(form_data, name, "")
    rows = Map.get(field, "rows") || if(type == "richText", do: 6, else: 3)
    assigns = %{name: name, val: val, rows: rows}
    ~H"""
    <textarea name={"doc[#{@name}]"} class="form-input" rows={@rows}><%= @val %></textarea>
    """
  end

  defp render_field_input(%{"type" => "boolean", "name" => name}, form_data) do
    checked = Map.get(form_data, name, "") == "true"
    assigns = %{name: name, checked: checked}
    ~H"""
    <div class="form-checkbox">
      <input type="hidden" name={"doc[#{@name}]"} value="false" />
      <input type="checkbox" name={"doc[#{@name}]"} value="true" checked={@checked} />
      <span class="text-sm text-muted">Enabled</span>
    </div>
    """
  end

  defp render_field_input(%{"type" => "color", "name" => name}, form_data) do
    val = Map.get(form_data, name, "#3b82f6")
    assigns = %{name: name, val: val}
    ~H"""
    <div style="display: flex; align-items: center; gap: 10px;">
      <input type="color" name={"doc[#{@name}]"} value={@val}
        style="width: 36px; height: 36px; border: 1px solid var(--input); border-radius: var(--radius-sm); cursor: pointer; background: transparent;" />
      <span class="text-sm" style="font-family: var(--font-mono);"><%= @val %></span>
    </div>
    """
  end

  defp render_field_input(%{"name" => name}, form_data) do
    val = Map.get(form_data, name, "")
    assigns = %{name: name, val: val}
    ~H"""
    <input type="text" name={"doc[#{@name}]"} value={@val} class="form-input" />
    """
  end
end
