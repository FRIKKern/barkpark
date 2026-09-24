defmodule Barkpark.Plugins.Bulldocs.Masters.Linked do
  @moduledoc """
  LINKED paper-master instances, the read side (task-59f078a2fd248698;
  `docs/decisions/0010-paper-masters.md` §5).

  A linked instance is a `master-ref` block (`Barkpark.PortableDoc.MasterRef`)
  holding a master id and a pinned version (nil = follow latest). Nothing is
  copied into the instance paper: the renderer resolves the reference at READ
  time from the map `render_map/3` builds, so editing a master never writes
  into an instance document.

    * **Tenancy.** A reference resolves ONLY inside the instance paper's own
      workspace, project and dataset — the same exact-match rule detached
      insertion uses. A master in another tenant and a missing master are both
      simply absent from the map, and the walker renders both as the identical
      "Master unavailable" state.
    * **Batched.** `render_map/3` never queries per instance. It collects every
      distinct reference in the paper, then reads LEVEL BY LEVEL: one query for
      the current master rows of the whole level, plus at most one query for the
      pinned revisions that are not the current row. At most `max_depth/0`
      levels, so a render costs at most `2 * max_depth()` queries however many
      instances the paper holds.
    * **Cycles.** A master may itself contain a linked instance. Rendering keeps
      the chain of masters it is inside; a master already on that chain, or a
      chain deeper than `max_depth/0`, renders as unavailable instead of
      recursing.
    * **Pinned versions** resolve from the master's revision history
      (`revisions.rev` is the document's opaque `_rev` at snapshot time), or
      from the current row when it still carries that rev. A pinned reference
      whose master no longer exists in scope is unavailable too.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.{Document, DraftId, Revision}
  alias Barkpark.PortableDoc.{MasterRef, Render}
  alias Barkpark.Repo

  @type_name "paper_master"
  @paper_type "paper"
  @max_depth 3

  # Every paper whose content holds a master-ref naming `$m` (published id) or
  # `$d` (its draft twin), at any depth. Passed as a PARAMETER, never inlined:
  # a jsonpath filter's `?` inside an Ecto fragment string would be counted as
  # a bind placeholder.
  @instance_path ~S{lax $.** ? (@.type == "master-ref" && (@.master == $m || @.master == $d))}

  @doc "How deep linked instances may nest (a master holding an instance, …)."
  def max_depth, do: @max_depth

  @doc """
  The `%{MasterRef.key => prerendered_html}` map for every linked instance in
  `blocks`, resolved inside `scope` — a paper `%Document{}`, or a map / keyword
  list with `:workspace_id`, `:project_id`, `:dataset`.

  `opts`: `:published_only` (the public reader: only PUBLISHED master rows and
  published revisions resolve), `:style` (default `:article`), `:theme`.
  A key is absent when its master is missing, foreign, cyclic or too deep; the
  walker renders those as unavailable.
  """
  def render_map(scope, blocks, opts \\ []) do
    case MasterRef.refs(blocks) do
      [] ->
        %{}

      refs ->
        scope = scope_of(scope)
        nodes = fetch_closure(scope, refs, opts)

        render_opts = %{
          style: Keyword.get(opts, :style, :article),
          theme: Keyword.get(opts, :theme, :evergreen)
        }

        render_refs(refs, nodes, [], render_opts)
    end
  end

  @doc """
  The node a single reference resolves to in `scope` (draft-first, the
  authoring view), plus the master row it came from:
  `{:ok, node, %Document{}}` or `:error`. Used by Detach and Pin.
  """
  def resolve(scope, {master, version} = ref) when is_binary(master) do
    scope = scope_of(scope)

    with %Document{} = row <- scope |> current_rows([base(master)], []) |> Map.get(base(master)),
         node when is_map(node) <- Map.get(fetch(scope, [ref], []), ref) do
      {:ok, node, %{row | rev: version || row.rev}}
    else
      _ -> :error
    end
  end

  @doc """
  The published ids of the papers holding a live linked instance of `master`,
  sorted. Only papers in the MASTER's own workspace, project and dataset are
  searched — a paper in another tenant can never resolve this master, so it is
  not an instance, and its id is never listed.
  """
  def live_instances(%Document{} = master) do
    pid = base(master.doc_id)

    from(d in Document,
      where:
        d.type == @paper_type and d.dataset == ^master.dataset and
          fragment(
            "jsonb_path_exists(?, ?::jsonpath, jsonb_build_object('m', ?::text, 'd', ?::text))",
            d.content,
            ^@instance_path,
            ^pid,
            ^DraftId.draft_id(pid)
          ),
      select: d.doc_id
    )
    |> scope_eq(:workspace_id, master.workspace_id)
    |> scope_eq(:project_id, master.project_id)
    |> Repo.all()
    |> Enum.map(&DraftId.published_id/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ── rendering ───────────────────────────────────────────────────────────────

  defp render_refs(refs, nodes, chain, render_opts) do
    Enum.reduce(refs, %{}, fn ref, acc ->
      case render_ref(ref, nodes, chain, render_opts) do
        html when is_binary(html) -> Map.put(acc, MasterRef.key(ref), html)
        nil -> acc
      end
    end)
  end

  # `chain` is the masters this render is already inside (outermost last).
  defp render_ref({master, _} = ref, nodes, chain, render_opts) do
    node = Map.get(nodes, ref)
    id = base(master)

    cond do
      not is_map(node) -> nil
      id in chain -> nil
      length(chain) >= @max_depth -> nil
      true -> render_node(node, nodes, [id | chain], render_opts)
    end
  end

  defp render_node(node, nodes, chain, render_opts) do
    inner = render_refs(MasterRef.refs(node), nodes, chain, render_opts)
    Render.render_block(node, Map.put(render_opts, :masters, inner))
  rescue
    _ -> nil
  end

  # ── batched reads ───────────────────────────────────────────────────────────

  # Level by level: the references of the paper, then the references inside
  # the masters just read, … at most @max_depth levels. Each level is ONE
  # `fetch/3` (<= 2 queries). A reference already read is never read again.
  defp fetch_closure(scope, refs, opts) do
    {nodes, _} =
      Enum.reduce_while(1..@max_depth, {%{}, refs}, fn _level, {acc, pending} ->
        case Enum.reject(pending, &Map.has_key?(acc, &1)) do
          [] ->
            {:halt, {acc, []}}

          pending ->
            fetched = fetch(scope, pending, opts)

            next =
              fetched
              |> Map.values()
              |> Enum.filter(&is_map/1)
              |> Enum.flat_map(&MasterRef.refs/1)
              |> Enum.uniq()

            {:cont, {Map.merge(acc, fetched), next}}
        end
      end)

    nodes
  end

  # `%{ref => node | nil}` for every ref of one level.
  defp fetch(scope, refs, opts) do
    rows = current_rows(scope, refs |> Enum.map(fn {m, _} -> base(m) end) |> Enum.uniq(), opts)

    # A pin the current row still satisfies needs no history read.
    missing_pins =
      refs
      |> Enum.filter(fn {m, v} ->
        is_binary(v) and match?(%Document{rev: rev} when rev != v, Map.get(rows, base(m)))
      end)
      |> Enum.map(fn {m, v} -> {base(m), v} end)
      |> Enum.uniq()

    pinned = pinned_revisions(scope, missing_pins, opts)

    Map.new(refs, fn {m, v} = ref ->
      node =
        case {Map.get(rows, base(m)), v} do
          {nil, _} -> nil
          {row, nil} -> node_of(row.content)
          {%Document{rev: ^v} = row, _} -> node_of(row.content)
          {_row, v} -> node_of(Map.get(pinned, {base(m), v}))
        end

      {ref, node}
    end)
  end

  # ONE query: the current master row per published id, in scope. Authoring
  # reads prefer the draft (the latest edit, the row detached insertion copies
  # from); the public reader reads PUBLISHED rows only.
  defp current_rows(_scope, [], _opts), do: %{}

  defp current_rows(scope, bases, opts) do
    published_only? = Keyword.get(opts, :published_only, false)
    ids = if published_only?, do: bases, else: bases ++ Enum.map(bases, &DraftId.draft_id/1)

    from(d in Document,
      where: d.type == @type_name and d.dataset == ^scope.dataset and d.doc_id in ^ids
    )
    |> scope_eq(:workspace_id, scope.workspace_id)
    |> scope_eq(:project_id, scope.project_id)
    |> Repo.all()
    |> Enum.sort_by(&if(DraftId.draft?(&1.doc_id), do: 0, else: 1))
    |> Enum.reduce(%{}, fn row, acc -> Map.put_new(acc, base(row.doc_id), row) end)
  end

  # ONE query: the newest revision snapshot per `{published id, rev}` pair, in
  # the same workspace, project and dataset.
  defp pinned_revisions(_scope, [], _opts), do: %{}

  defp pinned_revisions(scope, pins, opts) do
    ids = pins |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    revs = pins |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    wanted = MapSet.new(pins)

    query =
      from(r in Revision,
        where:
          r.type == @type_name and r.dataset == ^scope.dataset and r.doc_id in ^ids and
            r.rev in ^revs,
        order_by: [desc: r.inserted_at, desc: r.id],
        select: {r.doc_id, r.rev, r.content, r.status}
      )
      |> scope_eq(:workspace_id, scope.workspace_id)
      |> scope_eq(:project_id, scope.project_id)

    query
    |> Repo.all()
    |> Enum.filter(fn {id, rev, _content, status} ->
      MapSet.member?(wanted, {id, rev}) and
        (not Keyword.get(opts, :published_only, false) or status == "published")
    end)
    |> Enum.reduce(%{}, fn {id, rev, content, _}, acc -> Map.put_new(acc, {id, rev}, content) end)
  end

  defp node_of(%{"node" => node}) when is_map(node), do: node
  defp node_of(_), do: nil

  defp base(id), do: DraftId.published_id(id)

  defp scope_of(%Document{} = paper),
    do: %{workspace_id: paper.workspace_id, project_id: paper.project_id, dataset: paper.dataset}

  defp scope_of(scope) when is_list(scope), do: scope |> Map.new() |> scope_of()

  defp scope_of(%{} = scope),
    do: %{
      workspace_id: Map.get(scope, :workspace_id),
      project_id: Map.get(scope, :project_id),
      dataset: Map.get(scope, :dataset, "production")
    }

  defp scope_eq(query, field, nil), do: from(d in query, where: is_nil(field(d, ^field)))
  defp scope_eq(query, field, value), do: from(d in query, where: field(d, ^field) == ^value)
end
