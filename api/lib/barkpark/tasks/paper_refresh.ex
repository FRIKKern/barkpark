defmodule Barkpark.Tasks.PaperRefresh do
  @moduledoc """
  Task transition → paper cache-bust (tlv-bl-web-task-cache-bust).

  A paper whose task block carries a `query` is resolved at READ time
  (`?resolve=tasks` → `Papers.resolve_tasks_in_blocks/3`), so the paper
  DOCUMENT never changes when one of its tasks moves — and the web front's
  paper cache (`unstable_cache`, 300 s, tagged `bp:ds:<ds>:type:paper` +
  `bp:ds:<ds>:_all`) is only ever busted by a webhook. Task CAS writes
  (claim/close/stamp/release/…) reach PubSub only (`Tasks.Internal.emit_broadcasts/1`
  → `Content.broadcast_document_mutation/3`), never the webhook path, so a
  claimed task kept reading `ready` on the public paper for up to five minutes.

  This module closes that gap with a DEPENDENCY test, not a blanket bust:

      task CAS commit
        └─ emit_broadcasts/1 ─ notify/1 (off the request path)
             ├─ candidate task ids = the written tasks ∪ (for a transition that can
             │    enter/leave `done`) their `blocks` dependents — closing a blocker
             │    flips a dependent `open`→`ready` with no broadcast of its own
             ├─ candidate papers  = GIN-prefiltered papers holding a task block
             │    (`content @@ <jsonpath>` on `documents_content_path_idx`)
             ├─ per paper: TaskResolver.query_maps/1 → Tasks.Query.references_any?/4
             │    (the read's own query builder, status predicate relaxed)
             └─ ≥1 referencing paper → Webhooks.Dispatcher.dispatch_async/7
                  ("update", type "paper") — web busts type:paper + _all
                0 referencing papers → nothing dispatched (the negative control)

  Fail-open: every failure is logged and swallowed — a task write never waits
  on, or fails because of, a paper refresh.

  ## Bounds

    * Heartbeat kinds (`task.pulse`, `task.lease_renewed`) change nothing a task
      row renders (title/status/priority/worker/criteria/phase/draft) and are
      skipped before any query runs — they are the bulk of CAS traffic.
    * The paper scan is index-backed and capped (`@paper_scan_cap`); block
      nesting is prefiltered to `@max_depth` container levels (children /
      blocks / columns). A task block nested deeper than that is not seen by
      the prefilter and falls back to the web's 300 s safety net.
    * One `EXISTS` per DISTINCT query map, each restricted to the candidate
      task ids by primary key.

  ## Event identity

  The dispatch reuses the task transition's own `mutation_events.id` as its
  delivery id — it is the true cause, it is unique per transition, and the
  `UNIQUE(endpoint_id, event_id)` dedup therefore still holds. One dispatch per
  referencing paper DATASET (the web busts `type:paper` and `_all`, so one
  delivery refreshes every paper in that dataset).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Barkpark.Content.{Document, DraftId, Papers}
  alias Barkpark.PortableDoc.TaskResolver
  alias Barkpark.Repo
  alias Barkpark.Tasks.{Edge, Query}
  alias Barkpark.Webhooks.Dispatcher

  @event "update"
  @paper_type "paper"
  @heartbeat_kinds ~w(task.pulse task.lease_renewed)
  # Kinds that cannot move a task into or out of `done` — the only change that
  # alters a DEPENDENT's row (`dependency_count` counts not-`done` blockers).
  # Everything else (close, stage, landed, discharged, the unblock cascade, …)
  # also pulls in the task's `blocks` dependents.
  @done_neutral_kinds ~w(task.claimed task.released task.criterion task.relabeled task.referenced task.lease_expired)
  @paper_scan_cap 500
  @max_depth 2

  # The GIN-indexable prefilter: `$.blocks[*]…type == "<task block type>"` for
  # every task block type `TaskResolver` resolves, at every container nesting
  # up to `@max_depth`. `jsonb_path_ops` indexes `chain == constant` clauses, so
  # this is a bitmap index scan, not a detoast of every paper (measured:
  # 0.05 ms index scan vs 23 ms seq `$.**` walk over 20k rows).
  @containers ["children[*]", "blocks[*]", "columns[*][*]"]
  @chains Enum.reduce(1..@max_depth, [["blocks[*]"]], fn _, [prev | _] = acc ->
            [for(p <- prev, c <- @containers, do: p <> "." <> c) | acc]
          end)
          |> List.flatten()
          |> Enum.sort()
  @prefilter @chains
             |> Enum.flat_map(fn chain ->
               for t <- TaskResolver.unavailable_types(), do: ~s($.#{chain}.type == "#{t}")
             end)
             |> Enum.join(" || ")

  @doc false
  def prefilter_jsonpath, do: @prefilter

  @doc """
  Announce `broadcasts` (the `Tasks.Internal.task_broadcast/4` bundles a CAS
  verb emits after commit) to every paper whose task query references them.
  Runs on `Barkpark.TaskSupervisor` by default; `config :barkpark,
  :task_paper_refresh` selects `:async` (default), `:sync` (inline — tests that
  assert the dispatch), or `:off`. Always returns `:ok`.
  """
  @spec notify([map()]) :: :ok
  def notify(broadcasts) when is_list(broadcasts) do
    case Enum.reject(broadcasts, &heartbeat?/1) do
      [] ->
        :ok

      relevant ->
        case mode() do
          :off ->
            :ok

          :sync ->
            safe_refresh(relevant)

          _async ->
            try do
              {:ok, _pid} =
                Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
                  safe_refresh(relevant)
                end)

              :ok
            rescue
              e -> log_failure(e)
            catch
              kind, reason -> log_failure({kind, reason})
            end
        end
    end
  end

  def notify(_), do: :ok

  @doc """
  The synchronous core: returns the dispatches made, one
  `%{dataset:, doc_id:, event_id:, papers:}` per referencing paper dataset
  (`[]` when no paper references any written task — nothing dispatched).
  """
  @spec refresh([map()]) :: [map()]
  def refresh(broadcasts) when is_list(broadcasts) do
    broadcasts
    |> Enum.reject(&heartbeat?/1)
    |> Enum.filter(&match?(%{doc: %Document{workspace_id: ws}} when is_binary(ws), &1))
    |> Enum.group_by(& &1.doc.workspace_id)
    |> Enum.flat_map(fn {ws_id, group} -> refresh_workspace(ws_id, group) end)
  end

  defp refresh_workspace(ws_id, [first | _] = group) do
    task_ids = candidate_task_ids(group)
    scope = [workspace_id: ws_id]

    referencing =
      ws_id
      |> candidate_papers()
      |> Enum.reduce({[], %{}}, fn paper, {hits, memo} ->
        {hit?, memo} = references?(paper, scope, task_ids, memo)
        {if(hit?, do: [paper | hits], else: hits), memo}
      end)
      |> elem(0)

    referencing
    |> Enum.group_by(&dispatch_key(&1, ws_id))
    |> Enum.sort()
    |> Enum.map(fn {{dataset, project_id}, papers} ->
      doc_id = papers |> Enum.map(&DraftId.published_id(&1.doc_id)) |> Enum.min()

      Dispatcher.dispatch_async(dataset, @event, @paper_type, doc_id, nil, first.event_id,
        workspace_id: ws_id,
        project_id: project_id
      )

      %{
        dataset: dataset,
        doc_id: doc_id,
        event_id: first.event_id,
        papers: papers |> Enum.map(& &1.doc_id) |> Enum.sort()
      }
    end)
  end

  # Webhook selection is ALWAYS scoped to the TASK's workspace: a shared-layer
  # (nil-workspace) paper still only reveals this tenant's transition to this
  # tenant's endpoints. The paper's project narrows it when the paper lives in
  # that same workspace.
  defp dispatch_key(%{workspace_id: ws_id} = paper, ws_id), do: {paper.dataset, paper.project_id}
  defp dispatch_key(paper, _ws_id), do: {paper.dataset, nil}

  defp candidate_task_ids(group) do
    ids = group |> Enum.map(& &1.doc.id) |> Enum.uniq()

    blockers =
      group
      |> Enum.reject(&(&1.kind in @done_neutral_kinds))
      |> Enum.map(& &1.doc.id)
      |> Enum.uniq()

    Enum.uniq(ids ++ dependents_of(blockers))
  end

  defp dependents_of([]), do: []

  defp dependents_of(ids) do
    Repo.all(
      from(e in Edge,
        where: e.to_id in ^ids and e.kind == "blocks",
        select: e.from_id,
        distinct: true
      )
    )
  end

  # Papers a reader in `ws_id` can resolve this tenant's tasks on: the
  # workspace's own and the shared layer. Only `content->'blocks'` is fetched,
  # and only for rows the GIN prefilter admits.
  defp candidate_papers(ws_id) do
    from(d in Document,
      where:
        d.type == @paper_type and
          (d.workspace_id == ^ws_id or is_nil(d.workspace_id)) and
          fragment("? @@ ?::text::jsonpath", d.content, ^@prefilter),
      order_by: [asc: d.doc_id],
      limit: @paper_scan_cap,
      select: %{
        doc_id: d.doc_id,
        dataset: d.dataset,
        workspace_id: d.workspace_id,
        project_id: d.project_id,
        blocks: fragment("?->'blocks'", d.content)
      }
    )
    |> Repo.all()
  end

  defp references?(paper, scope, task_ids, memo) do
    {rows, aggs} = TaskResolver.query_maps(paper.blocks)

    probes =
      Enum.map(rows, &{:rows, Papers.task_query_dataset(&1, paper.dataset)}) ++
        Enum.map(aggs, &{:agg, Papers.task_query_dataset(&1, paper.dataset)})

    Enum.reduce_while(probes, {false, memo}, fn probe, {_, memo} ->
      {hit?, memo} =
        case Map.fetch(memo, probe) do
          {:ok, hit?} ->
            {hit?, memo}

          :error ->
            {class, query} = probe
            hit? = Query.references_any?(query, class, scope, task_ids)
            {hit?, Map.put(memo, probe, hit?)}
        end

      if hit?, do: {:halt, {true, memo}}, else: {:cont, {false, memo}}
    end)
  end

  defp heartbeat?(%{kind: kind}), do: kind in @heartbeat_kinds
  defp heartbeat?(_), do: true

  defp safe_refresh(broadcasts) do
    started = System.monotonic_time(:microsecond)
    dispatched = refresh(broadcasts)

    :telemetry.execute(
      [:barkpark, :tasks, :paper_refresh],
      %{
        duration_us: System.monotonic_time(:microsecond) - started,
        dispatched: length(dispatched)
      },
      %{kinds: Enum.map(broadcasts, & &1.kind), dispatches: dispatched}
    )

    :ok
  rescue
    e -> log_failure(e)
  catch
    kind, reason -> log_failure({kind, reason})
  end

  defp log_failure(reason) do
    Logger.warning("task_paper_refresh_failed reason=#{inspect(reason)}")
    :ok
  end

  defp mode, do: Application.get_env(:barkpark, :task_paper_refresh, :async)
end
