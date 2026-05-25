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
    structure = Structure.build(dataset)

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
          items:
            Enum.map(docs, fn doc ->
              pub_id = Content.published_id(doc.doc_id)

              %{
                type: :doc,
                id: pub_id,
                title: doc.title || "Untitled",
                is_draft: Content.draft?(doc.doc_id),
                status: doc.status
              }
            end),
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
          items:
            Enum.map(docs, fn doc ->
              pub_id = Content.published_id(doc.doc_id)

              %{
                type: :doc,
                id: pub_id,
                title: doc.title || "Untitled",
                is_draft: Content.draft?(doc.doc_id),
                status: doc.status
              }
            end),
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
