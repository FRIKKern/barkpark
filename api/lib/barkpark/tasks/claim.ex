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
      fenced_content_write: 4,
      current_epoch: 1,
      insert_mutation_event!: 5,
      caller_stamp: 1,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Content.Document
  alias Barkpark.Content.Scope
  alias Barkpark.Repo
  alias Barkpark.Tasks.CriteriaExemption
  alias Barkpark.Tasks.DependencySatisfaction
  alias Barkpark.Tasks.{Edges, ExecutionPolicy, Queue, QueueGate, Validation, WorkDigest}

  @event_task_claimed "task.claimed"
  # Derived at compile time from the ONE claimability source of truth
  # (Validation.claimable_statuses/0 — ~w(open blocked)); never fork a local
  # literal. Keeps `check_ready_for_targeted_claim/1` in lockstep with the
  # ready-queue allowlist in Tasks.Queue.
  @ready_lifecycle_statuses Validation.claimable_statuses()

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
            do_claim(doc, worker_id, [], opts)
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

  # The RESOURCE fence (`--resources`) — NOT the epoch fence. `Tasks.Fence` and
  # `Tasks.ClaimFence` own the epoch/lease fence, so a cold `grep fence` lands
  # there and never finds this. This is the one that refuses with
  # `resource_conflict`.
  # @canonical capability:task-resource-fence aka:resources,resource_conflict,fence,claim fence,--resources,resource overlap,holders doc:docs/setup/TASK-SYSTEM.md
  def claim_by_id(doc_id, worker_id, opts \\ [])
      when is_binary(doc_id) and is_binary(worker_id) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    resources = opts |> Keyword.get(:resources, []) |> normalize_resources()
    caller_token_id = Keyword.get(opts, :caller_token_id)

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

        case fetch_task_by_doc_id(doc_id, workspace_id, project_id) do
          {:error, :not_found} = err ->
            err

          {:ok, doc} ->
            # rail-l4: a targeted claim on an in_progress task by the SAME
            # worker that holds it is a lease RENEWAL, not a conflict — the
            # recovery path after a fence bump. A DIFFERENT worker falls through
            # to check_ready and still gets :not_ready.
            if renewal?(doc, worker_id) do
              with :ok <- check_executable_for_targeted_claim(doc, worker_id),
                   :ok <- validate_renewal_execution_policy(doc, opts) do
                do_renew(doc, worker_id, caller_token_id)
              end
            else
              with :ok <- check_executable_for_targeted_claim(doc, worker_id),
                   :ok <- check_ready_for_targeted_claim(doc),
                   :ok <- check_criteria_stated(doc, opts),
                   :ok <- check_deps_satisfied(doc),
                   :ok <- check_resources_free(resources, doc.id, workspace_id, project_id) do
                do_claim(doc, worker_id, resources, opts)
              end
            end
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

  # ── THE SECOND FORK (task-ca05dd6a02a0b55f) ─────────────────────────────
  #
  # `documents` is unique on `(doc_id, type, dataset_id)`, NOT on
  # `(doc_id, type)` (migration 20260527134000). One task doc_id can therefore
  # live in TWO datasets in a single workspace/project, and this lookup carries
  # no dataset discriminator by design — `bp task claim <id>` names no dataset.
  # Without a `limit`, that shape made `Repo.one/1` raise
  # `Ecto.MultipleResultsError`, i.e. a 500 on every attempt, forever.
  #
  # PR #15551 fixed exactly this in the READ path (`fetch_task_exact/3` in
  # tasks_controller.ex) and did not find this fork, so three days later
  # `bp task get akbr-feedback-2026-08-epic` resolved while
  # `bp task claim akbr-feedback-2026-08-epic` still 500'd (measured against
  # guerrilla 2026-09-05, request_id GNJljRgMcPdcwAYAABsC). A row that cannot be
  # CLAIMED cannot be stamped, closed or released either — every one of those
  # verbs is claim-fenced — so this one function kept the eleven known
  # cross-dataset rows exactly as unreachable as before the read was fixed.
  #
  # The order is the rule `Content.Graph.resolve_doc/3`
  # (`@canonical capability:slug-resolve`) and `fetch_task_exact/3` already
  # spell, and it is TOTAL — published-first, then dataset, then id — so the
  # same call returns the same row across every pooled connection. A partial
  # order would trade a 500 for a silently alternating answer, which is worse.
  #
  # `FOR UPDATE` is preserved: this is the targeted-claim path and the row lock
  # is what makes the claim a CAS. A fix that dropped it would trade a 500 for
  # a lost update.
  defp fetch_task_exact_locked(doc_id, workspace_id, project_id) do
    base =
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type == "task",
        order_by: [
          asc: fragment("CASE WHEN ? = 'published' THEN 0 ELSE 1 END", d.status),
          asc: d.dataset,
          asc: d.id
        ],
        limit: 1,
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

  # ── THE CLAIM-TIME CRITERIA DOOR (task-9554c64bf51a0f81) ─────────────────
  #
  # A row with zero acceptance criteria is one whose done state can be attested
  # ONLY by artifact and never by criterion. The artifact says something
  # landed; it cannot say what the row was FOR.
  #
  # The close door already refuses that (`check_close_artifact/5`), and by then
  # it is too late BY CONSTRUCTION: the work is finished, so the criteria that
  # would have defined success get written after the fact by whoever is trying
  # to get the row shut, if they get written at all. At CLAIM time they still
  # SHAPE the work. That is the whole argument for a second door, and it does
  # not weaken the first.
  #
  # WHY A REFUSAL AND NOT A WARNING. The platform already ran that experiment:
  # `Plugins.Tasks.warn_if_create_zero/1` is a soft `Logger.warning` on a
  # zero-criteria task, it fired on 9 of 11 births and changed nothing, because
  # its only reader is the server journal (close.ex records this verbatim). A
  # second warning would be the same instrument aimed at the same blind spot.
  # So this refuses in the same D288/D289 idiom the sibling gate uses: refuse
  # UNLESS you say why on the record, never a wall.
  #
  # A RENEWAL IS NEVER REFUSED. This sits only in the non-renewal branch: a
  # worker re-claiming a row it already holds is recovering a lease after a
  # fence bump, and refusing that would strand live work behind a paperwork
  # gate. The door belongs where work STARTS.
  #
  # The exemptions come from `Tasks.CriteriaExemption`, the same definition the
  # close door reads, so the two cannot drift about what a container is.
  defp check_criteria_stated(%Document{} = doc, opts) do
    cond do
      CriteriaExemption.exempt?(doc) -> :ok
      override_given?(opts) -> :ok
      true -> {:error, :criteria_unstated}
    end
  end

  defp override_given?(opts) do
    case Keyword.get(opts, :criteria_unstated_override) do
      reason when is_binary(reason) -> String.trim(reason) != ""
      _ -> false
    end
  end

  defp check_ready_for_targeted_claim(%Document{content: content}) do
    case Map.get(content || %{}, "lifecycle_status") do
      s when s in @ready_lifecycle_statuses -> :ok
      _ -> {:error, :not_ready}
    end
  end

  defp check_executable_for_targeted_claim(%Document{content: content}, worker_id) do
    if QueueGate.executable?(content, worker_id), do: :ok, else: {:error, :not_ready}
  end

  defp check_deps_satisfied(%Document{} = doc) do
    deps = Edges.dependencies(doc.id, kind: :blocks)

    # cch-w3-task-birth-attribution: a blocker must be done AND attributable.
    # `lifecycle_status` alone is forgeable by a fresh create, which births are
    # structurally exempt from guarding — so the check moved to the READ side.
    # ONE definition, three call sites; see Tasks.DependencySatisfaction.
    all_done? =
      Enum.all?(deps, fn %Document{content: c} ->
        DependencySatisfaction.satisfied?(c || %{})
      end)

    if all_done?, do: :ok, else: {:error, :blocked_by_unsatisfied_deps}
  end

  # Resource claims: a targeted claim may carry
  # `resources: ["a.go", …]` (opaque strings, exact-match). The overlap scan
  # refuses with `resource_conflict` + holders when any requested string is held
  # by another LIVE (in_progress) claim in the same tenancy. Resources live
  # INSIDE content.claim, so close + the TTL sweep free them for free.
  #
  # ─── RULING: when is a fenced resource freed? ──────────────────────────────
  # (task-fence-lifecycle-three-defects, 2026-09-02. Pinned by
  # `test/barkpark/tasks/fence_lifecycle_test.exs`.)
  #
  # The fence is held by the LIFECYCLE, not by the claim map. `A holds R` is
  # true iff A's `lifecycle_status` is exactly `"in_progress"` AND R is in
  # `A.content.claim.resources` — the two `where` clauses below, and nowhere
  # else. Consequences, each one a test:
  #
  #   * REFUSAL frees nothing because it takes nothing. The scan runs BEFORE
  #     `do_claim/4` inside the one `Repo.transaction`, and a `with` miss
  #     returns `{:error, {:resource_conflict, _}}` without ever reaching a
  #     write — the refused caller's row keeps its rev, its `"open"` status,
  #     and gains no `claim`/`assignee` key and no mutation_event.
  #   * CLOSE frees it, for every terminal status (done / cancelled / blocked)
  #     — the lifecycle leaves `"in_progress"`, so the scan stops seeing it.
  #     `Tasks.Close` deliberately KEEPS `claim.resources` on the map: on a
  #     terminal row it is audit ("what this work fenced"), not a live fence.
  #   * RELEASE frees it (lands `"open"`) and DELETES the key, because the row
  #     is claimable again and a live-looking fence on a claimable row is a lie.
  #   * REAP frees it identically — `TtlSweeper.apply_reap/1` is release's
  #     timeout twin and deletes the key for the same reason.
  #
  # Therefore there is NO unfreeable state: every path out of `in_progress` is
  # one of those four, and each one drops the fence. `Release.release/3`
  # refusing a terminal task with `{:not_in_progress, "done"}` is CORRECT and
  # is NOT a deadlock — release is a LEASE verb, and a done task has no lease
  # (and no fence) left to release. Do not "fix" it by letting release reopen
  # terminal rows; that would hand any caller a lifecycle rewind through a
  # cleanup verb, to free something already free.

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

  defp do_claim(%Document{} = doc, worker_id, resources, opts) do
    task_policy = Map.get(doc.content || %{}, "execution_policy")

    case ExecutionPolicy.resolve(
           Keyword.get(opts, :execution_policy_override),
           task_policy,
           Keyword.get(opts, :session_execution_policy),
           Keyword.get(opts, :provider_execution_policy)
         ) do
      {:ok, snapshot} ->
        do_claim_resolved(
          doc,
          worker_id,
          resources,
          Keyword.get(opts, :caller_token_id),
          snapshot
        )

      {:error, errors} ->
        {:error, {:invalid_execution_policy, errors}}
    end
  end

  # A renewal keeps the execution-policy snapshot frozen at the original
  # claim, but caller-supplied layers still have to satisfy the same strict
  # policy contract as a fresh claim. Resolve all four layers for validation
  # only, then deliberately discard the newly resolved snapshot so do_renew/3
  # preserves the existing claim.execution_policy value byte-for-byte.
  defp validate_renewal_execution_policy(%Document{} = doc, opts) do
    task_policy = Map.get(doc.content || %{}, "execution_policy")

    case ExecutionPolicy.resolve(
           Keyword.get(opts, :execution_policy_override),
           task_policy,
           Keyword.get(opts, :session_execution_policy),
           Keyword.get(opts, :provider_execution_policy)
         ) do
      {:ok, _snapshot} -> :ok
      {:error, errors} -> {:error, {:invalid_execution_policy, errors}}
    end
  end

  defp do_claim_resolved(%Document{} = doc, worker_id, resources, caller_token_id, snapshot) do
    observed_rev = doc.rev
    new_rev = generate_rev()
    next_epoch = current_epoch(doc) + 1
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    # Work digest over the task's work-defining fields AS READ in this claim
    # txn (title + content.brief + content.description + content.acceptance_criteria). Stamped
    # so close/3 can refuse a silent close if the brief was edited under the
    # claim — see Barkpark.Tasks.WorkDigest. Both claim paths land here, so both
    # get the stamp. The per-field companion map is what lets close name WHICH
    # fields drifted (changed_fields) without storing the field values verbatim.
    {work_digest, field_digests} = WorkDigest.stamp(doc.title, doc.content)

    new_claim =
      %{
        "worker" => worker_id,
        "ts_iso" => ts_iso,
        "epoch" => next_epoch,
        "work_digest" => work_digest,
        "work_field_digests" => field_digests
      }
      |> then(fn claim ->
        if resources == [], do: claim, else: Map.put(claim, "resources", resources)
      end)
      |> then(fn claim ->
        if is_nil(snapshot), do: claim, else: Map.put(claim, "execution_policy", snapshot)
      end)

    new_content =
      doc.content
      |> Map.put("lifecycle_status", "in_progress")
      |> Map.put("assignee", worker_id)
      |> Map.put("claim", new_claim)

    case fenced_content_write(doc, observed_rev, new_content, new_rev) do
      {:ok, updated} ->
        ev =
          insert_mutation_event!(
            updated,
            @event_task_claimed,
            observed_rev,
            "api",
            caller_stamp(caller_token_id)
          )

        {:ok, updated, [task_broadcast(updated, @event_task_claimed, ev, observed_rev)]}

      :stale ->
        {:error, :stale_claim}
    end
  end

  # rail-l4 renewal predicate: the task is a LIVE claim held by THIS caller.
  defp renewal?(%Document{content: content}, worker_id) do
    c = content || %{}

    Map.get(c, "lifecycle_status") == "in_progress" and
      get_in(c, ["claim", "worker"]) == worker_id
  end

  # rail-l4 lease RENEWAL — the recovery path. After a fence bump (a blocker
  # edge or a move landed on this claimed task) the holder is deadlocked: its
  # old-epoch `close` is `fenced_off`, and a fresh targeted claim would 409
  # `not_ready`. So a same-worker re-claim renews the lease instead: it bumps
  # the epoch and refreshes `ts_iso` (a lease keep-alive the TTL sweeper reads),
  # but DELIBERATELY keeps the ORIGINAL claim's `work_digest` +
  # `work_field_digests` untouched. Restamping the digest would silently
  # swallow a foreign brief edit that happened before the renewal — the whole
  # point of the L2 close-fence is to catch exactly that, so the renewed lease
  # must still `doc_changed_since_claim` at close if the brief really drifted.
  # Emits `task.claimed` (a renewal IS a claim) so the L1 envelope carries
  # rail_rev + notices (a renewal after an edge fence surfaces
  # blocked_while_claimed in the same response). Resources + worker are left
  # exactly as the live claim holds them.
  #
  # SIBLING: `Barkpark.Tasks.Pulse` mirrors this write (epoch bump + ts_iso
  # refresh, digest untouched) and adds the `claim.now` now-line — but as its
  # OWN path, holder-gated with NO re-claim fall-through: a lapsed lease must
  # pulse `:not_holder`, never silently re-claim through do_claim below.
  defp do_renew(%Document{content: content} = doc, worker_id, caller_token_id) do
    observed_rev = doc.rev
    new_rev = generate_rev()
    claim = Map.get(content, "claim") || %{}
    next_epoch = current_epoch(doc) + 1
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    new_claim =
      claim
      |> Map.put("epoch", next_epoch)
      |> Map.put("ts_iso", ts_iso)

    # Keep worker + assignee (already this caller). Only the claim lease moves.
    new_content =
      content
      |> Map.put("claim", new_claim)
      |> Map.put("assignee", worker_id)

    case fenced_content_write(doc, observed_rev, new_content, new_rev) do
      {:ok, updated} ->
        ev =
          insert_mutation_event!(
            updated,
            @event_task_claimed,
            observed_rev,
            "api",
            caller_stamp(caller_token_id)
          )

        {:ok, updated, [task_broadcast(updated, @event_task_claimed, ev, observed_rev)]}

      :stale ->
        {:error, :stale_claim}
    end
  end
end
