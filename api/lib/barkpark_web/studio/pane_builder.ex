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

  @doc """
  Build the full pane tree for `dataset` along `nav_path`. Returns
  `{panes, editor}` where `panes` is a list of pane maps and `editor`
  is either `nil` or a map describing the open document editor.

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
  """
  @spec build(String.t(), [String.t()]) :: {[map()], map() | nil}
  def build(dataset, nav_path), do: build(dataset, nav_path, [])

  @spec build(String.t(), [String.t()], keyword()) :: {[map()], map() | nil}
  def build(dataset, nav_path, opts) do
    structure = Structure.build(dataset, nil, scope(opts))

    root_pane = %{
      title: structure.title,
      items: list_items(structure),
      selected: Enum.at(nav_path, 0)
    }

    walk_path(nav_path, 0, structure, [root_pane], nil, dataset, opts)
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
  # Cytoscape `view: :graph` editor for `<doc_id>` regardless of its type. This
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
      if type == "paper" do
        case Content.get_paper(id, dataset, scope(opts)) do
          nil ->
            nil

          paper_doc ->
            %{
              view: :paper,
              doc: paper_doc,
              schema: nil,
              type: type,
              is_draft: false,
              has_published: false,
              form: %{}
            }
        end
      else
        case Content.fetch_doc_with_draft(type, id, dataset, scope(opts)) do
          {doc, is_draft, has_pub} when not is_nil(doc) ->
            schema =
              case Content.get_schema(type, dataset) do
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
          items: list_items(node),
          selected: Enum.at(rest, 0)
        }

        walk_path(rest, depth + 1, node, panes ++ [list_pane], nil, dataset, opts)

      # Plugin-contributed pre-filtered document list. Same rendering as
      # `:document_type_list` but the filter map is carried verbatim on
      # `node.filter` (a map, not a "field=value" string) so PaneBuilder
      # bypasses `Structure.parse_filter/1`.
      %{type: :plugin_document_list, type_name: type_name} = node ->
        schema =
          case Content.get_schema(type_name, dataset) do
            {:ok, s} -> s
            _ -> nil
          end

        plugin_filter = if is_map(node.filter), do: node.filter, else: %{}
        list_opts = [perspective: :drafts, filter_map: plugin_filter] ++ scope(opts)
        docs = Content.list_documents(type_name, dataset, list_opts)

        doc_pane = %{
          title: node.title || (schema && schema.title) || type_name,
          icon: node.icon || (schema && schema.icon),
          type_name: type_name,
          desk_groups: [],
          active_desk: nil,
          items: doc_items(docs, schema),
          selected: Enum.at(rest, 0)
        }

        editor =
          case rest do
            [doc_id | _] ->
              {doc, is_draft, has_pub} =
                Content.fetch_doc_with_draft(type_name, doc_id, dataset, scope(opts))

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

        {panes ++ [doc_pane], editor}

      # Plugin-contributed link row — terminal node, no pane to add. The
      # LV inspects `nav_path` and turns this into outbound navigation
      # via `push_navigate`. Returning the unchanged pane stack keeps the
      # parent list pane visible while the navigation flushes.
      %{type: :plugin_link} ->
        {panes, nil}

      %{type: :document_type_list, type_name: type_name} = node ->
        schema =
          case Content.get_schema(type_name, dataset) do
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

        docs = Content.list_documents(type_name, dataset, list_opts)

        # Papers are listed in the desk and OPEN LIVE inside the Studio editor
        # pane (a streaming block view), NOT the Studio form editor and NOT an
        # external link out to `/papers/:slug`. Their list rows are ordinary
        # selectable `:doc` rows so `phx-click="select"` drives Studio-internal
        # navigation to `/studio/:dataset/paper/:slug`; the editor map carries
        # `view: :paper` so StudioLive renders the block stream instead of a
        # field form.
        paper? = type_name == Content.paper_type()

        doc_pane = %{
          title: node.title || (schema && schema.title) || type_name,
          icon: node.icon || (schema && schema.icon),
          type_name: type_name,
          desk_groups: desk_groups,
          active_desk: active_group && Map.get(active_group, "name"),
          items: doc_items(docs, schema),
          selected: Enum.at(rest, 0)
        }

        editor =
          cond do
            type_name == "mediaAsset" and rest == [] ->
              %{
                view: :media_explorer,
                type: type_name,
                schema: schema,
                kind_filter: desk_kind_filter(active_group)
              }

            # A paper opens as a LIVE block view in the editor pane. Build a
            # `view: :paper` editor map carrying the paper document so
            # StudioLive can render + subscribe to the block stream.
            paper? ->
              case rest do
                [slug | _] ->
                  case Content.get_paper(slug, dataset, scope(opts)) do
                    nil ->
                      nil

                    paper_doc ->
                      %{
                        view: :paper,
                        doc: paper_doc,
                        schema: schema,
                        type: type_name,
                        is_draft: false,
                        has_published: false,
                        form: %{}
                      }
                  end

                _ ->
                  nil
              end

            # A `graph` doc opens as the blast-radius Cytoscape pane (Goal
            # ges/graph-edge-seam, Phase 5). Same draft-first doc resolution as
            # the generic branch, but the editor map carries `view: :graph` plus
            # the traversed node/edge payload (reverse direction — the
            # blast-radius is "what would break if this doc went away"). The
            # GraphView LiveComponent renders it; the StudioLive `:graph` arm
            # wires it up. Built via Content.Graph.traverse/2 (Phase 4).
            type_name == "graph" ->
              case rest do
                [doc_id | _] ->
                  {doc, is_draft, has_pub} =
                    Content.fetch_doc_with_draft(type_name, doc_id, dataset, scope(opts))

                  if doc do
                    %{
                      view: :graph,
                      doc: doc,
                      schema: schema,
                      type: type_name,
                      is_draft: is_draft,
                      has_published: has_pub,
                      form: %{},
                      graph: graph_payload(doc, dataset, scope(opts))
                    }
                  end

                _ ->
                  nil
              end

            # A sheet opens as the collaborative grid editor (Sheets M2).
            # Same draft-first doc resolution as the generic branch, but the
            # editor map carries `view: :sheet` so StudioLive renders the
            # SheetGrid LiveComponent instead of the field form.
            type_name == "sheet" ->
              case rest do
                [doc_id | _] ->
                  {doc, is_draft, has_pub} =
                    Content.fetch_doc_with_draft(type_name, doc_id, dataset, scope(opts))

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
                    Content.fetch_doc_with_draft(type_name, doc_id, dataset, scope(opts))

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

        {panes ++ [doc_pane], editor}

      %{type: :document, type_name: type_name} ->
        schema =
          case Content.get_schema(type_name, dataset) do
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

  # ── doc-row items + list_preview ───────────────────────────────────────────
  #
  # Shared row builder for BOTH document-list branches
  # (`:document_type_list` and `:plugin_document_list`). When the schema
  # declares `list_preview` — `%{"badge" => <spec>, "meta" => <spec>}`,
  # each spec a content-field name string or `%{"field" => f, "prefix"
  # => p}` — the named content values ride along on each row map as
  # `:badge` / `:meta` strings. No declaration → both keys are `nil` and
  # the row renders exactly as before (post/page/paper back-compat lock).
  # Generic by construction: any schema (host seed, plugin, ad-hoc) can
  # declare it; PaneBuilder never branches on the document type.

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
        meta: preview_value(doc, Map.get(preview, "meta"))
      }
    end)
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
  Convert a Structure node's children into pane items. Dividers stay as
  `:divider`; plugin-contributed `:plugin_link` items render as
  `:plugin_link` rows the LV turns into outbound navigation (NOT
  `push_patch` — these point at arbitrary paths outside the StudioLive
  catch-all); everything else becomes `:item` with a `drillable` flag.
  """
  @spec list_items(map()) :: [map()]
  def list_items(node) do
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
              # surface it here under the more descriptive `:href` key.
              href: child.filter
            }
          ]

        _ ->
          drillable = child.type in [:list, :document_type_list, :plugin_document_list]

          [
            %{
              type: :item,
              id: child.id,
              title: child.title,
              icon: child.icon,
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
  Structure tree. Handles direct children (simple doc list), nested
  sub-lists (e.g. posts inside a settings sub-list), and singleton
  fallback. Used by the `jump-to-user` event handler to resolve a
  presence target back to a navigable URL.
  """
  @spec find_doc_path(map(), String.t(), String.t()) :: [String.t()]
  def find_doc_path(structure, type, doc_id) do
    direct = Enum.find(structure.items, &(&1.id == type && &1.type == :document_type_list))

    if direct do
      [type, doc_id]
    else
      parent =
        Enum.find(structure.items, fn node ->
          node.type == :list &&
            Enum.any?(node.items || [], fn child ->
              child.type == :document_type_list && child.type_name == type
            end)
        end)

      if parent do
        all_item =
          Enum.find(parent.items, fn child ->
            child.type == :document_type_list && child.type_name == type && child.filter == nil
          end)

        sub_id = if all_item, do: all_item.id, else: "#{type}-all"
        [parent.id, sub_id, doc_id]
      else
        [type, doc_id]
      end
    end
  end
end
