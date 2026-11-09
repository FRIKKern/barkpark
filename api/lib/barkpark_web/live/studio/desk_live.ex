defmodule BarkparkWeb.Studio.DeskLive do
  @moduledoc """
  The desk slice: a read-only desk beside the Studio, built to prove the
  TanStack Studio's pane navigation in LiveView. Plan:
  `/papers/desk-vertical-slice`.

  The whole pane chain is one URL segment in the TanStack and Sanity format
  (`BarkparkWeb.Studio.Desk.Panes`), read against the same desk tree the
  Studio and `GET /v1/structure/:dataset` serve
  (`BarkparkWeb.Studio.Desk.Tree`):

      /w/:ws/p/:proj/d/:dataset/studio/_desk/post;post-01

  Every row is a real link that patches. There are no events: nothing here
  writes. Workspace admins only while it is a slice; anyone else lands on
  the Studio.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Content
  alias Barkpark.Content.TitleDerivation
  alias Barkpark.Structure
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.StructureCopy
  alias BarkparkWeb.Studio.StudioLive.Paths

  @page 100

  @impl true
  def mount(%{"dataset" => dataset}, _session, socket) do
    socket =
      socket
      |> assign_new(:scope_prefix, fn -> "" end)
      |> assign(dataset: dataset, page_title: gettext("Desk"), panes: [])

    if socket.assigns[:shares_admin?] do
      {:ok, socket}
    else
      {:ok,
       push_navigate(socket, to: Paths.studio_path(socket.assigns.scope_prefix, [], dataset))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    dataset = params["dataset"] || socket.assigns.dataset
    # The router hands the splat over as decoded path segments; a param value
    # with a slash in it (`inspect=sanity/structure/history`) spans several.
    splat = params |> Map.get("panes", []) |> Enum.join("/")
    scope = ScopeHelpers.scope_opts(socket)

    root =
      dataset
      |> Structure.build([defer_group_by: true] ++ scope)
      |> StructureCopy.localize()
      |> Tree.normalize()

    panes = Tree.parse(splat, root)
    ctx = %{dataset: dataset, scope: scope, root: root, nodes: Tree.index(root), panes: panes}
    ctx = Map.put(ctx, :base, Paths.studio_path(socket.assigns.scope_prefix, ["_desk"], dataset))

    views =
      panes
      |> Enum.with_index()
      |> Enum.map(fn {pane, i} -> view(pane, i, ctx) end)

    {:noreply, assign(socket, dataset: dataset, panes: views, page_title: page_title(views))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      .dk { flex: 1; min-height: 0; }
      .dk .dk-pane { width: 320px; min-width: 320px; flex-shrink: 0; }
      .dk .dk-doc { width: auto; flex: 1 0 600px; border-right: 0; }
      .dk a.pane-item { text-decoration: none; box-sizing: border-box; }
      .dk a.pane-item:hover { color: var(--fg); }
      .dk a.pane-item:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-note { padding: 16px; color: var(--fg-muted); font-size: var(--text-sm); }
      .dk .dk-fields { padding: 24px 32px; margin: 0; display: grid; gap: 20px; max-width: 72ch; }
      .dk .dk-fields dt { font-size: var(--text-xs); color: var(--fg-muted); margin-bottom: 4px; }
      .dk .dk-fields dd { margin: 0; font-size: var(--text-sm); white-space: pre-wrap; overflow-wrap: anywhere; }
      .dk .dk-close { color: var(--fg-muted); text-decoration: none; padding: 4px 8px; }
    </style>
    <div class="pane-layout dk" id="desk-panes" data-testid="panes" role="main">
      <section
        :for={pane <- @panes}
        id={"desk-pane-#{pane.index}"}
        class={["pane-column", "dk-pane", pane.kind == :doc && "dk-doc"]}
        data-pane-index={pane.index}
        data-pane-kind={pane.kind}
        aria-label={pane.title}
      >
        <div class="pane-header">
          <span class="pane-header-title">{pane.title}</span>
          <.link
            :if={pane.close}
            patch={pane.close}
            class="dk-close"
            aria-label={gettext("Close %{title}", title: pane.title)}
          >
            <span aria-hidden="true">×</span>
          </.link>
        </div>
        <div class="pane-body">
          <p :if={pane.note} class="dk-note">{pane.note}</p>
          <%= for row <- pane.rows do %>
            <div :if={row.kind == :divider} class="pane-divider"></div>
            <div :if={row.kind == :plain} class="pane-item">
              <span class="pane-item-label">{row.title}</span>
            </div>
            <.link
              :if={row.kind == :link}
              patch={row.href}
              class={["pane-item", row.selected && "selected"]}
              aria-current={row.selected && "true"}
              data-desk-row
            >
              <span class="pane-item-label">{row.title}</span>
              <span :if={row.chevron} class="pane-item-chevron" aria-hidden="true">›</span>
            </.link>
          <% end %>
          <dl :if={pane.fields != []} class="dk-fields">
            <div :for={field <- pane.fields}>
              <dt>{field.title}</dt>
              <dd>{field.value}</dd>
            </div>
          </dl>
        </div>
      </section>
    </div>
    """
  end

  # ── one pane's view ────────────────────────────────────────────────────────

  defp view(%{kind: :types}, i, ctx) do
    pane(i, :types, ctx.root.title || gettext("Content"), rows: node_rows(ctx.root, i, ctx))
  end

  defp view(%{kind: :menu, node: id}, i, ctx) do
    case ctx.nodes[id] do
      nil ->
        pane(i, :menu, id, note: gettext("This list is not on the desk."), close: close(i, ctx))

      node ->
        pane(i, :menu, node.pane_title || node.title || id,
          rows: node_rows(node, i, ctx),
          close: close(i, ctx)
        )
    end
  end

  defp view(%{kind: :list, type: type} = list, i, ctx) do
    node = list[:node] && ctx.nodes[list[:node]]
    title = (node && (node.pane_title || node.title)) || type

    case Content.resolve_schema(type, ctx.dataset, ctx.scope) do
      {:ok, schema} ->
        title = if node, do: title, else: schema.title || type
        {rows, note} = doc_rows(schema, node, i, ctx)
        pane(i, :list, title, rows: rows, note: note, close: close(i, ctx))

      _ ->
        note = gettext("There is no document type named “%{type}” here.", type: type)
        pane(i, :list, title, note: note, close: close(i, ctx))
    end
  end

  defp view(%{kind: :doc, id: id, type: type}, i, ctx) do
    with {:ok, schema} <- Content.resolve_schema(type, ctx.dataset, ctx.scope),
         {%{} = doc, draft?, _published?} <-
           Content.fetch_doc_with_draft(type, id, ctx.dataset, ctx.scope) do
      title = doc_title(doc, schema)
      status = if draft?, do: gettext("Draft"), else: gettext("Published")
      fields = [%{title: gettext("Status"), value: status} | fields(doc, schema)]
      pane(i, :doc, title, fields: fields, close: close(i, ctx))
    else
      _ ->
        note = gettext("No document “%{id}” of type “%{type}” was found.", id: id, type: type)
        pane(i, :doc, id, note: note, close: close(i, ctx))
    end
  end

  defp pane(index, kind, title, opts) do
    %{
      index: index,
      kind: kind,
      title: title,
      rows: Keyword.get(opts, :rows, []),
      fields: Keyword.get(opts, :fields, []),
      note: Keyword.get(opts, :note),
      close: Keyword.get(opts, :close)
    }
  end

  defp close(index, ctx), do: Panes.close_from(ctx.panes, index, ctx.base)

  # ── rows ───────────────────────────────────────────────────────────────────

  defp node_rows(node, i, ctx) do
    for item <- Tree.rows(node) do
      case {item.type, Tree.opens(item)} do
        {:divider, _} ->
          %{kind: :divider}

        {_, nil} ->
          %{kind: :plain, title: item.title || item.id}

        {_, next} ->
          link_row(item.title || item.id, next, i, ctx, next.kind != :doc)
      end
    end
  end

  defp doc_rows(schema, node, i, ctx) do
    opts =
      [
        perspective: :drafts,
        limit: @page,
        filter_map: Structure.parse_filter(node && node.filter),
        content_keys: [TitleDerivation.preview_title_field(schema) || "title"]
      ] ++ ctx.scope

    {docs, more?} = Content.list_documents_page(schema.name, ctx.dataset, opts)

    rows =
      for doc <- docs do
        next = %{kind: :doc, id: Content.published_id(doc.doc_id), type: schema.name}
        link_row(doc_title(doc, schema), next, i, ctx, false)
      end

    note =
      cond do
        rows == [] -> gettext("No documents here yet.")
        more? -> gettext("Showing the first %{count}.", count: @page)
        true -> nil
      end

    {rows, note}
  rescue
    # A desk filter the query layer refuses is this pane's to state.
    e in Barkpark.Content.InvalidFilterError -> {[], Exception.message(e)}
  end

  defp link_row(title, next, i, ctx, chevron) do
    %{
      kind: :link,
      title: title,
      href: Panes.open_after(ctx.panes, i, next, ctx.base),
      selected: selected?(Enum.at(ctx.panes, i + 1), next),
      chevron: chevron
    }
  end

  defp selected?(%{kind: :doc, id: id}, %{kind: :doc, id: id}), do: true
  defp selected?(%{kind: kind, node: node}, %{kind: kind, node: node}) when kind != :doc, do: true
  defp selected?(_open, _next), do: false

  # ── a document, read-only ──────────────────────────────────────────────────

  defp doc_title(doc, schema) do
    presence(doc.title) || TitleDerivation.preview_title(doc, schema) ||
      Content.published_id(doc.doc_id)
  end

  defp fields(doc, schema) do
    for %{"name" => name} = field <- schema.fields || [] do
      value = if name == "title", do: doc.title, else: (doc.content || %{})[name]
      %{title: field["title"] || name, value: show(value)}
    end
  end

  defp show(nil), do: "—"
  defp show(""), do: "—"
  defp show(value) when is_binary(value), do: value
  defp show(value) when is_number(value) or is_boolean(value), do: to_string(value)

  defp show(value) do
    json = Jason.encode!(value, pretty: true)
    if String.length(json) > 600, do: String.slice(json, 0, 600) <> " …", else: json
  end

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp presence(_value), do: nil

  defp page_title(views), do: views |> List.last() |> Map.fetch!(:title)
end
