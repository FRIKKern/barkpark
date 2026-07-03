defmodule Barkpark.Tasks.Claim do
  @moduledoc false
  # Task claim primitives, extracted from the Barkpark.Tasks facade (which
  # defdelegates claim/2 + claim_by_id/3 here): the queue-based atomic claim, the
  # targeted by-doc_id claim, resource-claim overlap scan, and the shared
  # do_claim CAS writer. Rides Tasks.Queue.ready_query/1 + Tasks.Internal.

  import Ecto.Query, only: [from: 2]

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      current_epoch: 1,
      insert_mutation_event!: 3,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Content.Document
  alias Barkpark.Content.Scope
  alias Barkpark.Repo
  alias Barkpark.Tasks.{Edges, Queue}

  @event_task_claimed "task.claimed"
  @ready_lifecycle_statuses ~w(open blocked)

  def claim(worker_id, opts \\ []) when is_binary(worker_id) do
    result =
      Repo.transaction(fn ->
        case opts
             |> Queue.ready_query()
             |> from(limit: 1, lock: "FOR UPDATE SKIP LOCKED")
             |> Repo.one() do
          nil ->
            {:ok, nil}

          %Document{} = doc ->
            do_claim(doc, worker_id)
        end
      end)

    case result do
      {:ok, {:ok, nil}} ->
        {:ok, nil}

      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def claim_by_id(doc_id, worker_id, opts \\ [])
      when is_binary(doc_id) and is_binary(worker_id) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    resources = opts |> Keyword.get(:resources, []) |> normalize_resources()

    result =
      Repo.transaction(fn ->
        # Advisory lock (per-doc_id) — serializes concurrent targeted claims for
        # the same row; keyed off doc_id (unique within tenancy) since we don't
        # yet know the uuid. Resource-carrying claims ALSO take a global
        # resources lock so two concurrent claims of different tasks cannot both
        # pass the overlap scan and land conflicting resource sets.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:" <> doc_id])

        if resources != [] do
          _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task-resources"])
        end

        with {:ok, doc} <- fetch_task_by_doc_id(doc_id, workspace_id, project_id),
             :ok <- check_ready_for_targeted_claim(doc),
             :ok <- check_deps_satisfied(doc),
             :ok <- check_resources_free(resources, doc.id, workspace_id, project_id) do
          do_claim(doc, worker_id, resources)
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Everything is a task: the TARGETED claim_by_id path fetches by doc_id on
  # `type == "task"`. Resolution: try the exact doc_id first; when no row is
  # found AND the caller did NOT supply a `drafts.` prefix, retry with
  # `"drafts." <> doc_id` (tasks created via mutate land as drafts.<id>). An
  # explicit `drafts.` prefix is exact — the fallback is never applied in
  # reverse. If both `t1` and `drafts.t1` exist, the exact `t1` match wins.
  defp fetch_task_by_doc_id(doc_id, workspace_id, project_id) do
    case fetch_task_exact_locked(doc_id, workspace_id, project_id) do
      {:ok, _} = hit ->
        hit

      {:error, :not_found} ->
        if String.starts_with?(doc_id, "drafts.") do
          {:error, :not_found}
        else
          fetch_task_exact_locked("drafts." <> doc_id, workspace_id, project_id)
        end
    end
  end

  defp fetch_task_exact_locked(doc_id, workspace_id, project_id) do
    base =
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type == "task",
        lock: "FOR UPDATE"
      )

    # Tenancy: route through the ONE shared helper (fail-CLOSED on nil) so the
    # targeted-claim fetch shares the exact workspace/project semantics as the
    # ready-queue path (Queue.ready_query → Scope.scope_to_workspace). A nil
    # workspace_id yields zero rows, never every tenant's rows.
    query = Scope.scope_to_workspace(base, workspace_id, project_id)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Document{} = doc -> {:ok, doc}
    end
  end

  defp check_ready_for_targeted_claim(%Document{content: content}) do
    case Map.get(content || %{}, "lifecycle_status") do
      s when s in @ready_lifecycle_statuses -> :ok
      _ -> {:error, :not_ready}
    end
  end

  defp check_deps_satisfied(%Document{} = doc) do
    deps = Edges.dependencies(doc.id, kind: :blocks)

    all_done? =
      Enum.all?(deps, fn %Document{content: c} ->
        Map.get(c || %{}, "lifecycle_status") == "done"
      end)

    if all_done?, do: :ok, else: {:error, :blocked_by_unsatisfied_deps}
  end

  # Resource claims (the Beads file-claim successor): a targeted claim may carry
  # `resources: ["a.go", …]` (opaque strings, exact-match). The overlap scan
  # refuses with `resource_conflict` + holders when any requested string is held
  # by another LIVE (in_progress) claim in the same tenancy. Resources live
  # INSIDE content.claim, so close + the TTL sweep free them for free.

  # Accepts a list, or a single comma-separated string (what
  # `bp task claim … --set resources=a.go,b.go` delivers).
  defp normalize_resources(resources) when is_binary(resources),
    do: resources |> String.split(",") |> normalize_resources()

  defp normalize_resources(resources) when is_list(resources) do
    resources
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_resources(_), do: []

  defp check_resources_free([], _doc_uuid, _workspace_id, _project_id), do: :ok

  defp check_resources_free(resources, doc_uuid, workspace_id, project_id) do
    holders =
      from(d in Document,
        where: d.type == "task" and d.id != ^doc_uuid,
        where: fragment("?->>'lifecycle_status'", d.content) == "in_progress",
        where: fragment("jsonb_exists_any(?->'claim'->'resources', ?)", d.content, ^resources),
        select: %{doc_id: d.doc_id, content: d.content}
      )
      # Same shared, fail-CLOSED tenancy helper as the fetch above — the
      # resource-overlap scan is bounded to the caller's workspace/project, and
      # a nil workspace_id scans NOTHING (safe default) rather than all tenants.
      |> Scope.scope_to_workspace(workspace_id, project_id)
      |> Repo.all()

    case holders do
      [] ->
        :ok

      holders ->
        conflicts =
          Enum.map(holders, fn %{doc_id: did, content: c} ->
            claim = Map.get(c || %{}, "claim") || %{}
            held = Map.get(claim, "resources") || []

            %{
              doc_id: did,
              worker: Map.get(claim, "worker"),
              resources: Enum.filter(resources, &(&1 in held))
            }
          end)

        {:error, {:resource_conflict, conflicts}}
    end
  end

  defp do_claim(%Document{} = doc, worker_id, resources \\ []) do
    observed_rev = doc.rev
    new_rev = generate_rev()
    next_epoch = current_epoch(doc) + 1
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    new_claim =
      %{
        "worker" => worker_id,
        "ts_iso" => ts_iso,
        "epoch" => next_epoch
      }
      |> then(fn claim ->
        if resources == [], do: claim, else: Map.put(claim, "resources", resources)
      end)

    new_content =
      doc.content
      |> Map.put("lifecycle_status", "in_progress")
      |> Map.put("assignee", worker_id)
      |> Map.put("claim", new_claim)

    {rows, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
      |> Repo.update_all(
        set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
      )

    case rows do
      1 ->
        updated = %{doc | content: new_content, rev: new_rev}
        ev = insert_mutation_event!(updated, @event_task_claimed, observed_rev)
        {:ok, updated, [task_broadcast(updated, @event_task_claimed, ev, observed_rev)]}

      0 ->
        {:error, :stale_claim}
    end
  end
end
