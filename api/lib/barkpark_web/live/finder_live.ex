defmodule BarkparkWeb.FinderLive do
  @moduledoc """
  The PUBLIC finder — the flagship search experience, Phoenix-native
  (search-template W3, the third framework leg).

  Where the Next edition runs the search loop in a client island and the Astro
  edition ships static files that call the API from the browser, THIS one is
  pure LiveView: the per-keystroke loop is a `phx-change` round-trip into the
  SAME engine the search channel serves (`Content.search_documents/3`), and the
  page arrives server-rendered. Zero client search code — the framework IS the
  live layer.

  The corpus graph rides the SAME zero-dependency Canvas2D renderer every other
  surface uses (`/assets/bp-graph.js`): the topology is derived server-side at
  mount (published perspective, same shape as `TasksController.graph_corpus/2`
  — the flat `/v1/graph` twin; a shared extraction is filed as backlog) and
  inlined as `data-*` attrs the `FinderGraph` hook (bulldocs layout) ingests.

  Tenancy: mounted FLAT on the public root, exactly like the flat `/papers`
  reader — reads resolve the Default workspace, published perspective only.
  That is threaded, not assumed: `mount/3` resolves
  `Tenancy.get_default_workspace()` once and every list read below carries its
  id, failing CLOSED (empty page) when no Default is seeded — the same posture
  `Content.get_public_document/3` takes on the by-id twin. See
  `BarkparkWeb.FinderWorkspaceScopeTest`.
  Hits link into the native PortableDoc reader (`/papers/<slug>`), which is the
  Phoenix PortableDoc mastery surface already in production.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext

  @default_dataset "production"
  @hit_limit 12
  # Same ceilings as TasksController.graph_corpus/2 — keeps the inline payload
  # bounded on huge datasets. Both config-overridable (tests), same keys as the
  # controller twin.
  @graph_node_budget 2000
  @graph_node_per_type_limit 1000

  @impl true
  def mount(params, _session, socket) do
    dataset = sanitize_dataset(params["dataset"])

    # THE PUBLIC TENANT, resolved ONCE (task-f9c30aa28c64f24a). This LiveView is
    # mounted FLAT on the public root — `pipe_through [:browser,
    # :paper_reader_csp]`, `live_session :finder` with no `on_mount`, no token,
    # no LiveScope — so NOTHING upstream resolves a tenant and there is no
    # `AssignDefaultScope`-populated conn to lift one off, which is why the flat
    # HTTP twin of the same derivation (`TasksController.derive_graph_corpus/2`,
    # built from `scope_opts(conn)`) carried a workspace and the hand-copied
    # LiveView version did not.
    #
    # The right answer for a PUBLIC surface is NOT "some member's workspace" and
    # NOT "whatever the caller asks for" — it is the same pinned public tenant
    # the by-id twin every hit links into already uses:
    # `Content.get_public_document/3` resolves `Tenancy.get_default_workspace()`
    # and fails CLOSED when there is none ("if no Default workspace is seeded
    # there is no public tenant"). This module's moduledoc already CLAIMED that
    # fence; the five list reads below just never carried it.
    #
    # `nil` is a real state (no seeded Default), and it is handled by rendering
    # an EMPTY page — never by omitting the key. Passing `workspace_id: nil`
    # would be strictly WORSE than today: `Content.resolve_read_dataset_id/2`
    # branches on the PRESENCE of the key, so a nil value drops the dataset_id
    # leg (the only thing fencing this surface today) AND
    # `scope_to_workspace_or_global/3` reads nil as the all-tenants global — no
    # fence of any kind on any of the five reads.
    workspace_id =
      case Barkpark.Tenancy.get_default_workspace() do
        %{id: id} when is_binary(id) -> id
        _ -> nil
      end

    # The corpus derivation walks every schema x up-to-1000 docs + edges — on a
    # loaded box that is SECONDS, and doing it inline here made the whole page
    # time out under a concurrent site build (live-caught). Mount renders the
    # shell instantly; start_async derives the corpus off-mount and the hook
    # ingests it when it lands. The static render (connected?: false) skips the
    # derivation entirely — crawlers and the first HTML paint stay instant.
    socket =
      socket
      |> assign(
        page_title: "Search — Barkpark",
        dataset: dataset,
        # The pinned public tenant every read below threads (or `nil` → empty
        # page). Assigned, not re-resolved per event: it cannot change within a
        # mount, and re-reading it on every keystroke is a DB round-trip per
        # debounce window.
        workspace_id: workspace_id,
        # `q`/`hits`/`hit_count` are seeded empty and then OWNED by
        # `handle_params/3`, which runs immediately after mount on both the dead
        # and the connected render. That is what makes `/finder?q=foo` a real
        # address (defect 1) — it renders its results server-side, so it is
        # bookmarkable, reloadable, back-button-restorable and crawlable.
        q: "",
        hits: [],
        hit_count: 0,
        # The graph's node total INCLUDES phantoms — dangling edge TARGETS with
        # no document row behind them. `data-rev` below wants that number (it is
        # the payload's change token); the human-readable line does NOT, which is
        # why the two are separate assigns (defect 3).
        node_count: 0,
        document_count: 0,
        graph_nodes: "[]",
        graph_edges: "[]",
        graph_root: "",
        graph_truncated: false,
        graph_truncation_reason: nil
      )

    # Who is asking — resolved BEFORE the async closure so the derivation runs
    # as the mounting principal, not as an ambient "server-side, therefore
    # privileged" reader. On this public route (`:browser` pipeline, no
    # on_mount auth) it resolves to `CallerContext.anonymous/0`, which the
    # shared clamp treats as the NARROWEST tier; if this LV ever mounts behind
    # auth, the assigned `:caller_context`/`:api_token` flows through here
    # unchanged — same threading as the search event below (D62).
    caller_context = CallerContext.from_conn(socket)

    socket =
      if connected?(socket) do
        start_async(socket, :graph_corpus, fn ->
          graph_payload(dataset, caller_context, workspace_id)
        end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(
        :graph_corpus,
        {:ok,
         {nodes_json, edges_json, root, node_count, document_count, truncated, truncation_reason}},
        socket
      ) do
    {:noreply,
     assign(socket,
       node_count: node_count,
       document_count: document_count,
       graph_nodes: nodes_json,
       graph_edges: edges_json,
       graph_root: root,
       graph_truncated: truncated,
       graph_truncation_reason: truncation_reason
     )}
  end

  def handle_async(:graph_corpus, {:exit, reason}, socket) do
    # Honest degrade: the search box works without the graph; log and keep the
    # empty canvas rather than crashing the view.
    require Logger
    Logger.warning("finder: graph corpus derivation failed: #{inspect(reason)}")
    {:noreply, socket}
  end

  # THE URL IS THE STATE (defect 1). `handle_params/3` runs after mount on the
  # dead render AND after every `push_patch`, so it is the ONE place the search
  # executes: a typed query, a reload, a pasted link and the back button all take
  # the same path and produce the same page. Before this, `q` was hard-set to ""
  # at mount with no `handle_params/3` anywhere in the module, so `/finder?q=foo`
  # rendered an empty finder.
  #
  # The search DOES run on the dead render, unlike the graph derivation above
  # which is deliberately skipped there: one bounded `search_documents/3` call is
  # what makes the URL addressable, whereas the corpus walk is seconds.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, run_search(socket, params["q"])}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    query = String.trim(to_string(q))

    # `replace: true`: the input is `phx-debounce="150"`, so a typed word emits
    # several events. Pushing history for each would make the back button walk
    # backwards one debounce-window at a time instead of leaving the finder.
    {:noreply, push_patch(socket, to: finder_path(socket.assigns.dataset, query), replace: true)}
  end

  defp finder_path(dataset, query) do
    params =
      []
      |> then(fn p -> if query == "", do: p, else: [{"q", query} | p] end)
      |> then(fn p ->
        if dataset == @default_dataset, do: p, else: [{"dataset", dataset} | p]
      end)

    case params do
      [] -> ~p"/finder"
      params -> ~p"/finder?#{params}"
    end
  end

  defp run_search(socket, raw) do
    case {String.trim(to_string(raw || "")), socket.assigns.workspace_id} do
      {"", _} ->
        assign(socket, q: "", hits: [], hit_count: 0)

      # FAIL CLOSED, exactly as `Content.get_public_document/3` does: with no
      # seeded Default workspace there is no public tenant, so there is nothing
      # this surface is entitled to search. Zero hits — never an unscoped read.
      {query, nil} ->
        assign(socket, q: query, hits: [], hit_count: 0)

      {query, workspace_id} ->
        # Thread the socket's REAL caller context (search-template W10 / D62)
        # so the retriever's schema-visibility gate sees who is asking instead
        # of a nil it must fail closed on. This finder mounts on the PUBLIC
        # `/finder` route (`:browser` pipeline, no on_mount auth), so today the
        # context resolves to `CallerContext.anonymous/0` and hits are
        # correctly narrowed to PUBLIC-visibility types — the same set the
        # query route serves a tokenless reader. Deliberately NOT a synthetic
        # authed context: that would hand private-type hits (session titles,
        # machine paths) to every anonymous visitor — the exact leak D62
        # seals. If this LV ever mounts behind auth, the assigned
        # `:caller_context`/`:api_token` flows through here unchanged.
        caller_context = CallerContext.from_conn(socket)

        # ENGINE PINNED TO POSTGRES, DELIBERATELY — and it must stay pinned in
        # the same breath as the `workspace_id:` below. This call used to ask
        # for `engine: "indx"` and never got it: `QueryPipeline`'s D3-b gate
        # substitutes the scoped Postgres retriever for any non-postgres engine
        # WITHOUT a binary `:workspace_id`, which is exactly what this call was.
        # So the requested engine was decorative and the served engine was
        # Postgres. Adding the workspace key LIFTS that gate — leaving `"indx"`
        # here would have flipped the public finder onto Indx as a silent side
        # effect of a tenancy fix, onto a candidate pool `Indx.Retriever`'s own
        # comment calls "NOT tenant-scoped" and that
        # `Content.get_documents_by_ids/3` hydrates with NO perspective filter.
        # Pinning `"postgres"` keeps the SERVED engine byte-identical to before
        # this fix; changing it is a separate decision with its own evidence.
        # See `BarkparkWeb.FinderWorkspaceScopeTest` "search engine".
        {docs, count, _meta} =
          Content.search_documents(query, socket.assigns.dataset,
            perspective: :published,
            limit: @hit_limit,
            engine: "postgres",
            workspace_id: workspace_id,
            caller_context: caller_context
          )

        assign(socket, q: query, hits: Enum.map(docs, &hit/1), hit_count: count)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="bp-finder">
      <div
        id="finder-graph"
        class="bp-finder-graph"
        phx-hook="FinderGraph"
        data-nodes={@graph_nodes}
        data-edges={@graph_edges}
        data-root={@graph_root}
        data-rev={@node_count}
        data-truncated={to_string(@graph_truncated)}
        data-truncation-reason={@graph_truncation_reason}
      >
      </div>
      <section class="bp-finder-panel">
        <p class="bp-finder-eyebrow">Search</p>
        <h1>Search everything.</h1>
        <form phx-change="search" phx-submit="search" autocomplete="off">
          <input
            type="search"
            name="q"
            value={@q}
            placeholder="Search everything…"
            phx-debounce="150"
            autofocus
            aria-label="Search"
            class="bp-finder-input"
          />
        </form>
        <ol :if={@hits != []} class="bp-finder-hits">
          <li :for={hit <- @hits}>
            <.link :if={hit.href} navigate={hit.href}>
              <strong>{hit.title}</strong>
              <span class="bp-finder-type">{hit.type}</span>
            </.link>
            <div :if={is_nil(hit.href)} class="bp-finder-hit-inert" data-test-id="finder-hit-inert">
              <strong>{hit.title}</strong>
              <span class="bp-finder-type">{hit.type}</span>
            </div>
          </li>
        </ol>
        <p class="bp-finder-count">
          {@document_count} documents · live search served by Phoenix · {if @q != "",
            do: hit_summary(@hit_count, length(@hits)),
            else: "type to search"}<span :if={@graph_truncated}> · graph truncated ({@graph_truncation_reason})</span>
        </p>
      </section>
    </main>
    <style>
      .bp-finder { position: relative; min-height: 100vh; overflow: hidden; }
      .bp-finder-graph { position: absolute; inset: 0; }
      .bp-finder-panel { position: relative; z-index: 1; max-width: 640px; margin: 0 auto; padding: 18vh 20px 0; text-align: center; pointer-events: none; }
      .bp-finder-panel form, .bp-finder-panel ol { pointer-events: auto; }
      .bp-finder-eyebrow { letter-spacing: .2em; text-transform: uppercase; font-size: 12px; opacity: .6; margin: 0; }
      .bp-finder-panel h1 { margin: 4px 0 20px; font-size: clamp(28px, 5vw, 44px); }
      .bp-finder-input { width: 100%; font: inherit; padding: 10px 14px; border: 1px solid rgba(128,128,128,.4); border-radius: 10px; background: transparent; color: inherit; }
      .bp-finder-hits { list-style: none; margin: 14px 0 0; padding: 0; text-align: left; }
      .bp-finder-hits li { padding: 8px 4px; border-bottom: 1px solid rgba(128,128,128,.18); }
      .bp-finder-hits a { color: inherit; text-decoration: none; display: flex; justify-content: space-between; gap: 12px; }
      .bp-finder-hits a:hover strong { text-decoration: underline; }
      .bp-finder-hit-inert { display: flex; justify-content: space-between; gap: 12px; opacity: .72; cursor: default; }
      .bp-finder-type { opacity: .5; font-size: .85em; }
      .bp-finder-count { margin-top: 16px; font-size: 12.5px; opacity: .55; }
    </style>
    """
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # The engine returns the FULL total while the page renders at most `@hit_limit`
  # rows and offers no pagination — so "437 hits" beside 12 rows read as a
  # rendering bug. Say which is which. Under the limit the wording is unchanged,
  # which is what the existing spec pins.
  defp hit_summary(total, shown) when total > shown, do: "showing #{shown} of #{total} hits"
  defp hit_summary(total, _shown), do: "#{total} hits"

  defp sanitize_dataset(raw) do
    case to_string(raw || "") do
      s when byte_size(s) > 0 ->
        if Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,62}\z/, s), do: s, else: @default_dataset

      _ ->
        @default_dataset
    end
  end

  defp hit(doc) do
    id = Content.published_id(doc.doc_id)

    %{title: doc.title || id, type: doc.type, href: public_href(doc.type, id)}
  end

  # `paper` is the ONLY type with a public reader — `live("/papers/:slug",
  # BulldocsLive)` in router.ex. (Cited by SYMBOL, not by line: the line anchor
  # this used to carry rotted the moment an unrelated pipeline gained a plug.)
  # Every other type used to resolve to
  # `~p"/finder"`: a link back to the page the reader is already standing on, so
  # a task/sheet/session hit rendered as a control that did nothing (defect 2).
  #
  # There is no public surface to send those types to, and inventing one is not
  # this row's job. So the honest answer is NO link: `nil` here, and the template
  # renders the row's title and type as plain text. A hit that cannot be opened
  # says so by not looking openable — strictly better than a click that reloads
  # the finder and looks like a bug.
  defp public_href("paper", id), do: ~p"/papers/#{id}"
  defp public_href(_type, _id), do: nil

  # The flat /v1/graph twin (TasksController.graph_corpus/2), derived at mount
  # and inlined for the hook — published perspective, real + phantom nodes,
  # budget-capped. Backlog: extract the shared derivation (filed at Decide).
  #
  # Truncation truth mirrors the controller (stw9-backlog-graph-server-honesty):
  # BOTH ceilings are detected (per_type_cap — a type's page at the cap with a
  # confirming COUNT — and node_budget), edges are re-filtered to the surviving
  # node set, and the {truncated, reason} pair rides the payload so /finder
  # never claims a complete corpus it didn't derive.
  # FAIL CLOSED with no public tenant — the empty payload the mount already
  # renders, so the page degrades to "no corpus" rather than to an unscoped
  # walk of every workspace on the box. Same posture as `run_search/2` above and
  # as `Content.get_public_document/3`.
  defp graph_payload(_dataset, _caller_context, nil), do: {"[]", "[]", "", 0, 0, false, nil}

  defp graph_payload(dataset, caller_context, workspace_id) do
    per_type_limit =
      Application.get_env(:barkpark, :graph_corpus_per_type_limit, @graph_node_per_type_limit)

    node_budget = Application.get_env(:barkpark, :graph_corpus_node_budget, @graph_node_budget)

    # `workspace_id` rides in `opts`, so it reaches ALL FOUR corpus reads at
    # once: `list_schemas/2`, `list_documents/3`, `count_documents/3` (which
    # derives `list_opts` from it) and `corpus_edges/3` (which forwards `opts`
    # into its own `list_documents/3`). This is the shape the flat `/v1/graph`
    # twin builds from `scope_opts(conn)`; the LiveView copy was written
    # `[dataset:, limit:]` and lost the tenant. It is only ever a BINARY here —
    # the nil clause above returns before this line.
    opts = [dataset: dataset, limit: per_type_limit, workspace_id: workspace_id]
    list_opts = Keyword.put(opts, :perspective, :published)

    # Schema visibility, keyed on the PRINCIPAL — `Content.Schema.
    # visible_schemas/2` is the ONE owner of this clamp, shared with the flat
    # `/v1/graph` twin (`TasksController.derive_graph_corpus/2`). This site
    # used to run the unclamped `list_schemas |> Enum.map(& &1.name)` line the
    # controller's clamp had replaced — a second hand-copied derivation, which
    # is exactly how an anonymous /finder visitor got every private type's
    # name and titles in the graph payload while the search clamp on the SAME
    # page held (task-336d22b7722ea71e). Never derive `types` here without it.
    types =
      dataset
      |> Content.list_schemas(opts)
      |> Barkpark.Content.Schema.visible_schemas(caller_context)
      |> Enum.map(& &1.name)

    {doc_lists, per_type_capped} =
      Enum.map_reduce(types, false, fn type, capped ->
        docs = Content.list_documents(type, dataset, list_opts)

        capped =
          capped or
            (length(docs) >= per_type_limit and
               Content.count_documents(type, dataset, list_opts) > per_type_limit)

        {docs, capped}
      end)

    real_nodes =
      doc_lists
      |> List.flatten()
      |> Enum.map(fn d ->
        pid = Content.published_id(d.doc_id)
        %{id: pid, doc_id: pid, type: d.type, title: d.title || pid, phantom: false}
      end)
      |> Enum.uniq_by(& &1.id)

    node_ids = MapSet.new(real_nodes, & &1.id)

    raw_edges =
      types
      |> Enum.flat_map(fn type -> Content.corpus_edges(type, dataset, opts) end)
      |> Enum.uniq_by(fn e -> {e.from_id, e.to_id, e.field} end)

    edges =
      Enum.map(raw_edges, fn e ->
        %{from_id: e.from_id, to_id: e.to_id, kind: e.kind || "references", weight: nil}
      end)

    phantom_nodes =
      raw_edges
      |> Enum.reject(fn e -> MapSet.member?(node_ids, e.to_id) end)
      |> Enum.map(& &1.to_id)
      |> Enum.uniq()
      |> Enum.map(fn tid -> %{id: tid, doc_id: tid, type: nil, title: tid, phantom: true} end)

    all_nodes = real_nodes ++ phantom_nodes
    over_budget = length(all_nodes) > node_budget
    nodes = if over_budget, do: Enum.take(all_nodes, node_budget), else: all_nodes

    # Only edges whose BOTH endpoints survived the budget (no-op under budget).
    kept_ids = MapSet.new(nodes, & &1.id)

    edges =
      Enum.filter(edges, fn e ->
        MapSet.member?(kept_ids, e.from_id) and MapSet.member?(kept_ids, e.to_id)
      end)

    root = List.first(real_nodes)[:id]

    truncated = per_type_capped or over_budget

    reason =
      case {per_type_capped, over_budget} do
        {true, true} -> "per_type_cap+node_budget"
        {true, false} -> "per_type_cap"
        {false, true} -> "node_budget"
        {false, false} -> nil
      end

    # THE COUNT SPLIT (defect 3). `nodes` is `real_nodes ++ phantom_nodes`, and a
    # phantom is a dangling edge TARGET — an id some document references that no
    # document row backs. Rendering `length(nodes)` as "N documents" counted
    # those, while the truncation notice beside it was scrupulously honest, so
    # the surface contradicted itself. `data-rev` still wants the node total (it
    # is the payload's change token); the human line wants the document total.
    document_count = Enum.count(nodes, &(not &1.phantom))

    {Jason.encode!(nodes), Jason.encode!(edges), root || "", length(nodes), document_count,
     truncated, reason}
  end
end
