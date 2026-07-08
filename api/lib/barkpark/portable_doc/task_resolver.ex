defmodule Barkpark.PortableDoc.TaskResolver do
  @moduledoc """
  Turns a **query-carrying** task block into a **snapshot-carrying** one — the
  bridge that makes a plan (paper) show LIVE `bp` tasks instead of hand-authored
  rows. It is the task twin of `Papers.resolve_embeds_in_blocks`: a block writes
  a `query` (`{parent_id, labels, status, …}`), the resolver runs it against the
  task substrate and injects the resolved `snapshot` (or `task`) the component
  emitters already know how to render.

  Two layers, split so ALL the logic is pure and unit-testable and only the DB
  read is app-coupled:

    * `resolve/2` — pure block traversal. Takes the blocks and a `fetch`
      function `(query_map -> [row])`; walks the tree, replaces each task
      block's `query` with the fetched rows. No DB — inject any fetcher.
    * `row_from_task/1` — pure field mapper: one task doc (in the
      `TasksController` `render_doc` shape) → one component snapshot row
      (`title`/`status`/`priority`/`worker`/`criteria`/`phase`). No DB.

  The DB-backed default fetcher (query → task docs → `row_from_task`) lives with
  the task substrate and carries the tenancy scope; a caller wires it in via
  `resolve(blocks, &Fetcher.rows/1)`. Realtime is the caller's job too:
  re-run `resolve/2` on each `task.*` mutation event and re-render.
  """

  # The block types that read a task snapshot (list/board/roadmap share the
  # `snapshot: [rows]` contract; detail takes a single `task`).
  @snapshot_types ~w(tasks task-list task-board roadmap)
  @detail_type "task-detail"

  # The data-viz block types that read an AGGREGATE (count-only) rollup rather
  # than task rows. Each resolves a `query` into the ratified renderer Attrs:
  # `chart` → `series`, `heatmap` → `cells`, `stat` → `value` (see `shape/2`).
  @dataviz_types ~w(chart heatmap stat)

  @doc """
  Walk `blocks`, resolving every task block that carries a `query`. `fetch` is
  any `(query_map -> [row])` function for the task-ROW blocks. The optional
  `agg_fetch` is `(query_map -> {:ok, tally} | {:error, _})` for the data-viz
  blocks (`chart`/`heatmap`/`stat`) — omit it (or pass `nil`) and those blocks
  pass through UNTOUCHED, the correct offline/wasm degrade (renderer shows its
  dim placeholder). A block with a literal `snapshot`/`task`/`series`/`cells`/
  `value` and no `query` is always left untouched (author-pinned rows work
  offline).
  """
  def resolve(blocks, fetch, agg_fetch \\ nil)

  def resolve(blocks, fetch, agg_fetch) when is_list(blocks) and is_function(fetch, 1) do
    Enum.map(blocks, &resolve_block(&1, fetch, agg_fetch))
  end

  def resolve(blocks, _fetch, _agg_fetch), do: blocks

  @doc """
  Build the LIVE-TASK PREVIEW channel for `blocks` — the DISPLAY-ONLY twin of
  `resolve/2`. Where `resolve/2` REPLACES each `query` with a `snapshot` IN PLACE
  (the reader / `?resolve=tasks` render path, which persists nothing), the Studio
  editor must NOT do that: the continuous canvas diffs every save against the
  SOURCE blocks (the unresolved `query` blocks). If a resolved snapshot entered
  that baseline every save would persist stale rows into the doc and break
  byte-stability (doctrine D5/D3). So `preview/2` leaves `blocks` UNTOUCHED and
  returns a SEPARATE, FLAT list of id-keyed preview entries the editor pushes to
  the task-block node views on a parallel channel:

    * `%{"block_id" => id, "type" => t, "snapshot" => rows}` — a `tasks` /
      `task-list` / `task-board` / `roadmap` block carrying a live `query`.
    * `%{"block_id" => id, "type" => "task-detail", "task" => task}` — the first
      matched row (or `%{}` when none match).
    * `%{"block_id" => id, "type" => t, "error" => true}` — the fetch RAISED
      (Tasks plugin off / substrate error): a quiet stub note, never a crash.

  Only query-carrying blocks WITH a stable `id` produce an entry (the id keys the
  node view; an un-addressable block is skipped). An author-pinned literal
  `snapshot`/`task` (no `query`) is absent from the result — it already carries
  its rows, so there is nothing to preview live. The input `blocks` are never
  returned nor mutated: `preview/2` yields ONLY the previews.
  """
  def preview(blocks, fetch) when is_list(blocks) and is_function(fetch, 1) do
    collect_previews(blocks, fetch)
  end

  def preview(_blocks, _fetch), do: []

  @doc """
  Merge one `preview/2` entry back onto its block FOR DISPLAY — the pure last
  step a render site uses to paint live rows without ever touching the stored
  block. Returns a NEW map shaped exactly like `resolve/2`'s output (`snapshot`/
  `task` present, `query` dropped) so the same component emitters render it —
  the reader's producer, byte for byte (doctrine rule 3). An `error`/unknown
  entry (or `nil`) returns the block unchanged; the caller owns the stub note.
  The input block is never mutated — D5 stays intact by construction.
  """
  def apply_preview(block, %{"snapshot" => rows}) when is_map(block) do
    block |> Map.put("snapshot", rows) |> Map.delete("query")
  end

  def apply_preview(block, %{"task" => task}) when is_map(block) do
    block |> Map.put("task", task) |> Map.delete("query")
  end

  def apply_preview(block, _entry), do: block

  defp collect_previews(blocks, fetch) do
    Enum.flat_map(blocks, &preview_block(&1, fetch))
  end

  defp preview_block(%{"type" => type, "query" => query, "id" => id}, fetch)
       when type in @snapshot_types and is_map(query) and is_binary(id) and id != "" do
    [preview_entry(id, type, query, fetch, :snapshot)]
  end

  defp preview_block(%{"type" => @detail_type, "query" => query, "id" => id}, fetch)
       when is_map(query) and is_binary(id) and id != "" do
    [preview_entry(id, @detail_type, query, fetch, :detail)]
  end

  # A container block (columns/section/…) can nest task blocks in `children`.
  defp preview_block(%{"children" => children}, fetch) when is_list(children) do
    collect_previews(children, fetch)
  end

  defp preview_block(_block, _fetch), do: []

  # Run the block's fetch on a rescue boundary: a raising fetcher (Tasks plugin
  # off / substrate error) degrades to an `{ error: true }` stub entry so the node
  # view shows a quiet note instead of the whole preview push crashing.
  defp preview_entry(id, type, query, fetch, kind) do
    base = %{"block_id" => id, "type" => type}

    try do
      rows = query |> fetch.() |> List.wrap()

      case kind do
        :snapshot ->
          Map.put(base, "snapshot", rows)

        :detail ->
          task =
            case rows do
              [first | _] -> first
              [] -> %{}
            end

          Map.put(base, "task", task)
      end
    rescue
      _ -> Map.put(base, "error", true)
    end
  end

  defp resolve_block(%{"type" => type, "query" => query} = block, fetch, _agg_fetch)
       when type in @snapshot_types and is_map(query) do
    rows = query |> fetch.() |> List.wrap()

    block
    |> Map.put("snapshot", rows)
    |> Map.delete("query")
  end

  defp resolve_block(%{"type" => @detail_type, "query" => query} = block, fetch, _agg_fetch)
       when is_map(query) do
    task =
      case query |> fetch.() |> List.wrap() do
        [first | _] -> first
        [] -> %{}
      end

    block
    |> Map.put("task", task)
    |> Map.delete("query")
  end

  # A data-viz block (chart/heatmap/stat) carrying an aggregate `query`: run the
  # count rollup and MERGE the ratified Attrs (`series`/`cells`/`value`), dropping
  # `query`. An `{:error, _}` (out-of-whitelist dim / non-task source / agg off)
  # leaves the block UNTOUCHED — the renderer then shows its dim placeholder,
  # exactly like an offline/wasm render with only a `query` present.
  defp resolve_block(%{"type" => type, "query" => query} = block, _fetch, agg_fetch)
       when type in @dataviz_types and is_map(query) and is_function(agg_fetch, 1) do
    case agg_fetch.(query) do
      {:ok, tally} when is_map(tally) ->
        block |> Map.merge(shape(type, tally)) |> Map.delete("query")

      _ ->
        block
    end
  end

  # A container block (columns/section/…) can nest task blocks in `children`.
  defp resolve_block(%{"children" => children} = block, fetch, agg_fetch)
       when is_list(children) do
    Map.put(block, "children", resolve(children, fetch, agg_fetch))
  end

  defp resolve_block(block, _fetch, _agg_fetch), do: block

  # ── data-viz shapers (pure): neutral count tally → ratified block Attrs ──────

  @doc """
  Shape a `Barkpark.Tasks.Query.agg_for_query/2` count tally into the ratified
  data-viz Attrs for `type`. COUNT-ONLY: every value is a count.

    * `"stat"`  → `%{"value" => n, "spark" => [...]?}`
    * `"chart"` → `%{"series" => [%{"label", "points" => [...]}]}` (one series
      per primary groupBy value; points per `over` bucket, else a single count)
    * `"heatmap"` → `%{"cells" => [[...]], "max", "rowLabels", "colLabels"}`
  """
  def shape("stat", tally), do: stat_shape(tally)
  def shape("chart", tally), do: chart_shape(tally)
  def shape("heatmap", tally), do: heatmap_shape(tally)
  def shape(_type, _tally), do: %{}

  defp cell(tally, p, s), do: Map.get(tally.tally, {p, s}, 0)

  defp stat_shape(%{buckets: buckets} = t) when is_list(buckets) and buckets != [] do
    %{"value" => t.total, "spark" => Enum.map(buckets, &cell(t, :__all__, &1))}
  end

  defp stat_shape(t), do: %{"value" => t.total}

  defp chart_shape(%{labels1: []} = t) do
    points =
      case t.buckets do
        buckets when is_list(buckets) and buckets != [] ->
          Enum.map(buckets, &cell(t, :__all__, &1))

        _ ->
          [t.total]
      end

    %{"series" => [%{"label" => "count", "points" => points}]}
  end

  defp chart_shape(%{labels1: labels1} = t) do
    axis =
      case t.buckets do
        buckets when is_list(buckets) and buckets != [] -> buckets
        _ -> [:__all__]
      end

    series =
      for l1 <- labels1 do
        %{"label" => l1, "points" => Enum.map(axis, &cell(t, l1, &1))}
      end

    %{"series" => series}
  end

  defp heatmap_shape(%{labels1: rows, labels2: cols} = t) do
    cells = for r <- rows, do: for(c <- cols, do: cell(t, r, c))

    max =
      case List.flatten(cells) do
        [] -> 0
        flat -> Enum.max(flat)
      end

    %{"cells" => cells, "max" => max, "rowLabels" => rows, "colLabels" => cols}
  end

  @doc """
  Map one task doc (the `TasksController.render_doc` shape — tolerant of string
  OR atom keys) into a component snapshot row.

  Status is the honest lifecycle read: a plain `open` task with no unmet blocker
  is surfaced as **ready** (claim it now — the white-ladder distinction the
  design language turns on); `open` WITH blockers stays `open` (backlog).
  Everything else maps straight through (`blocked`/`in_progress`/`done`/
  `cancelled`). A `phase:`/`wave:` label becomes the row's phase group.
  """
  def row_from_task(task) when is_map(task) do
    %{
      "title" => get(task, "title") |> stringish(),
      "status" => status_of(task),
      "priority" => get(task, "priority") |> stringish(),
      "worker" => worker_of(task),
      "criteria" => criteria_of(task),
      "phase" => phase_of(task)
    }
    |> prune()
  end

  def row_from_task(_), do: %{"title" => "", "status" => "open"}

  # ── field mappers (pure) ────────────────────────────────────────────────────

  defp status_of(task) do
    lifecycle = task |> get("lifecycle_status") |> stringish()
    deps = task |> get("dependency_count") |> int_or(0)

    case lifecycle do
      "open" when deps > 0 -> "open"
      "open" -> "ready"
      "" -> if deps > 0, do: "open", else: "ready"
      other -> other
    end
  end

  defp worker_of(task) do
    case get(task, "claim") do
      %{} = claim -> claim |> get("worker") |> stringish()
      _ -> task |> get("assignee") |> stringish()
    end
  end

  # `criteria_progress` is `{met, total}` (atom OR string keys, per the wire).
  # Absent/zero-total → nil so the row simply omits the segment (never "0/0").
  defp criteria_of(task) do
    case get(task, "criteria_progress") do
      %{} = p ->
        total = p |> get("total") |> int_or(0)
        if total > 0, do: %{"met" => int_or(get(p, "met"), 0), "total" => total}, else: nil

      _ ->
        nil
    end
  end

  # First `phase:`/`wave:` label (prefix stripped) names the phase group.
  defp phase_of(task) do
    task
    |> get("labels")
    |> List.wrap()
    |> Enum.map(&stringish/1)
    |> Enum.find_value(fn l ->
      case String.split(l, ":", parts: 2) do
        [p, rest] when p in ~w(phase wave) and rest != "" -> rest
        _ -> nil
      end
    end)
  end

  # ── tolerant helpers ────────────────────────────────────────────────────────

  # Read a key that may be a string OR an atom (render_doc emits atoms; a JSON
  # round-trip emits strings).
  defp get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, safe_atom(key))
    end
  end

  defp get(_, _), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp stringish(nil), do: nil
  defp stringish(s) when is_binary(s), do: s
  defp stringish(n) when is_integer(n), do: Integer.to_string(n)
  defp stringish(other), do: to_string(other)

  defp int_or(n, _) when is_integer(n), do: n

  defp int_or(s, d) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> d
    end
  end

  defp int_or(_, d), do: d

  # Drop nil/"" values so a component sees a clean row (its own logic omits
  # absent segments).
  defp prune(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end
end
