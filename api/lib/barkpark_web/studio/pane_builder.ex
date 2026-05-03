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
  """
  @spec build(String.t(), [String.t()]) :: {[map()], map() | nil}
  def build(dataset, nav_path) do
    structure = Structure.build(dataset)

    root_pane = %{
      title: structure.title,
      items: list_items(structure),
      selected: Enum.at(nav_path, 0)
    }

    walk_path(nav_path, 0, structure, [root_pane], nil, dataset)
  end

  @doc """
  Recursively walk `path` against `current_node`'s children, building a
  pane at each depth. Mirrors the TUI's `rebuildPanes()` loop. Returns
  `{panes, editor_or_nil}`.
  """
  @spec walk_path([String.t()], non_neg_integer(), map(), [map()], map() | nil, String.t()) ::
          {[map()], map() | nil}
  def walk_path([], _depth, _current, panes, editor, _dataset), do: {panes, editor}

  def walk_path([id | rest], depth, current, panes, _editor, dataset) do
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

        walk_path(rest, depth + 1, node, panes ++ [list_pane], nil, dataset)

      %{type: :document_type_list, type_name: type_name} = node ->
        schema =
          case Content.get_schema(type_name, dataset) do
            {:ok, s} -> s
            _ -> nil
          end

        opts = [perspective: :drafts]

        opts =
          if node.filter,
            do: opts ++ [filter_map: Structure.parse_filter(node.filter)],
            else: opts

        docs = Content.list_documents(type_name, dataset, opts)

        doc_pane = %{
          title: node.title || (schema && schema.title) || type_name,
          icon: node.icon || (schema && schema.icon),
          type_name: type_name,
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
              {doc, is_draft, has_pub} = Content.fetch_doc_with_draft(type_name, doc_id, dataset)

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

      %{type: :document, type_name: type_name} ->
        schema =
          case Content.get_schema(type_name, dataset) do
            {:ok, s} -> s
            _ -> nil
          end

        if schema do
          {doc, is_draft, has_pub} = Content.fetch_doc_with_draft(type_name, type_name, dataset)

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
  `:divider`; everything else becomes `:item` with a `drillable` flag.
  """
  @spec list_items(map()) :: [map()]
  def list_items(node) do
    Enum.flat_map(node.items, fn child ->
      case child.type do
        :divider ->
          [%{type: :divider, id: child.id}]

        _ ->
          drillable = child.type in [:list, :document_type_list]

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
