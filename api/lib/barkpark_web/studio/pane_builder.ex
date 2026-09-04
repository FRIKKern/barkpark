defmodule BarkparkWeb.Studio.PaneBuilder do
  @moduledoc """
  Pane-tree builder for the multi-pane Studio LiveView.

  Pure data: no socket / no PubSub / no presence. Given a dataset and a
  navigation path, returns a list of pane maps + an optional editor map.
  StudioLive consumes this via a thin wrapper that mirrors the result
  into LV assigns.

  Extracted from `BarkparkWeb.Studio.StudioLive` in Task #11 WI3 — see
  `.doey/research/task11-wi3-IMPL-SPEC.md` section CODE_EXTRACTION_PLAN
  for the full rationale.
  """

  alias Barkpark.{Content, Structure}
  alias Barkpark.Content.Graph
  alias BarkparkWeb.Studio.StudioLive.Paths

  @doc """
  Build the full pane tree for `dataset` along `nav_path`. Returns
  `{panes, editor}` where `panes` is a list of pane maps and `editor`
  is either `nil` or a map describing the open document editor.

  Every pane map carries the ANATOMY keys (pane anatomy model, spd-s3):

    * `role:` — `:nav` for the root desk pane, `:list` for every drilled
      pane (`:list`, `:document_type_list`, `:plugin_document_list`).
      Content/inspector are NOT panes — the editor renders from its own
      map and never enters this list.
    * `priority:` — `0` on the root, its pane index on intermediates, and
      `:active` on the pane the nav path terminates in (the drilled-to
      leaf — a document list, or a `:list` group opened as the last
      segment). The responsive desk protects `:active` first when space
      starves.

  Both are DERIVED display metadata: never stored on `Structure.Node`,
  never serialized on the `/v1/structure` wire (the Go TUI drops unknown
  subtrees; the wire contract is pinned by structure_controller_test).

  Optional `opts`:

    * `:desk` — name of the active desk-group filter on a
      `:document_type_list` pane (read from `?desk=…` URL param by
      StudioLive). Looked up in the schema's `desk_groups` array. If
      the schema declares none (or the named group is absent), the
      pane renders unfiltered — back-compat with v1 schemas.

    * `:scope` — the tenancy `[workspace_id: …, project_id: …]` keyword
      (from `BarkparkWeb.ScopeHelpers.scope_opts(socket)`) threaded into
      EVERY document read so the desk shows ONLY the active
      workspace/project's content. Empty `[]` is nil-safe — the
      `Barkpark.Content` query path no-ops on an absent scope, so the desk
      keeps its pre-tenancy shape on an unscoped mount.

    * `:scope_prefix` — the `/w/:ws/p/:proj` URL prefix (or `""` on a flat
      surface). Threaded into `list_items/2` so plugin `:plugin_link` hrefs
      are canonicalised to the `/d/` shape at SOURCE (via
      `Paths.plugin_link_href/2`), instead of being rewritten later at
      render time. Absent → `""` → the legacy flat hrefs, unchanged.
  """
  @spec build(String.t(), [String.t()]) :: {[map()], map() | nil}
  def build(dataset, nav_path), do: build(dataset, nav_path, [])

  @spec build(String.t(), [String.t()], keyword()) :: {[map()], map() | nil}
  def build(dataset, nav_path, opts) do
    # The DISPLAYED desk is the default-gated tree (charter Decisions 1/3): a
    # disabled plugin's tree and top-menu Media are absent, so panes[0] tells
    # the enablement truth. `gated` renders the root pane in EVERY case.
    gated = Structure.build(dataset, scope(opts))

    # Resolution walks gated-first. A raw nav_path whose head no longer sits at
    # the gated root (a stale pre-tiering deep link — e.g. the router's legacy
    # `/studio/:ds/book/:id` → ["book", id], now nested under the Plugins node)
    # is normalized to the node's nested ancestor path so the walk drills the
    # Plugins/…Rest column and reveals it (URL unchanged). A type absent from
    # the gated display entirely (top-menu mediaAsset, a disabled plugin's
    # bookmark) falls back to the ungated `gating: :none` tree so its panes /
    # editor still open — the #1851 never-unreachable guarantee.
    {tree, segments} = resolve(nav_path, gated, dataset, opts)

    root_pane = %{
      title: gated.title,
      role: :nav,
      priority: 0,
      items: list_items(gated, scope_prefix(opts)),
      selected: Enum.at(segments, 0)
    }

    {panes, editor} = walk_path(segments, 0, tree, [root_pane], nil, dataset, opts)

    # Every pane carries the NORMALIZED segments that address it (`:path`), so a
    # row click in pane `i` can build `pane.path ++ [id]` instead of slicing the
    # raw URL by the pane's rendered index. The two diverge exactly when
    # `resolve/4` normalized a demoted type into its group: the pane stack is
    # then one longer than the URL, and `Enum.take(nav_path, i) ++ [id]` kept
    # the OLD doc id and appended the new one (Gyldendal field report #35b:
    # `/studio/publication/pub-a` → click → `/studio/publication/pub-a/pub-b`).
    # Pane `i` is addressed by the first `i` segments: the root pane by none,
    # the pane opened by consuming segment 0 by one, and so on.
    panes =
      panes
      |> Enum.with_index()
      |> Enum.map(fn {pane, i} -> Map.put(pane, :path, Enum.take(segments, i)) end)

    {panes, editor}
  end

  # Pick the tree to walk and the (possibly normalized) segments to walk it
  # with. Returns `{tree, segments}` — `tree` is the gated desk unless a type
  # absent from it forces the ungated fallback; `segments` is the raw nav_path
  # unless a demoted-but-present type is normalized to its nested ancestor path.
  @spec resolve([String.t()], map(), String.t(), keyword()) :: {map(), [String.t()]}
  defp resolve([], gated, _dataset, _opts), do: {gated, []}

  # RESERVED heads — `walk_path` resolves these WITHOUT any structure lookup
  # (per-doc graph blast-radius; direct type+id open from backlinks). They must
  # never be normalized or diverted to the ungated tree.
  defp resolve(["graph" | _] = nav_path, gated, _dataset, _opts), do: {gated, nav_path}
  defp resolve(["open" | _] = nav_path, gated, _dataset, _opts), do: {gated, nav_path}

  defp resolve([head | tail] = nav_path, gated, dataset, opts) do
    cond do
      root_has_segment?(gated, head) ->
        # Head still names a gated root item — walk the gated tree as-is.
        {gated, nav_path}

      true ->
        case find_type_node(gated.items || [], head, []) do
          # Demoted-but-present: the type lives deeper in the gated tree
          # (under Plugins / …Rest). Normalize to its nested ancestor path.
          {node_path, %{type: :document}} ->
            # Singletons resolve by type name — the stale doc-id tail is dropped.
            {gated, node_path}

          {node_path, _node} ->
            {gated, node_path ++ tail}

          # Absent from the gated display — resolve against the ungated tree so
          # the panes / editor still open (top-menu Media, a disabled plugin).
          nil ->
            {Structure.build(dataset, [gating: :none] ++ scope(opts)), nav_path}
        end
    end
  end

  # True when `seg` names a direct child of the (gated) root — by node id or by
  # the document type it lists. Mirrors `walk_path/7`'s `[id | rest]` match so
  # "still resolves at the root" means exactly "the walk would find it there".
  defp root_has_segment?(node, seg) do
    Enum.any?(node.items || [], fn n -> n.id == seg || n.type_name == seg end)
  end

  @doc """
  Recursively walk `path` against `current_node`'s children, building a
  pane at each depth. Mirrors the TUI's `rebuildPanes()` loop. Returns
  `{panes, editor_or_nil}`.
  """
  @spec walk_path([String.t()], non_neg_integer(), map(), [map()], map() | nil, String.t()) ::
          {[map()], map() | nil}
  def walk_path(path, depth, current, panes, editor, dataset),
    do: walk_path(path, depth, current, panes, editor, dataset, [])

  @spec walk_path(
          [String.t()],
          non_neg_integer(),
          map(),
          [map()],
          map() | nil,
          String.t(),
          keyword()
        ) :: {[map()], map() | nil}
  def walk_path([], _depth, _current, panes, editor, _dataset, _opts), do: {panes, editor}

  # RESERVED literal `"graph"` segment — the per-doc blast-radius action (Goal
  # ges/graph-edge-seam, FIX 2). The graph pane roots on ANY content doc, so it
  # is NOT a schema/structure node: a `graph/<doc_id>` nav path opens the
  # Canvas2D `view: :graph` editor for `<doc_id>` regardless of its type. This
  # clause runs BEFORE the structure `Enum.find` below — which would otherwise
  # return nil (no node has `type_name == "graph"`) and drop the pane to nil,
  # leaving the whole GraphView half of Phase 5 unreachable. The 'View blast
  # radius' affordance on the document editor push_patches to this path.
  def walk_path(["graph" | rest], _depth, _current, panes, _editor, dataset, opts) do
    editor =
      case rest do
        [doc_id | _] ->
          case resolve_graph_doc(doc_id, dataset, scope(opts)) do
            nil ->
              nil

            doc ->
              %{
                view: :graph,
                doc: doc,
                schema: nil,
                type: graph_doc_type(doc),
                is_draft: Content.draft?(doc.doc_id),
                has_published: not Content.draft?(doc.doc_id),
                form: %{},
                graph: graph_payload(doc, dataset, scope(opts))
              }
          end

        _ ->
          nil
      end

    {panes, editor}
  end

  # RESERVED literal "open" segment — direct doc-open by [type, doc_id], used by
  # the Studio backlinks panel to jump to a referencer that may live OUTSIDE the
  # currently-navigated structure subtree. Like "graph", it runs BEFORE the
  # structure Enum.find below (no node has type_name == "open"), resolves the doc
  # by id+type with NO structure lookup, and emits the same editor map a desk
  # row-click would. rebuild_panes then dispatches on editor[:view].
  def walk_path(["open", type, id | _], _depth, _current, panes, _editor, dataset, opts) do
    editor =
      if Content.blocks_type?(type) do
        # Same draft-first fix as `build_editor`'s blocks branch (spd-w17 D220).
        # A backlink to a never-published paper is the SAME silent blank screen,
        # reached by a different door — fixing only one leaves the other.
        case Content.fetch_doc_with_draft(type, id, dataset, scope(opts)) do
          {nil, _is_draft, _has_pub} ->
            nil

          {paper_doc, is_draft, has_pub} ->
            %{
              view: :paper,
              doc: paper_doc,
              schema: nil,
              type: type,
              is_draft: is_draft,
              has_published: has_pub,
              form: %{}
            }
        end
      else
        case Content.fetch_doc_with_draft(type, id, dataset, scope(opts)) do
          {doc, is_draft, has_pub} when not is_nil(doc) ->
            schema =
              case Content.resolve_schema(type, dataset, scope(opts)) do
                {:ok, s} -> s
                _ -> nil
              end

            %{
              doc: doc,
              schema: schema,
              type: type,
              is_draft: is_draft,
              has_published: has_pub,
              form: (schema && Content.doc_to_form(doc, schema)) || %{}
            }

          _ ->
            nil
        end
      end

    {panes, editor}
  end

  def walk_path([id | rest], depth, current, panes, _editor, dataset, opts) do
    found =
      Enum.find(current.items, fn node ->
        node.id == id || node.type_name == id
      end)

    case found do
      nil ->
        {panes, nil}

      %{type: :list} = node ->
        list_pane = %{
          title: node.title,
          role: :list,
          priority: if(rest == [], do: :active, else: depth + 1),
          items: list_items(node, scope_prefix(opts)),
          selected: Enum.at(rest, 0)
        }

        walk_path(rest, depth + 1, node, panes ++ [list_pane], nil, dataset, opts)

      # Plugin-contributed pre-filtered document list. Same rendering as
      # `:document_type_list` but the filter map is carried verbatim on
      # `node.filter` (a map, not a "field=value" string) so PaneBuilder
      # bypasses `Structure.parse_filter/1`.
      %{type: :plugin_document_list, type_name: type_name} = node ->
        schema =
          case Content.resolve_schema(type_name, dataset, scope(opts)) do
            {:ok, s} -> s
            _ -> nil
          end

        plugin_filter = if is_map(node.filter), do: node.filter, else: %{}
        list_opts = [perspective: :drafts, filter_map: plugin_filter] ++ scope(opts)
        {docs, filter_error} = list_documents_preflighted(type_name, dataset, list_opts)

        doc_pane = %{
          title: node.title || (schema && schema.title) || type_name,
          icon: node.icon || (schema && schema.icon),
          type_name: type_name,
          role: :list,
          priority: :active,
          desk_groups: [],
          active_desk: nil,
          filter_error: filter_error,
          items: doc_items(docs, schema),
          selected: Enum.at(rest, 0)
        }

        editor = build_editor(type_name, schema, rest, dataset, opts, nil)

        {panes ++ [doc_pane], editor}

      # Plugin-contributed link row — terminal node, no pane to add.
      # Returning the unchanged pane stack keeps the parent list pane visible
      # with this link as its selection.
      #
      # This comment used to say "the LV inspects `nav_path` and turns this
      # into outbound navigation via `push_navigate`". It does not, and never
      # did: no arm of StudioLive reads `nav_path` for a `:plugin_link`, the
      # rows are plain `<a href>` anchors the BROWSER follows, and mounting
      # such a path directly issues no redirect at all
      # (`studio_plugin_link_empty_state_test.exs` drives `assert_redirect/2`
      # to "but got none"). So the render this branch produces is not an
      # intermediate frame that a navigate is about to replace — it is the
      # page, for as long as the URL stands. That is why
      # `Shared.empty_editor_state/2` must suppress the unresolved-document
      # notice for this shape rather than tolerate it as a one-frame flash
      # (task-554a33ca42c0c45a).
      %{type: :plugin_link} ->
        {panes, nil}

      %{type: :document_type_list, type_name: type_name} = node ->
        schema =
          case Content.resolve_schema(type_name, dataset, scope(opts)) do
            {:ok, s} -> s
            _ -> nil
          end

        desk_groups = schema_desk_groups(schema)
        active_desk = Keyword.get(opts, :desk)
        active_group = find_desk_group(desk_groups, active_desk)

        list_opts = [perspective: :drafts] ++ scope(opts)

        list_opts =
          if node.filter,
            do: list_opts ++ [filter_map: Structure.parse_filter(node.filter)],
            else: list_opts

        list_opts =
          if active_group,
            do:
              Keyword.update(
                list_opts,
                :filter_map,
                desk_filter_map(active_group),
                &Map.merge(&1, desk_filter_map(active_group))
              ),
            else: list_opts

        {docs, filter_error} = list_documents_preflighted(type_name, dataset, list_opts)

        doc_pane = %{
          title: node.title || (schema && schema.title) || type_name,
          icon: node.icon || (schema && schema.icon),
          type_name: type_name,
          role: :list,
          priority: :active,
          desk_groups: desk_groups,
          active_desk: active_group && Map.get(active_group, "name"),
          filter_error: filter_error,
          items: doc_items(docs, schema),
          selected: Enum.at(rest, 0)
        }

        editor = build_editor(type_name, schema, rest, dataset, opts, active_group)

        {panes ++ [doc_pane], editor}

      %{type: :document, type_name: type_name} ->
        schema =
          case Content.resolve_schema(type_name, dataset, scope(opts)) do
            {:ok, s} -> s
            _ -> nil
          end

        if schema do
          {doc, is_draft, has_pub} =
            Content.fetch_doc_with_draft(type_name, type_name, dataset, scope(opts))

          editor =
            if doc do
              %{
                doc: doc,
                schema: schema,
                type: type_name,
                is_draft: is_draft,
                has_published: has_pub,
                form: Content.doc_to_form(doc, schema)
              }
            end

          {panes, editor}
        else
          {panes, nil}
        end

      _ ->
        {panes, nil}
    end
  end

  # ── Editor dispatch ────────────────────────────────────────────────────────
  #
  # ONE dispatch table shared by BOTH document-list branches
  # (`:document_type_list` and `:plugin_document_list`), so a
  # plugin-contributed list over a special type opens the same editor a host
  # desk row does:
  #
  #   * papers open LIVE inside the Studio editor pane (a streaming block
  #     view, `view: :paper`) — NOT the field form and NOT a link out to
  #     `/papers/:slug`;
  #   * sheets open the collaborative grid (`view: :sheet`, Sheets M2);
  #   * `graph` docs open the blast-radius Canvas2D pane (`view: :graph`,
  #     Goal ges/graph-edge-seam Phase 5) with the traversed node/edge
  #     payload via Content.Graph.traverse/2;
  #   * a mediaAsset list with NO doc selected opens the asset explorer
  #     (`view: :media_explorer`), kind-filtered by the active desk chip;
  #   * everything else resolves draft-first into the field-form editor.
  #
  # Returns the editor map or nil (no doc selected / doc not found).
  defp build_editor(type_name, schema, rest, dataset, opts, active_group) do
    scope_kw = scope(opts)

    cond do
      type_name == "mediaAsset" and rest == [] ->
        %{
          view: :media_explorer,
          type: type_name,
          schema: schema,
          kind_filter: desk_kind_filter(active_group)
        }

      # Blocks-doc whitelist (`Content.blocks_type?/1` — `["paper", "session"]`,
      # session-handoff Task 3): a session opens in the SAME paper pane by
      # design (`view: :paper`), fetched by its actual type rather than the
      # hardcoded "paper" equality this replaced. "sheet"/"graph" are fixed
      # plugin schema names with no accessor.
      Content.blocks_type?(type_name) ->
        case rest do
          [slug | _] ->
            # DRAFT-FIRST, like every other editor branch. `create_document`
            # ALWAYS writes `drafts.<id>` (writer.ex) and the desk navigates to
            # the PUBLISHED id, so a published-only lookup here resolved to
            # nothing for every never-published paper — a brand-new one most of
            # all. That is the owner's blank screen (spd-w17): a doc was
            # created, the URL moved, and the pane still read "Select a document
            # to edit". The flags were hardcoded `false`, so a draft paper that
            # did open claimed to be published; thread the real ones.
            case Content.fetch_doc_with_draft(type_name, slug, dataset, scope_kw) do
              {nil, _is_draft, _has_pub} ->
                nil

              {paper_doc, is_draft, has_pub} ->
                %{
                  view: :paper,
                  doc: paper_doc,
                  schema: schema,
                  type: type_name,
                  is_draft: is_draft,
                  has_published: has_pub,
                  form: %{}
                }
            end

          _ ->
            nil
        end

      type_name == "graph" ->
        case rest do
          [doc_id | _] ->
            {doc, is_draft, has_pub} =
              Content.fetch_doc_with_draft(type_name, doc_id, dataset, scope_kw)

            if doc do
              %{
                view: :graph,
                doc: doc,
                schema: schema,
                type: type_name,
                is_draft: is_draft,
                has_published: has_pub,
                form: %{},
                graph: graph_payload(doc, dataset, scope_kw)
              }
            end

          _ ->
            nil
        end

      type_name == "sheet" ->
        case rest do
          [doc_id | _] ->
            {doc, is_draft, has_pub} =
              Content.fetch_doc_with_draft(type_name, doc_id, dataset, scope_kw)

            if doc do
              %{
                view: :sheet,
                doc: doc,
                schema: schema,
                type: type_name,
                is_draft: is_draft,
                has_published: has_pub,
                form: %{}
              }
            end

          _ ->
            nil
        end

      true ->
        case rest do
          [doc_id | _] ->
            {doc, is_draft, has_pub} =
              Content.fetch_doc_with_draft(type_name, doc_id, dataset, scope_kw)

            if doc && schema do
              %{
                doc: doc,
                schema: schema,
                type: type_name,
                is_draft: is_draft,
                has_published: has_pub,
                form: Content.doc_to_form(doc, schema)
              }
            end

          _ ->
            nil
        end
    end
  end

  # Build the blast-radius graph payload for the GraphView pane. Roots on the
  # doc's `documents.id` UUID and walks the materialised `content_edges` table
  # (Phase 4 BFS), direction `:both` so the pane shows both what this doc
  # references AND what references it (the blast radius). Returns the
  # `%{nodes, edges}` slice the GraphView LiveComponent encodes. nil-safe on a
  # doc without an `:id` (degrades to an empty graph rather than crashing the
  # whole pane tree).
  defp graph_payload(%{id: id} = _doc, dataset, scope_kw) when is_binary(id) do
    result =
      Graph.traverse(id, [dataset: dataset, direction: :both, depth: 2] ++ scope_kw)

    # Thread `root` through — the renderer pins it dead-center as the
    # gravitational sun and bands dependents into BFS blast-rings. Dropping it
    # would silently re-center the graph on an arbitrary serialization-order
    # node. Fall back to the queried id (a real node id) when traverse omits it.
    %{nodes: result.nodes, edges: result.edges, root: result.root || id}
  end

  defp graph_payload(_doc, _dataset, _scope_kw), do: %{nodes: [], edges: []}

  # Resolve a doc_id to its `%Document{}` WITHOUT knowing its schema type — the
  # blast-radius pane roots on ANY content doc, so type-agnostic resolution is
  # the point (FIX 2). Published row preferred over its `drafts.` twin
  # (publish-stable, mirroring resolve_doc_pk/3). Scoped to the caller's tenant
  # via `Content.Graph` is not reused here (it traverses, not resolves), so we
  # read the keyed row through the tenant-aware `Content.list_documents`-style
  # scope. Returns nil when nothing in scope matches.
  # Delegates to the canonical Content.Graph.resolve_doc/3 (published-preferred,
  # tenancy-scoped slug→Document) instead of re-building the same Ecto query in
  # the web layer — collapses the resolve_pk/resolve_graph_doc duplication AND
  # removes a raw-Ecto layering violation from PaneBuilder. nil id → nil.
  defp resolve_graph_doc(doc_id, dataset, scope_kw),
    do: Graph.resolve_doc(doc_id, dataset, scope_kw)

  # The open doc's schema type — surfaced on the editor map so StudioLive's
  # toolbar can label/route correctly. A %Document{} carries it as :type.
  defp graph_doc_type(%{type: t}) when is_binary(t), do: t
  defp graph_doc_type(_), do: nil

  # Pull the tenancy scope keyword threaded in via `build(.., scope: scope_opts)`.
  # Returns the `[workspace_id: …, project_id: …]` list (or `[]` when no scope
  # was threaded), ready to append onto a Content read's opts. Nil-safe: the
  # Content query path no-ops on an empty/absent scope.
  defp scope(opts) do
    case Keyword.get(opts, :scope) do
      kw when is_list(kw) -> kw
      _ -> []
    end
  end

  # The `/w/:ws/p/:proj` URL prefix threaded from `rebuild_panes` (or `""` on
  # a flat surface). Feeds `list_items/2`'s plugin-link canonicalisation.
  defp scope_prefix(opts) do
    case Keyword.get(opts, :scope_prefix) do
      prefix when is_binary(prefix) -> prefix
      _ -> ""
    end
  end

  # ── doc-row items: list_preview → preview manifest ──────────────────────────
  #
  # Shared row builder for BOTH document-list branches
  # (`:document_type_list` and `:plugin_document_list`). Two row sources
  # (Preview Contract D17); a DECLARED `list_preview` always wins:
  #
  #   1. list_preview for FIELDFUL docs. task/ticket never enter
  #      Projection.project (no blocks → no manifest, writer.ex:576-594);
  #      they keep the schema-declared `list_preview` — `%{"badge" => <spec>,
  #      "meta" => <spec>}`, each spec a content-field name string or
  #      `%{"field" => f, "prefix" => p}` — surfaced as `:badge`/`:meta`.
  #      The declared spec wins even if such a doc somehow gained a manifest,
  #      so fieldful rows can never regress to the sparse OG description
  #      (mirrors the Go TUI's `rowMeta`, per-key).
  #   2. Manifest for BLOCK docs. A paper/sheet/form write stamps an OG-shaped
  #      manifest at `content["preview"]` (Projection.project/4). When no meta
  #      spec is declared, the row's `:meta` is the manifest description — a
  #      one-line summary the row never had. `:badge` stays declaration-only
  #      (the sparse share manifest carries no badge vocabulary).
  #
  # No manifest AND no declaration → both keys `nil`, the row renders exactly
  # as before (post/page back-compat lock). Generic by construction: PaneBuilder
  # never branches on the document type; the declaration/manifest is the switch.

  defp doc_items(docs, schema) do
    preview = schema_list_preview(schema)

    Enum.map(docs, fn doc ->
      pub_id = Content.published_id(doc.doc_id)

      %{
        type: :doc,
        id: pub_id,
        title: doc.title || "Untitled",
        is_draft: Content.draft?(doc.doc_id),
        status: doc.status,
        badge: preview_value(doc, Map.get(preview, "badge")),
        # `:meta` stays the pure preview-contract value (Go TUI rowMeta parity —
        # nil when no declaration/manifest). `:updated` is the Studio-only
        # subtitle fallback so a row is never a bare mono id; the render picks
        # `meta || updated`. Threading updated_at only READS a field already on
        # every Document — no /v1/structure wire change.
        meta: row_meta(doc, Map.get(preview, "meta")),
        updated: relative_updated(doc)
      }
    end)
  end

  # Humanized "Updated N ago" subtitle fallback. The timestamp is already on
  # every Document struct (`content/query.ex` orders by updated_at_desc); this
  # only READS it — nothing here touches the /v1/structure node wire the Go TUI
  # shares. nil when a row somehow carries no usable timestamp.
  defp relative_updated(%{updated_at: %DateTime{} = ts}), do: "Updated " <> ago(ts)
  defp relative_updated(_), do: nil

  defp ago(%DateTime{} = ts) do
    secs = max(DateTime.diff(DateTime.utc_now(), ts, :second), 0)

    cond do
      secs < 60 -> "just now"
      secs < 3_600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3_600)}h ago"
      secs < 2_592_000 -> "#{div(secs, 86_400)}d ago"
      true -> "#{div(secs, 2_592_000)}mo ago"
    end
  end

  # A declared list_preview meta spec WINS; only spec-less docs (block docs —
  # paper/sheet/form — declare none) read the write-time manifest description.
  # Identical priority to the Go TUI's `rowMeta` (listpreview_render_test.go
  # pins it there; pane_builder_test.exs pins it here).
  defp row_meta(doc, nil), do: manifest_description(doc)
  defp row_meta(doc, spec), do: preview_value(doc, spec)

  # The OG description off a doc's write-time preview manifest, or nil when the
  # doc carries no manifest (task/ticket/classic docs) or an empty description.
  # The manifest is `content["preview"]`, a string-keyed map (Barkpark.Preview).
  defp manifest_description(doc) do
    with %{} = content <- Map.get(doc, :content),
         %{"description" => desc} when is_binary(desc) <- Map.get(content, "preview"),
         trimmed when trimmed != "" <- String.trim(desc) do
      trimmed
    else
      _ -> nil
    end
  end

  defp schema_list_preview(nil), do: %{}

  defp schema_list_preview(schema) do
    case Map.get(schema, :list_preview) || Map.get(schema, "list_preview") do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp preview_value(_doc, nil), do: nil

  defp preview_value(doc, field) when is_binary(field),
    do: format_preview(content_value(doc, field), "")

  defp preview_value(doc, %{} = spec) do
    field = Map.get(spec, "field") || Map.get(spec, :field)
    prefix = Map.get(spec, "prefix") || Map.get(spec, :prefix) || ""

    if is_binary(field), do: format_preview(content_value(doc, field), prefix)
  end

  defp preview_value(_doc, _spec), do: nil

  defp content_value(doc, field) do
    case Map.get(doc, :content) do
      %{} = content -> Map.get(content, field)
      _ -> nil
    end
  end

  # Only scalar values render; nil / "" / structured values are skipped
  # so a misdeclared field degrades to "no badge", never a crash.
  defp format_preview(nil, _prefix), do: nil
  defp format_preview("", _prefix), do: nil

  defp format_preview(value, prefix) when is_binary(value) or is_number(value),
    do: prefix <> to_string(value)

  defp format_preview(_value, _prefix), do: nil

  # ── desk_groups helpers ────────────────────────────────────────────────────
  #
  # A schema may declare `desk_groups: [%{"name" => …, "title" => …,
  # "filter" => %{<path> => %{<op> => <val>}}}, …]`. PaneBuilder treats
  # them as alternative chip-style filters on a single `:document_type_list`
  # pane. Schemas without `desk_groups` (or with `[]`) render the existing
  # single flat list — back-compat lock.

  # Read a document list AFTER checking its filter map — never around a rescue.
  #
  # Three filter sources reach `Content.list_documents/3` from this module: a
  # plugin node's verbatim `filter` map, a structure node's parsed `filter`
  # string, and the active desk group's chip filter merged over either. All three
  # are STORED data, authored elsewhere (a plugin, a structure definition, a
  # customer's schema), and the query builder now REFUSES an unsupported op
  # instead of silently returning every row — so a filter that was written before
  # `SchemaDefinition`'s write-time validation existed would raise from inside
  # the LiveView and take the whole desk down.
  #
  # The pre-flight asks `Query.validate_filter_map/1` the same question the
  # builder would raise on, and turns a refusal into an HONEST pane: no items, and
  # a `filter_error` the pane renders next to the chip row. Deliberately NOT a
  # `rescue` — a rescue would also swallow genuine builder bugs, re-creating the
  # silence this whole change removes, one layer up. Anything OTHER than a bad
  # filter still crashes loudly.
  defp list_documents_preflighted(type_name, dataset, list_opts) do
    filter_map = Keyword.get(list_opts, :filter_map, %{})

    case Content.Query.validate_filter_map(filter_map) do
      :ok ->
        {Content.list_documents(type_name, dataset, list_opts), nil}

      {:error, {nil, :not_a_map}} ->
        {[], "This list's saved filter is malformed and was not applied. No documents are shown."}

      {:error, {field, op}} ->
        {[],
         "This list's saved filter uses an unsupported operator #{inspect(op)} on " <>
           "#{inspect(to_string(field))}, so it could not be applied. No documents are shown — " <>
           "fix the filter in this type's schema (desk groups)."}
    end
  end

  defp schema_desk_groups(nil), do: []

  defp schema_desk_groups(schema) do
    case Map.get(schema, :desk_groups) || Map.get(schema, "desk_groups") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp find_desk_group(_groups, nil), do: nil
  defp find_desk_group(_groups, ""), do: nil

  defp find_desk_group(groups, name) when is_binary(name) do
    Enum.find(groups, fn g ->
      to_string(Map.get(g, "name") || Map.get(g, :name)) == name
    end)
  end

  # Pull the `filter` map off a desk-group spec. Returns `%{}` (no filter)
  # when the group is the "all" bucket or simply omits the key.
  defp desk_filter_map(group) when is_map(group) do
    case Map.get(group, "filter") || Map.get(group, :filter) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  # Map schema desk-group names to bp-asset-explorer kind filters.
  defp desk_kind_filter(nil), do: "all"
  defp desk_kind_filter(%{"name" => "images"}), do: "image"
  defp desk_kind_filter(%{"name" => "video"}), do: "video"
  defp desk_kind_filter(%{"name" => "audio"}), do: "audio"
  defp desk_kind_filter(%{"name" => "documents"}), do: "document"
  defp desk_kind_filter(%{"name" => name}) when is_binary(name), do: "all"
  defp desk_kind_filter(_), do: "all"

  @doc """
  Decide whether a nav pane should render as a narrow collapsed strip.

  Rule (matches Sanity's "breadcrumb collapse"): the two right-most
  columns stay full width. "Column" includes the editor panel if open:

    * No editor, 1 or 2 panes  → no collapse
    * No editor, 3+ panes      → collapse all panes except the last 2
    * Editor open, 1 or 2 panes → no collapse (editor is the 2nd full column)
    * Editor open, 3+ panes    → collapse all panes except the last one
  """
  @spec collapse?(non_neg_integer(), non_neg_integer(), boolean()) :: boolean()
  def collapse?(idx, num_panes, has_editor?) do
    keep_full_nav_count = if has_editor?, do: 1, else: 2
    idx < num_panes - keep_full_nav_count
  end

  @doc """
  Pane display state for a viewport bucket — the ONE table the responsive
  desk reads (pane anatomy model, spd-s3). Pure: `(idx, num_panes,
  has_editor?, bucket)` → `:full | :strip | :hidden`.

  Buckets (matching the CSS breakpoint vocabulary):

    * `"wide"` / `"standard"` — exactly today's behaviour: `:strip` iff
      `collapse?/3`, else `:full`. `collapse?/3` survives VERBATIM as the
      wide-bucket reducer, so every existing nav transition is
      bit-identical (the wide sweep test pins this).
    * `"narrow"`   — depends on whether the document is open:
      * editor OPEN → every pane is `:hidden` except the LAST, which is a
        44px `:strip`. This is the rule that actually closes the 640–1023
        overflow band (charter D35). The briefed "last pane stays `:full`"
        rule was measured bit-identical to `collapse?/3` whenever an
        editor is open (`collapse?/3` already sets `keep_full_nav_count =
        1`, the same predicate as `idx == num_panes - 1`), so it removed
        ZERO pixels: one 140px list column + the 560px content floor still
        overflowed every viewport below ~744px. Hiding the list columns
        and keeping ONE strip leaves 44px of chrome beside the protected
        content pane — the twin of what `"phone"` already does, with a
        back affordance that survives.
      * editor CLOSED → the LAST pane stays `:full` and every earlier pane
        drops to `:strip`. Unchanged: without an editor there is no 560px
        floor in the row, so it never overflowed.
    * `"phone"`    — with an editor open EVERY pane is `:hidden` (the
      document owns the viewport); without an editor the last pane is
      `:full` and the rest `:hidden` (single-column drill navigation).

  Derived display state only — never stored on `Structure.Node`, never
  serialized on the `/v1/structure` wire.
  """
  @spec display_state(non_neg_integer(), pos_integer(), boolean(), String.t()) ::
          :full | :strip | :hidden
  def display_state(idx, num_panes, has_editor?, bucket) when bucket in ["wide", "standard"] do
    if collapse?(idx, num_panes, has_editor?), do: :strip, else: :full
  end

  # Narrow WITH a document open (charter D35): the content pane is the
  # protected winner, so the whole nav row yields to a single 44px back
  # strip. Anything less was measured to close zero pixels of overflow.
  def display_state(idx, num_panes, true, "narrow") do
    if idx == num_panes - 1, do: :strip, else: :hidden
  end

  # Narrow with NO document open: pure drill navigation, last pane full.
  def display_state(idx, num_panes, false, "narrow") do
    if idx == num_panes - 1, do: :full, else: :strip
  end

  def display_state(_idx, _num_panes, true, "phone"), do: :hidden

  def display_state(idx, num_panes, false, "phone") do
    if idx == num_panes - 1, do: :full, else: :hidden
  end

  @doc """
  The Tier-2 ladder (charter D148/D151): the same table, plus the one input
  the desk was missing — whether the user SUMMONED the Document inspector.

  Additive by arity, not by edit. Elixir dispatches `/5` separately from
  `/4`, so the five clauses above are unreachable from here except through
  the explicit delegation in the fall-through clause. That is the whole
  design: `inspector_open? == false` is `/4` VERBATIM in every one of the
  40 cells, and exactly one cell family moves when it is true.

  The moving cell — `"standard"` with a document open and the inspector
  summoned — runs the ladder step the epic's Vision declared and never
  shipped: the nav rail yields so the inspector can dock IN FLOW instead of
  overlaying the prose. The rule is the `"narrow"`-with-editor rule reused
  verbatim: every pane `:hidden` except the LAST, which survives as a 44px
  `:strip` back affordance. Measured at viewport 1024, this takes
  `panes.visible_pane_widths_px` from `[44, 260]` to `[44]`
  (`scripts/measurements/spd-visible-table-2026-07-20.json`), so panel goes
  720 -> 980px, surface border-box 680, gutter 80, content 600. Divided by
  each face's OWN probe-derived advance at 18px: 60.00ch resolved Iowan Old
  Style (10.0000 px/ch), 54.31ch forced Georgia (11.0469 px/ch), 65.42ch
  forced Source Serif 4 (9.1719 px/ch). The cell that ships today is
  378.958px = 37.90 / 34.30 / 41.32ch on those same three faces, so the
  honest headline is +220px against today's user-opened cell.

  Forced Georgia's 54.31ch is an INHERITED shortfall — the default (not
  user-opened) cell is already 54.22ch and this ladder adds 0.09ch. It is
  owned by `spd-b42-georgia-default-shortfall-inflow-width`, not by this
  clause, and D149 refuses the 292px and 260px dock trims that would chase
  it here.

  Every OTHER bucket delegates, and each refusal is a decision:

    * `"wide"` — Tier 1 moves ZERO cells. At 1280/1440 the inspector
      already docks with room to spare; yielding the rail there would spend
      navigation to buy width nobody is short of.
    * `"narrow"` with an editor — already the terminal state of this same
      ladder (D35). There is nothing left to yield.
    * `"narrow"` / `"standard"` with NO editor — no document means no
      Document inspector, so `inspector_open?` cannot be true in a way that
      renders. Delegation keeps the desk honest if it ever is.
    * `"phone"` — the document already owns the viewport.

  Needs no CSS. The overlay and its 55%-black scrim live entirely inside
  `@container panel (max-width: 860px)` in root.html.heex; at panel 980 that
  block stops matching, `.bp-doc-sidebar.is-open`'s `flex: 0 0 300px`
  returns, and the scrim `::after` structurally cannot render.
  """
  @spec display_state(non_neg_integer(), pos_integer(), boolean(), String.t(), boolean()) ::
          :full | :strip | :hidden

  # ── D180 — WHAT THE SURVIVING STRIP ACTUALLY DOES ────────────────────────
  #
  # The 44px strip this clause leaves behind carries `phx-click="expand-pane"`,
  # and spd-b47 was filed on the belief that the ladder and `expand-pane`
  # collide: "the ladder is not a pane state — it is driven by
  # `sidebar_user_opened`, which `expand-pane` does not touch." THAT MECHANISM
  # IS FALSE, and so are both outcomes the task predicted from it (a dead
  # control; or the inspector squeezed back under the reading bar). Both are
  # refuted by execution, not by argument.
  #
  # `expand-pane` DOES reach `sidebar_user_opened` — TRANSITIVELY:
  #
  #   Handlers.Scope.expand_pane/2 (scope.ex:170-178) `push_patch`
  #     -> handle_params -> rebuild_panes/1
  #     -> the fall-through clause (shared.ex:806-811)
  #     -> clear_paper_view/1
  #     -> `assign(sidebar_assigns(nil))` (shared/paper.ex:755)
  #
  # and `sidebar_assigns(nil)` re-seeds `sidebar_user_opened: false`. Read off
  # the live socket after the click: `assigns.sidebar_user_opened = false`.
  #
  # So the measured outcome is a THIRD one, which neither option named. At
  # `standard` with this ladder engaged the sole surviving pane is
  # `{idx: 1, "Papers"}`, and clicking it CLOSES THE WHOLE DOCUMENT:
  #
  #   panes AFTER strip click:  ["pane-structure", "pane-papers"]
  #   editor open AFTER:        false
  #   strips AFTER:             []
  #
  # The rail reverts to ordinary full display because there is no longer an
  # editor for it to yield to. The strip is a DOCUMENT-CLOSE, not an
  # inspector-dismiss, and it needs no suppression: expand-pane already
  # implies dismiss.
  #
  # AND THERE IS NO AFFORDANCE LIE. `expand_pane/2` truncates with
  # `Enum.take(nav_path, idx)`; pane 0 IS the root pane and each ordinary
  # segment contributes exactly one pane, so the strip's label names its own
  # destination in every topology measured — ["paper", slug] -> {1, "Papers"}
  # -> the Papers list; ["open", "paper", slug] -> {0, "Structure"} -> the desk
  # root. No off-by-one to fix.
  #
  # SCOPE, STATED HONESTLY RATHER THAN GENERALISED: every figure above comes
  # from a 2-SEGMENT paper path (panes = [Structure, Papers]). A deeper nav
  # path would make the surviving strip an INTERMEDIATE pane, where `take/2`
  # lands on a list instead of closing the document. That case is NOT measured
  # here — it is filed as `b47-strip-behaviour-unmeasured-beyond-two-panes`.
  # This ruling claims the 2-segment topology only.
  #
  # Locked by `studio_live_navigational_truth_test.exs`, which pins the pane
  # ids AND editor-open false AND `sidebar_user_opened == false` — pane ids
  # alone would stay green if the reset chain above were refactored away.
  def display_state(idx, num_panes, true, "standard", true) do
    if idx == num_panes - 1, do: :strip, else: :hidden
  end

  def display_state(idx, num_panes, has_editor?, bucket, _inspector_open?),
    do: display_state(idx, num_panes, has_editor?, bucket)

  @doc """
  Convert a Structure node's children into pane items. Dividers stay as
  `:divider`; plugin-contributed `:plugin_link` items render as
  `:plugin_link` rows the LV turns into outbound navigation (NOT
  `push_patch` — these point at arbitrary paths outside the StudioLive
  catch-all); everything else becomes `:item` with a `drillable` flag.

  `scope_prefix` (the `/w/:ws/p/:proj` prefix, `""` on a flat surface)
  canonicalises `:plugin_link` hrefs at SOURCE via `Paths.plugin_link_href/2`
  — Structure emits them flat (`/studio/<ds>/…`), so the scoped surface
  rewrites them here to the `/d/` canonical rather than at render time.
  The 1-arity form defaults to `""` (flat, unchanged) for legacy callers.
  """
  @spec list_items(map()) :: [map()]
  def list_items(node), do: list_items(node, "")

  @spec list_items(map(), String.t()) :: [map()]
  def list_items(node, scope_prefix) do
    Enum.flat_map(node.items, fn child ->
      case child.type do
        :divider ->
          # Carry the optional label through so the renderer can show it as a
          # section break. Legacy host-side dividers omit it (label nil).
          [%{type: :divider, id: child.id, label: Map.get(child, :title)}]

        :plugin_link ->
          [
            %{
              type: :plugin_link,
              id: child.id,
              title: child.title,
              icon: child.icon,
              # PaneBuilder stashes the destination in `:filter` on the Node;
              # surface it here under the more descriptive `:href` key,
              # canonicalised against the current scope at SOURCE.
              href: Paths.plugin_link_href(scope_prefix, child.filter)
            }
          ]

        _ ->
          drillable = child.type in [:list, :document_type_list, :plugin_document_list]

          [
            %{
              type: :item,
              id: child.id,
              title: child.title,
              # `|| "file"` closes the asymmetry that WAS the bug
              # (spd-w18-nil-icon-500): the placed-node paths above already
              # fall back (`node.icon || (schema && schema.icon)`), this
              # forwarding did not, and its render site draws the icon
              # UNCONDITIONALLY — so a nil here 500'd the whole desk column.
              # No schema is in hand at this depth, hence the neutral glyph
              # rather than a schema icon. (`:plugin_link` above stays
              # nil-tolerant on purpose: its render site is wrapped in
              # `if item.icon`, so nil means "draw no glyph" there, a real
              # design state rather than a crash.)
              icon: child.icon || "file",
              drillable: drillable
            }
          ]
      end
    end)
  end

  @doc """
  Update a doc's title in the pane items list without rebuilding from
  DB. Hot-path optimisation for autosave — preserves N+1-query-free
  behaviour per IMPL-SPEC Risk #3.
  """
  @spec update_title([map()], String.t(), String.t()) :: [map()]
  def update_title(panes, doc_id, new_title) do
    Enum.map(panes, fn pane ->
      updated_items =
        Enum.map(pane.items, fn item ->
          if Map.get(item, :type) == :doc && Map.get(item, :id) == doc_id do
            %{item | title: new_title}
          else
            item
          end
        end)

      %{pane | items: updated_items}
    end)
  end

  @doc """
  Find the URL path segments for a given (type, doc_id) in the
  Structure tree. Recursively searches nested groups (at any depth) for
  the node that lists `type` — a `:document_type_list` or
  `:plugin_document_list` (preferring the unfiltered "All" view over
  filtered sub-views of the same type) or a `:document` singleton
  (whose path omits the doc id: singletons resolve by type name).
  Falls back to `[type, doc_id]` when the type isn't in the tree.
  Used by the `jump-to-user` event handler to resolve a presence
  target back to a navigable URL.
  """
  @spec find_doc_path(map(), String.t(), String.t()) :: [String.t()]
  def find_doc_path(structure, type, doc_id) do
    case find_type_node(structure.items || [], type, []) do
      {path, %{type: :document}} -> path
      {path, _node} -> path ++ [doc_id]
      nil -> [type, doc_id]
    end
  end

  # DFS for the structure node that lists `type`. Returns `{id_path, node}`
  # or nil. At each level direct matches beat descents into sub-lists, and
  # among doc-list siblings of the same type the unfiltered one (the "All"
  # view a filtered group always carries) beats the filtered sub-views.
  defp find_type_node(items, type, acc) do
    direct =
      items
      |> Enum.filter(fn node ->
        node.type in [:document_type_list, :plugin_document_list, :document] and
          (node.type_name == type or node.id == type)
      end)
      |> Enum.sort_by(&(&1.filter != nil))
      |> List.first()

    if direct do
      {acc ++ [direct.id], direct}
    else
      Enum.find_value(items, fn
        %{type: :list, items: children} = node when is_list(children) ->
          find_type_node(children, type, acc ++ [node.id])

        _ ->
          nil
      end)
    end
  end
end
