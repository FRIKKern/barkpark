defmodule Barkpark.Tasks.Move do
  @moduledoc false
  # rail-l3 — re-parent a task (change `content.parent_id`), the structural
  # counterpart to the `relabel`/`reference` single-field mutations. A move
  # rides the SAME advisory-lock + CAS-on-rev + durable mutation_event +
  # post-commit broadcast shape as `Tasks.Mutations.relabel_by_id/3`, differing
  # only in WHICH key it writes (`parent_id`, set OR removed for a root move)
  # and the event kind (`task.reparented`, carrying `{from, to}`).
  #
  # ## Rail-rev interplay (no bump plumbing)
  #
  # A move changes the membership of TWO rails — the source parent's and the
  # destination parent's. Neither needs a stored-counter bump: `Tasks.Rail.rev/2`
  # recomputes each digest on demand from the substrate, so the membership flip
  # flips both digests automatically. The controller reads them back AFTER the
  # write as `rail_rev` (destination) + `from_rail_rev` (source).
  #
  # ## Guards
  #
  #   * **existence + type** — resolving the new parent is the caller's job
  #     (`find_task_by_doc_id` → `invalid_parent`); this module trusts the
  #     passed `new_parent_doc_id` is a real task's doc_id (or nil for root).
  #   * **cycle** — a task may not move under itself or any of its own
  #     descendants. `cycle?/2` walks the destination's ancestor chain; if the
  #     moving task appears anywhere in it (or IS the destination), the move is
  #     refused with `{:error, :cycle}`.
  #   * **no-op** — moving to the parent the task already has (prefix-agnostic)
  #     is idempotent: `{:ok, doc}` with NO write, NO event (the rail did not
  #     change, so there is nothing to announce).
  #
  # ## rail-l4 fence (allow-and-fence)
  #
  # Moving an `in_progress` task mutates its world, so the reparent CAS write
  # ALSO bumps `content.claim.epoch` by 1 (folded into the one UPDATE, not a
  # second write) and the `task.reparented` event notes `"fenced" =>
  # "reparented"`. The mover is NEVER rejected; the holder's old-epoch `close`
  # is now `fenced_off` and it recovers via a same-worker re-claim (renewal,
  # see `Barkpark.Tasks.Claim`). Only the epoch moves — work_digest/worker/
  # ts_iso stay as the holder stamped them.
  #
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

  alias Barkpark.Content.{Document, DraftId, Scope}
  alias Barkpark.Repo

  @event_task_reparented "task.reparented"

  # A pre-existing parent_id cycle in the data can't loop us forever.
  @max_ancestor_walk 1000

  @doc """
  Re-parent the task identified by `task_uuid` (`documents.id`) under
  `new_parent_doc_id` (a task's `doc_id` string), or to the root when
  `new_parent_doc_id` is nil (the `parent_id` key is REMOVED, not set to nil).

  Returns `{:ok, doc}` on a successful move (or an idempotent no-op),
  `{:error, :not_found}`, `{:error, :cycle}`, or `{:error, :stale_claim}`.
  """
  @spec move(binary(), binary() | nil, binary() | nil) ::
          {:ok, Document.t()} | {:error, :not_found | :cycle | :stale_claim}
  def move(task_uuid, new_parent_doc_id, caller_token_id \\ nil)
      when is_binary(task_uuid) and (is_binary(new_parent_doc_id) or is_nil(new_parent_doc_id)) do
    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_uuid}"])

        case Repo.get(Document, task_uuid) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            old_parent = parent_id_of(doc.content)

            cond do
              same_parent?(old_parent, new_parent_doc_id) ->
                # Idempotent: the rail did not change — no write, no event.
                {:noop, doc}

              cycle?(doc, new_parent_doc_id) ->
                {:error, :cycle}

              true ->
                do_move(doc, old_parent, new_parent_doc_id, caller_token_id)
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:noop, doc}} ->
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_move(%Document{} = doc, old_parent, new_parent_doc_id, caller_token_id) do
    observed_rev = doc.rev
    new_rev = generate_rev()

    reparented =
      case new_parent_doc_id do
        nil -> Map.delete(doc.content, "parent_id")
        pid -> Map.put(doc.content, "parent_id", pid)
      end

    # rail-l4 allow-and-fence: an `in_progress` task's world just changed, so
    # bump its claim epoch in the SAME CAS write (never a second UPDATE) — the
    # holder's old-epoch close is now fenced_off and must resync. Only the epoch
    # moves; work_digest/worker/ts_iso stay as the holder stamped them.
    {new_content, fenced?} = maybe_fence(reparented, doc)

    # PDS-D451: the receipt is the STORED row. NOTE the NOOP arm above
    # (`same_parent?` -> `{:noop, doc}`) is DELIBERATELY not routed here — it
    # performs no write at all, and giving it one would destroy the family's
    # one proven-honest receipt.
    case fenced_content_write(doc, observed_rev, new_content, new_rev) do
      {:ok, updated} ->
        ev =
          insert_mutation_event!(
            updated,
            @event_task_reparented,
            observed_rev,
            "api",
            Map.merge(
              reparent_payload(old_parent, new_parent_doc_id, fenced?),
              caller_stamp(caller_token_id)
            )
          )

        {:ok, updated, [task_broadcast(updated, @event_task_reparented, ev, observed_rev)]}

      :stale ->
        {:error, :stale_claim}
    end
  end

  # Fold the fencing epoch bump into the reparent write when the moved task is a
  # live claim. Returns `{new_content, fenced?}`.
  defp maybe_fence(content, %Document{} = doc) do
    case content do
      %{"lifecycle_status" => "in_progress", "claim" => claim} when is_map(claim) ->
        bumped = Map.put(claim, "epoch", current_epoch(doc) + 1)
        {Map.put(content, "claim", bumped), true}

      _ ->
        {content, false}
    end
  end

  # The task.reparented document payload — always {from, to}; when the move also
  # fenced a live claim, note it so the event stream shows why the epoch moved.
  defp reparent_payload(old_parent, new_parent_doc_id, fenced?) do
    base = %{"reparented" => %{"from" => old_parent, "to" => new_parent_doc_id}}
    if fenced?, do: Map.put(base, "fenced", "reparented"), else: base
  end

  # ─── cycle detection ─────────────────────────────────────────────────────

  # A cycle iff the moving task IS the destination or an ANCESTOR of it — i.e.
  # the destination is the moving task or one of its descendants. Walk the
  # destination's ancestor chain (destination first, then up via parent_id) and
  # look for the moving task's (prefix-agnostic) doc_id.
  defp cycle?(_doc, nil), do: false

  defp cycle?(%Document{} = doc, new_parent_doc_id) do
    base_self = strip(doc.doc_id)

    new_parent_doc_id
    |> ancestor_chain(doc.workspace_id, doc.project_id)
    |> Enum.any?(fn a -> strip(a) == base_self end)
  end

  # doc_ids of the chain STARTING AT `doc_id` and walking up via parent_id, to
  # the root. Guards a pre-existing data cycle (seen-set + depth cap). A missing
  # ancestor row terminates the walk (still counting the id we were chasing).
  defp ancestor_chain(doc_id, workspace_id, project_id),
    do: ancestor_chain(doc_id, workspace_id, project_id, MapSet.new(), 0)

  defp ancestor_chain(nil, _ws, _proj, _seen, _depth), do: []

  defp ancestor_chain(doc_id, ws, proj, seen, depth) when depth < @max_ancestor_walk do
    key = strip(doc_id)

    if MapSet.member?(seen, key) do
      []
    else
      case fetch_ancestor(doc_id, ws, proj) do
        nil ->
          [doc_id]

        %{doc_id: aid, parent_id: pid} ->
          [aid | ancestor_chain(pid, ws, proj, MapSet.put(seen, key), depth + 1)]
      end
    end
  end

  defp ancestor_chain(_doc_id, _ws, _proj, _seen, _depth), do: []

  # Resolve one ancestor by its (prefix-agnostic) doc_id within the task's
  # tenancy, returning `%{doc_id, parent_id}`. A published+draft twin can both
  # match the stripped id — take the first (either resolves the same chain link).
  defp fetch_ancestor(doc_id, ws, proj) do
    base = strip(doc_id)

    from(d in Document,
      where: d.type == "task",
      where: fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id) == ^base,
      select: %{doc_id: d.doc_id, parent_id: fragment("?->>'parent_id'", d.content)},
      limit: 1
    )
    |> Scope.scope_to_workspace(ws, proj)
    |> Repo.all()
    |> List.first()
  end

  # ─── parent helpers ──────────────────────────────────────────────────────

  defp parent_id_of(content) when is_map(content) do
    case Map.get(content, "parent_id") do
      p when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  defp parent_id_of(_), do: nil

  # Prefix-agnostic same-rail test (the `drafts.` twin shares a rail, per
  # `Tasks.Rail`). Both nil (root→root) is a no-op too.
  defp same_parent?(nil, nil), do: true
  defp same_parent?(nil, _), do: false
  defp same_parent?(_, nil), do: false
  defp same_parent?(a, b), do: strip(a) == strip(b)

  defp strip(doc_id), do: DraftId.published_id(doc_id)
end
