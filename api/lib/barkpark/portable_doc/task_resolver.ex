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
