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

    # Try draft first, then published
    draft_id = Content.draft_id(doc_id)
    pub_id = Content.published_id(doc_id)

    {doc, is_draft} =
      case Content.get_document(draft_id, type, @dataset) do
        {:ok, d} -> {d, true}
        _ ->
          case Content.get_document(pub_id, type, @dataset) do
            {:ok, d} -> {d, false}
            _ -> {nil, false}
          end
      end

    form_data = doc_to_form(doc, schema)

    socket =
      socket
      |> assign(
        type: type,
        doc_id: pub_id,
        schema: schema,
        doc: doc,
        is_draft: is_draft,
        has_published: Content.get_document(pub_id, type, @dataset) |> elem(0) == :ok,
        form_data: form_data,
        page_title: doc && doc.title || "New Document"
      )

    {:ok, socket}
  end

  @impl true
  def handle_info({:document_changed, %{type: type, doc_id: changed_id}}, socket) do
    pub_id = Content.published_id(changed_id)
    if type == socket.assigns.type && pub_id == socket.assigns.doc_id do
      # Reload the document
      {:noreply, reload_doc(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"doc" => params}, socket) do
    type = socket.assigns.type
    doc_id = socket.assigns.doc_id
    schema = socket.assigns.schema

    # Build content map from non-standard fields
    content =
      Enum.reduce(schema.fields, %{}, fn field, acc ->
        key = field["name"]
        val = Map.get(params, key, "")
        case key do
          k when k in ["title", "status"] -> acc
          _ -> if val != "", do: Map.put(acc, key, val), else: acc
        end
      end)

    attrs = %{
      "doc_id" => Content.draft_id(doc_id),
      "title" => Map.get(params, "title", ""),
      "status" => Map.get(params, "status", "draft"),
      "content" => content
    }

    case Content.upsert_document(type, attrs, @dataset) do
      {:ok, _doc} ->
        {:noreply, socket |> put_flash(:info, "Saved") |> reload_doc()}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save")}
    end
  end

  def handle_event("publish", _params, socket) do
    case Content.publish_document(socket.assigns.doc_id, socket.assigns.type, @dataset) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Published") |> reload_doc()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to publish")}
    end
  end

  def handle_event("unpublish", _params, socket) do
    case Content.unpublish_document(socket.assigns.doc_id, socket.assigns.type, @dataset) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Unpublished") |> reload_doc()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to unpublish")}
    end
  end

  def handle_event("discard-draft", _params, socket) do
    case Content.discard_draft(socket.assigns.doc_id, socket.assigns.type, @dataset) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Draft discarded") |> reload_doc()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "No draft to discard")}
    end
  end

  defp reload_doc(socket) do
    type = socket.assigns.type
    doc_id = socket.assigns.doc_id
    schema = socket.assigns.schema
    draft_id = Content.draft_id(doc_id)
    pub_id = Content.published_id(doc_id)

    {doc, is_draft} =
      case Content.get_document(draft_id, type, @dataset) do
        {:ok, d} -> {d, true}
        _ ->
          case Content.get_document(pub_id, type, @dataset) do
            {:ok, d} -> {d, false}
            _ -> {nil, false}
          end
      end

    has_published = case Content.get_document(pub_id, type, @dataset) do
      {:ok, _} -> true
      _ -> false
    end

    assign(socket,
      doc: doc,
      is_draft: is_draft,
      has_published: has_published,
      form_data: doc_to_form(doc, schema),
      page_title: doc && doc.title || "Document"
    )
  end

  defp doc_to_form(nil, _schema), do: %{}
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
    <div class="page-header">
      <div>
        <h1 class="page-title"><%= @doc && @doc.title || "New Document" %></h1>
        <p class="page-subtitle">
          <%= if @schema, do: "#{@schema.icon} #{@schema.title}", else: @type %>
          &middot;
          <.status_badge status={if @is_draft, do: "draft", else: (@doc && @doc.status || "draft")} />
        </p>
      </div>
      <div class="toolbar">
        <%= if @is_draft do %>
          <button class="btn btn-primary" phx-click="publish">Publish</button>
          <%= if @has_published do %>
            <button class="btn btn-sm" phx-click="discard-draft" data-confirm="Discard this draft?">Discard Draft</button>
          <% end %>
        <% else %>
          <button class="btn" phx-click="unpublish">Unpublish</button>
        <% end %>
        <a href={"/studio/#{@type}"} class="btn">Back to list</a>
      </div>
    </div>

    <div class="card">
      <form phx-submit="save">
        <%= if @schema do %>
          <%= for field <- @schema.fields do %>
            <div class="form-group">
              <label class="form-label"><%= field["title"] || field["name"] %></label>
              <%= render_field_input(field, @form_data) %>
            </div>
          <% end %>
        <% else %>
          <div class="form-group">
            <label class="form-label">Title</label>
            <input type="text" name="doc[title]" value={@form_data["title"]} class="form-input" />
          </div>
        <% end %>

        <div style="margin-top:24px;">
          <button type="submit" class="btn btn-primary">Save</button>
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

  defp render_field_input(%{"type" => "text", "name" => name}, form_data) do
    val = Map.get(form_data, name, "")
    assigns = %{name: name, val: val}
    ~H"""
    <textarea name={"doc[#{@name}]"} class="form-input" rows="3"><%= @val %></textarea>
    """
  end

  defp render_field_input(%{"type" => "richText", "name" => name}, form_data) do
    val = Map.get(form_data, name, "")
    assigns = %{name: name, val: val}
    ~H"""
    <textarea name={"doc[#{@name}]"} class="form-input" rows="6"><%= @val %></textarea>
    """
  end

  defp render_field_input(%{"type" => "boolean", "name" => name}, form_data) do
    checked = Map.get(form_data, name, "") == "true"
    assigns = %{name: name, checked: checked}
    ~H"""
    <div class="form-check">
      <input type="hidden" name={"doc[#{@name}]"} value="false" />
      <input type="checkbox" name={"doc[#{@name}]"} value="true" checked={@checked} />
    </div>
    """
  end

  defp render_field_input(%{"type" => "color", "name" => name}, form_data) do
    val = Map.get(form_data, name, "#3b82f6")
    assigns = %{name: name, val: val}
    ~H"""
    <div style="display:flex; gap:8px; align-items:center;">
      <input type="color" name={"doc[#{@name}]"} value={@val} style="width:40px;height:32px;border:none;cursor:pointer;" />
      <input type="text" name={"doc[#{@name}_hex]"} value={@val} class="form-input" style="width:120px;" disabled />
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
