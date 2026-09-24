defmodule Barkpark.Plugins.Bulldocs.Masters do
  @moduledoc """
  Paper MASTERS — the save/library half of the composition doctrine's general
  Template capability (task `cd-5b-template-generalization`; design record
  `docs/decisions/0010-paper-masters.md`).

  An author saves one composed node of a paper — any block the doctrine
  classifies as `:element`, `:widget` or `:section`
  (`Barkpark.PortableDoc.Tiers`) — as a master, and later inserts it into a
  paper as a DETACHED copy.

    * **Storage.** A master is its own document, type `"paper_master"`
      (schema `priv/plugins/bulldocs/schemas/paper_master.json`, private), one
      document per master. `content["node"]` holds the node payload verbatim
      (its authored ids included); `tier`, `block_type`, `source_paper` and
      `source_block_id` describe it. The document's own `rev` column is the
      master revision a copy records.
    * **Tenancy.** A master is born in the saving paper's workspace, project
      and dataset. Insertion resolves the master INSIDE the target paper's
      scope, so a master from another tenant is `{:error, :master_not_found}`
      (the same answer as a missing one: no existence oracle).
    * **Detached insertion.** `insert_detached/7` builds ONE `insert-after`
      (or `append-block`) op carrying a copy of the node and applies it through
      `Barkpark.Content.apply_paper_block_ops_once/6` — the existing
      request-identified op path, so every Patch constraint, ratchet,
      normalization, encryption and projection chokepoint runs, and a retried
      request replays its receipt. The copy gets FRESH ids for every map in the
      node that carries one, derived deterministically from the request id (a
      retry builds a byte-identical op, which is what lets the idempotency
      fingerprint match), and its root carries provenance:
      `"master" => %{"id", "rev", "mode" => "detached"}`. Nothing links the
      copy back: later master edits never reach it.
      References inside the node that name one of its own ids (a blockref or
      TOC `anchor`, an in-page `href: "#<id>"`) are rewritten to the fresh
      ids, so they point at the copy.

  LINKED (live-updating) instances are deliberately NOT here — a separate row.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId}
  alias Barkpark.PortableDoc.{BodyWalk, Tiers}
  alias Barkpark.Repo

  @type_name "paper_master"
  @default_dataset "production"
  @tiers [:element, :widget, :section]
  # The paper template's own slot roles (`Papers.Template.paper_declarations/0`).
  # A copy of one would break the paper's cardinality declarations wherever it
  # lands, so a node carrying one is not masterable.
  @template_roles ~w(title featured ingress)

  @doc "The document type masters are stored as."
  def type_name, do: @type_name

  @doc """
  Save the node `block_id` of paper `slug` as a master.

  `opts`: `:workspace_id` / `:project_id` scope the paper lookup exactly like
  the block-op path; `:title` names the master (defaults to the node's own
  `title`, else its type).
  Returns `{:ok, %Document{}}` or `{:error, reason}` —
  `:paper_not_found`, `:block_not_found`, `:not_masterable` (unclassified
  type), `:locked_block` (a template-locked or slot-role node) or
  `:bound_field` (a node carrying a `fieldName` binding: a copy would bind a
  second block to the same schema field).
  """
  def save_master(slug, block_id, dataset \\ @default_dataset, opts \\ [])
      when is_binary(slug) and is_binary(block_id) and is_binary(dataset) do
    with %Document{} = paper <- resolve_paper(slug, dataset, opts),
         {:ok, node} <- find_node(paper, block_id),
         {:ok, tier} <- masterable(node) do
      attrs = %{
        "title" => opts[:title] || default_title(node),
        "content" => %{
          "tier" => Atom.to_string(tier),
          "block_type" => node["type"],
          "source_paper" => slug,
          "source_block_id" => block_id,
          "node" => node
        }
      }

      Content.create_document(@type_name, attrs, dataset,
        workspace_id: paper.workspace_id,
        project_id: paper.project_id
      )
    else
      nil -> {:error, :paper_not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  The masters visible in a scope, newest first. `opts`: `:workspace_id`,
  `:project_id` (both matched exactly, `nil` included).
  """
  def list_masters(dataset \\ @default_dataset, opts \\ []) do
    ws = Keyword.get(opts, :workspace_id)
    project = Keyword.get(opts, :project_id)

    from(d in Document,
      where: d.type == @type_name and d.dataset == ^dataset,
      order_by: [desc: d.inserted_at]
    )
    |> scope_eq(:workspace_id, ws)
    |> scope_eq(:project_id, project)
    |> Repo.all()
  end

  @doc """
  The stable id a copy records for a master: its published id (the row may be
  a `drafts.` row).
  """
  def master_id(%Document{doc_id: doc_id}), do: DraftId.published_id(doc_id)

  @doc """
  Pure: the op that inserts a detached copy of `master` after block `after_id`
  (or appends at the top level when `after_id` is nil). `seed` drives the
  fresh ids — the same seed builds the same op.
  """
  def detached_insert_op(%Document{} = master, after_id, seed) when is_binary(seed) do
    block = detached_copy(master, seed)

    case after_id do
      nil -> %{"op" => "append-block", "block" => block}
      id when is_binary(id) -> %{"op" => "insert-after", "afterId" => id, "block" => block}
    end
  end

  @doc """
  Pure: a detached copy of `master`'s node — fresh ids everywhere, provenance
  on the root.
  """
  def detached_copy(%Document{} = master, seed) when is_binary(seed) do
    node = get_in(master.content || %{}, ["node"])

    ids = id_map(node, seed)

    node
    |> fresh_ids(ids)
    |> Map.put("master", %{
      "id" => master_id(master),
      "rev" => master.rev,
      "mode" => "detached"
    })
  end

  @doc """
  Insert a detached copy of master `master_id` into paper `slug` through the
  request-identified op path (`Content.apply_paper_block_ops_once/6`).

  `opts` pass straight through (`:workspace_id`, `:project_id`, `:if_rev`, …);
  the master is resolved inside the TARGET paper's scope. Returns what the op
  path returns — `{:ok, receipt, :applied | :replayed}` — or
  `{:error, :paper_not_found | :master_not_found | reason}`.
  """
  def insert_detached(slug, master_id, after_id, dataset, request_id, principal_key, opts \\ [])
      when is_binary(slug) and is_binary(master_id) and is_binary(dataset) do
    with %Document{} = paper <- resolve_paper(slug, dataset, opts),
         {:ok, op} <- insert_op(paper, master_id, after_id, request_id) do
      Content.apply_paper_block_ops_once(slug, [op], dataset, request_id, principal_key, opts)
    else
      nil -> {:error, :paper_not_found}
      {:error, :master_not_found} = err -> err
    end
  end

  @doc """
  The detached-insert op for master `master_id` into the already-resolved
  `paper`, or `{:error, :master_not_found}`. The master is looked up INSIDE the
  paper's workspace, project and dataset (the same rule as `insert_detached/7`);
  the ids are seeded off the canonical `request_id`, so a retried request builds
  the byte-identical op. This is the seam a caller that owns its own guard
  ladder and op path (the Studio paper socket) uses instead of
  `insert_detached/7`.
  """
  def insert_op(%Document{} = paper, master_id, after_id, request_id)
      when is_binary(master_id) do
    case get_master_in_scope(master_id, paper) do
      %Document{} = master ->
        seed = "#{canonical_request_id(request_id)}\u0000#{master_id(master)}"
        {:ok, detached_insert_op(master, after_id, seed)}

      :master_not_found ->
        {:error, :master_not_found}
    end
  end

  @doc """
  The masters an author may insert into `paper`: exactly the masters in the
  paper's own workspace, project and dataset (`list_masters/2` with the
  paper's scope, the same scope `insert_op/4` resolves in).
  """
  def list_for_paper(%Document{} = paper) do
    list_masters(paper.dataset,
      workspace_id: paper.workspace_id,
      project_id: paper.project_id
    )
  end

  @doc """
  Pure: may `node` be saved as a master? The same refusal set as
  `save_master/4` (`:not_masterable`, `:locked_block`, `:bound_field`), as a
  boolean the editor uses to decide whether to offer the action.
  """
  def masterable?(node) when is_map(node), do: match?({:ok, _}, masterable(node))
  def masterable?(_), do: false

  # ── helpers ─────────────────────────────────────────────────────────────────

  # The op path canonicalizes the request id (`Ecto.UUID.cast/1`) before keying
  # the replay; seed the ids off the SAME canonical form, so a retry that
  # spells the UUID differently still rebuilds a byte-identical op. A
  # non-UUID id is refused by the op path itself.
  defp canonical_request_id(request_id) do
    case Ecto.UUID.cast(request_id) do
      {:ok, canonical} -> canonical
      :error -> to_string(request_id)
    end
  end

  # Same scope rule as the block-op path's paper lookup: an explicit workspace
  # wins; absent one, the seeded Default workspace; absent that, unscoped.
  defp resolve_paper(slug, dataset, opts) do
    case Keyword.get(opts, :workspace_id) do
      ws when is_binary(ws) and ws != "" ->
        Content.get_paper(slug, dataset,
          workspace_id: ws,
          project_id: Keyword.get(opts, :project_id)
        )

      _ ->
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: ws_id} when is_binary(ws_id) ->
            Content.get_paper(slug, dataset, workspace_id: ws_id)

          _ ->
            Content.get_paper(slug, dataset)
        end
    end
  end

  # The master must share the paper's workspace, project AND dataset — matched
  # exactly in the query, so a foreign master is indistinguishable from none.
  defp get_master_in_scope(master_id, %Document{} = paper) do
    base = DraftId.published_id(master_id)

    from(d in Document,
      where:
        d.type == @type_name and d.dataset == ^paper.dataset and
          d.doc_id in ^[base, DraftId.draft_id(base)],
      order_by: [asc: d.doc_id],
      limit: 1
    )
    |> scope_eq(:workspace_id, paper.workspace_id)
    |> scope_eq(:project_id, paper.project_id)
    |> Repo.one()
    |> case do
      %Document{} = master -> master
      nil -> :master_not_found
    end
  end

  defp scope_eq(query, field, nil), do: from(d in query, where: is_nil(field(d, ^field)))
  defp scope_eq(query, field, value), do: from(d in query, where: field(d, ^field) == ^value)

  defp find_node(%Document{content: content}, block_id) do
    (content || %{})
    |> Map.get("blocks", [])
    |> BodyWalk.collect(fn
      %{"id" => ^block_id, "type" => type} = node when is_binary(type) -> [node]
      _ -> []
    end)
    |> case do
      [node | _] -> {:ok, node}
      [] -> {:error, :block_not_found}
    end
  end

  defp masterable(node) do
    tier = Tiers.tier_of(node)

    cond do
      tier not in @tiers -> {:error, :not_masterable}
      any_node?(node, &locked_or_slot_role?/1) -> {:error, :locked_block}
      any_node?(node, &bound?/1) -> {:error, :bound_field}
      true -> {:ok, tier}
    end
  end

  # The name the picker shows when the author gave none: the node's own title
  # (a section's heading line), else its block type.
  defp default_title(%{"title" => title}) when is_binary(title) and title != "", do: title
  defp default_title(node), do: node["type"]

  defp any_node?(node, pred),
    do: BodyWalk.collect(node, &if(pred.(&1), do: [true], else: [])) != []

  defp locked_or_slot_role?(%{"locked" => true}), do: true
  defp locked_or_slot_role?(%{"role" => role}) when role in @template_roles, do: true
  defp locked_or_slot_role?(_), do: false

  defp bound?(%{"fieldName" => name}) when is_binary(name) and name != "", do: true
  defp bound?(_), do: false

  # Every map carrying a binary "id" gets a fresh one: `mst-` + 12 hex of
  # sha256(seed, old id). One mapping per old id, so ids the node repeats stay
  # consistent; deterministic, so a retried request rebuilds the same op.
  defp id_map(node, seed) do
    node
    |> collect_ids([])
    |> Map.new(fn id -> {id, fresh_id(seed, id)} end)
  end

  defp collect_ids(%{} = map, acc) do
    acc =
      case map do
        %{"id" => id} when is_binary(id) and id != "" -> [id | acc]
        _ -> acc
      end

    map |> Map.delete("id") |> Map.values() |> collect_ids(acc)
  end

  defp collect_ids(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_ids/2)
  defp collect_ids(_other, acc), do: acc

  # Replace every id with its fresh twin AND rewrite every INTERNAL reference —
  # a value that names one of the node's own old ids — so it points at the
  # copy, not at the source block it was saved from. A reference to an id that
  # is NOT inside the node (another block of the source paper, another paper)
  # is left alone: only the node's own ids are in `ids`.
  #
  # The reference shapes PortableDoc carries by block id:
  #   * `anchor` — a blockref's `^anchor` (node or mark attrs) and a TOC
  #     entry's anchor;
  #   * `href` of the form `#<id>` — an in-page link mark.
  defp fresh_ids(%{} = map, ids) do
    Map.new(map, fn
      {"id", id} when is_binary(id) and id != "" -> {"id", Map.get(ids, id, id)}
      {"anchor", ref} when is_binary(ref) -> {"anchor", Map.get(ids, ref, ref)}
      {"href", "#" <> ref} -> {"href", "#" <> Map.get(ids, ref, ref)}
      {k, v} -> {k, fresh_ids(v, ids)}
    end)
  end

  defp fresh_ids(list, ids) when is_list(list), do: Enum.map(list, &fresh_ids(&1, ids))
  defp fresh_ids(other, _ids), do: other

  defp fresh_id(seed, id) do
    hex =
      :crypto.hash(:sha256, [seed, 0, id])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "mst-" <> hex
  end
end
