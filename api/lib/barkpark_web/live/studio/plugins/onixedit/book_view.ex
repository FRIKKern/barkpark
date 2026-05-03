defmodule BarkparkWeb.Studio.Plugins.OnixEdit.BookView do
  @moduledoc """
  Phase 8 WI3 — read-only Studio view for `book` documents.

  Mounted at `/studio/:dataset/onixedit/book/:doc_id/view` and is the default
  click target from the Structure sidebar (per the redirect in
  `Studio.StudioLive.specialized_editor_redirect/1`). Companion to
  `Plugins.OnixEdit.BookEditor` (Phase 5 — full editor with autosave,
  publish, sign-off, Bokbasen status). BookView ships *view-only* and
  exposes an "Open in editor →" link to BookEditor for callers who need
  edit affordances.

  v1 schema field types render as plain values; v2 (composite / arrayOf /
  codelist / localizedText) render as collapsed pretty-JSON `<pre>` blocks
  per the masterplan v1 constraint (decision D12).
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Content

  @schema_name "book"

  @impl true
  def mount(%{"dataset" => dataset, "doc_id" => doc_id}, _session, socket) do
    pub_id = Content.published_id(doc_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{dataset}")
    end

    schema =
      case Content.get_schema(@schema_name, dataset) do
        {:ok, s} -> s
        _ -> nil
      end

    socket =
      socket
      |> assign(
        dataset: dataset,
        doc_id: pub_id,
        schema: schema,
        page_title: "Book — view"
      )
      |> load_document()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:document_changed, %{type: @schema_name, doc_id: changed_id}}, socket) do
    if Content.published_id(changed_id) == socket.assigns.doc_id do
      {:noreply, load_document(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_document(socket) do
    type = @schema_name
    pub_id = socket.assigns.doc_id
    dataset = socket.assigns.dataset

    draft_result = Content.get_document(Content.draft_id(pub_id), type, dataset)
    pub_result = Content.get_document(pub_id, type, dataset)

    {doc, is_draft} =
      case draft_result do
        {:ok, d} ->
          {d, true}

        _ ->
          case pub_result do
            {:ok, d} -> {d, false}
            _ -> {nil, false}
          end
      end

    assign(socket,
      doc: doc,
      is_draft: is_draft,
      has_published: match?({:ok, _}, pub_result)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="book-view-shell editor-panel" style="overflow-y:auto;padding:1rem;">
      <%= if @doc do %>
        <header class="book-view-header" style="margin-bottom:1rem;">
          <span class={"badge badge-" <> if(@is_draft, do: "draft", else: "published")}>
            <%= if @is_draft, do: "draft", else: "published" %>
          </span>
          <h1 style="margin:.25rem 0;"><%= @doc.title || "Untitled" %></h1>
          <div class="muted" style="font-size:.85rem;display:flex;gap:1rem;flex-wrap:wrap;">
            <span>_id: <%= @doc.doc_id %></span>
            <span>_type: book</span>
            <span>_createdAt: <%= @doc.inserted_at %></span>
            <span>_updatedAt: <%= @doc.updated_at %></span>
          </div>
          <div style="margin-top:.5rem;">
            <a class="btn btn-ghost btn-sm"
               href={"/studio/#{@dataset}/onixedit/book/#{Content.published_id(@doc.doc_id)}"}>
              Open in editor →
            </a>
          </div>
        </header>

        <section class="book-view-fields">
          <%= if @schema do %>
            <%= for field <- @schema.fields do %>
              <%= render_field(assigns, field) %>
            <% end %>
          <% else %>
            <div class="muted" style="margin-bottom:.5rem;">
              schema unavailable; raw content below
            </div>
            <pre class="json-dump"><%= Jason.encode!(@doc.content || %{}, pretty: true) %></pre>
          <% end %>
        </section>
      <% else %>
        <p class="muted">Book document not found.</p>
      <% end %>
    </div>
    """
  end

  # ── field renderers ─────────────────────────────────────────────────

  defp render_field(assigns, %{"type" => t} = field)
       when t in ["composite", "arrayOf", "localizedText"] do
    value = field_value(assigns.doc, field)
    json = Jason.encode!(value || empty_for(t), pretty: true)

    assigns =
      assign(assigns,
        field: field,
        json: json,
        item_count: count_items(value)
      )

    ~H"""
    <details class="field-block" style="margin-bottom:.5rem;border:1px solid #eee;padding:.5rem;">
      <summary>
        <strong><%= @field["title"] || @field["name"] %></strong>
        <span class="muted">(<%= @field["type"] %><%= if @item_count, do: ", #{@item_count} items" %>)</span>
      </summary>
      <pre class="json-dump" style="white-space:pre-wrap;"><%= @json %></pre>
    </details>
    """
  end

  defp render_field(assigns, %{"type" => "codelist"} = field) do
    code = field_value(assigns.doc, field)
    assigns = assign(assigns, field: field, code: code)

    ~H"""
    <div class="field-block" style="margin-bottom:.5rem;">
      <div class="field-label" style="font-weight:600;"><%= @field["title"] || @field["name"] %></div>
      <div class="field-value"><%= @code || "—" %></div>
    </div>
    """
  end

  defp render_field(assigns, field) do
    value = field_value(assigns.doc, field)
    assigns = assign(assigns, field: field, value: value)

    ~H"""
    <div class="field-block" style="margin-bottom:.5rem;">
      <div class="field-label" style="font-weight:600;"><%= @field["title"] || @field["name"] %></div>
      <div class="field-value"><%= format_v1(@value) %></div>
    </div>
    """
  end

  defp field_value(%{content: content}, %{"name" => name}) when is_map(content) do
    Map.get(content, name)
  end

  defp field_value(_, _), do: nil

  defp empty_for("arrayOf"), do: []
  defp empty_for(_), do: %{}

  defp count_items(value) when is_list(value), do: length(value)
  defp count_items(_), do: nil

  defp format_v1(nil), do: "—"
  defp format_v1(""), do: "—"
  defp format_v1(v) when is_binary(v), do: v
  defp format_v1(v) when is_boolean(v) or is_number(v), do: to_string(v)
  defp format_v1(v), do: inspect(v)
end
