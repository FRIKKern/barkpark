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

  @doc """
  Walk `blocks`, resolving every task block that carries a `query`. `fetch` is
  any `(query_map -> [row])` function. A block with a literal `snapshot`/`task`
  and no `query` is left untouched (author-pinned rows still work offline).
  """
  def resolve(blocks, fetch) when is_list(blocks) and is_function(fetch, 1) do
    Enum.map(blocks, &resolve_block(&1, fetch))
  end

  def resolve(blocks, _fetch), do: blocks

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

  defp resolve_block(%{"type" => type, "query" => query} = block, fetch)
       when type in @snapshot_types and is_map(query) do
    rows = query |> fetch.() |> List.wrap()

    block
    |> Map.put("snapshot", rows)
    |> Map.delete("query")
  end

  defp resolve_block(%{"type" => @detail_type, "query" => query} = block, fetch)
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

  # A container block (columns/section/…) can nest task blocks in `children`.
  defp resolve_block(%{"children" => children} = block, fetch) when is_list(children) do
    Map.put(block, "children", resolve(children, fetch))
  end

  defp resolve_block(block, _fetch), do: block

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
