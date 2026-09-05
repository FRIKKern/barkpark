defmodule Barkpark.Tasks.EventsSharedOnlyScopeTest do
  @moduledoc """
  `Tasks.Events.replay_since/3` must honour the `:shared_only` empty-scope
  sentinel (task-5ca36b127acf9cbd; class task-3e2a70930c6df723).

  ## The defect

  `maybe_scope_workspace/2` was a `when is_binary(ws_id)` clause paired with a
  PERMISSIVE catch-all:

      defp maybe_scope_workspace(query, ws_id) when is_binary(ws_id),
        do: from(e in query, where: e.workspace_id == ^ws_id)

      defp maybe_scope_workspace(query, _), do: query

  `BarkparkWeb.ScopeHelpers.scope_opts/1` emits the ATOM `:shared_only`
  whenever an HTTP request resolved no workspace, and
  `TasksController.events/2` hands it straight through
  (`Keyword.get(scope_opts(conn), :workspace_id)`). The atom fails
  `is_binary/1`, fell into the catch-all, and the feed went workspace-BLIND:
  every co-dataset tenant's task mutations replayed to a caller with no
  resolved tenant.

  This is a FAIL-OPEN SHAPE, not a demonstrated leak. Reachability is low and
  the row says so honestly: every door into this read rides the `:api`
  pipeline, which carries `AssignDefaultScope`, so the atom only appears when
  the seeded Default workspace is ABSENT (fresh DB before backfill, after
  `DELETE /api/workspaces/default`, or the support-reset vacancy window). The
  guard shape is the bug; no exploitable leak is claimed.

  ## Why the arms are shaped this way

  Every row is minted under a dataset string UNIQUE to this module. The
  `mutation_events` table is written by every other suite — and, in this repo,
  by other agents against the same database — so a shared-dataset assertion
  would measure the neighbourhood, not the fixture.

  `(1)` is the INSTRUMENT SELF-TEST and PASSES BEFORE THE FIX: a real binary
  workspace id reaches the workspace clause and isolates. Without it, `(2)`'s
  red could be any upstream failure and this suite would prove nothing about
  the sentinel.

  `(2)` is the arm the fix earns. `(3)` pins the other direction — a predicate
  that excluded the workspace rows but ALSO emptied the shared layer would
  trade a fail-open for a blind feed. `(4)` proves `nil` is untouched: it is
  the deliberate global read for internal / back-compat callers, and widening
  or narrowing it is a DIFFERENT change.
  """

  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Tasks.Events

  setup do
    # Dataset string unique per run: two workspaces PLUS the shared
    # (NULL-workspace) layer all live under it, so isolation can only come from
    # workspace_id — never from the dataset leaf.
    dataset = "events-shared-only-#{System.unique_integer([:positive])}"

    ws_a = create_workspace!()
    ws_b = create_workspace!()

    owned_a = emit!(dataset, "task-owned-a", ws_a.id)
    owned_b = emit!(dataset, "task-owned-b", ws_b.id)
    shared = emit!(dataset, "task-shared", nil)

    %{
      dataset: dataset,
      ws_a: ws_a,
      ws_b: ws_b,
      owned_a: owned_a,
      owned_b: owned_b,
      shared: shared
    }
  end

  # A task mutation_event carrying an EXPLICIT workspace_id (or nil for the
  # shared layer) — the same row-local tenant column `replay_since/3` reads.
  # Written directly because a NULL-workspace document cannot be minted through
  # `Content.create_document/4`, and the boundary under test is the event
  # column, not the document.
  defp emit!(dataset, doc_id, workspace_id) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: dataset,
      type: "task",
      doc_id: doc_id,
      mutation: "task.claimed",
      rev: "rev-1",
      document: %{"doc_id" => doc_id},
      workspace_id: workspace_id,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp doc_ids(rows), do: Enum.map(rows, & &1.doc_id)

  describe "replay_since/3 workspace boundary" do
    test "(1) INSTRUMENT SELF-TEST — a binary workspace id isolates to that workspace", ctx do
      ids = doc_ids(Events.replay_since(ctx.dataset, 0, workspace_id: ctx.ws_a.id))

      assert ctx.owned_a.doc_id in ids,
             "fixture broken: A's own event is missing under A's scope, got #{inspect(ids)}"

      refute ctx.owned_b.doc_id in ids,
             "CROSS-TENANT: B's event surfaced under A's scope"

      refute ctx.shared.doc_id in ids
    end

    test "(2) :shared_only EXCLUDES every workspace-owned row", ctx do
      ids = doc_ids(Events.replay_since(ctx.dataset, 0, workspace_id: :shared_only))

      refute ctx.owned_a.doc_id in ids,
             "FAIL-OPEN: workspace A's task event replayed to an unresolved-tenant caller " <>
               "(:shared_only fell through the permissive catch-all), got #{inspect(ids)}"

      refute ctx.owned_b.doc_id in ids,
             "FAIL-OPEN: workspace B's task event replayed under :shared_only, got #{inspect(ids)}"
    end

    test "(3) :shared_only still RETURNS the shared (NULL-workspace) layer", ctx do
      ids = doc_ids(Events.replay_since(ctx.dataset, 0, workspace_id: :shared_only))

      assert ctx.shared.doc_id in ids,
             "the sentinel means the shared layer, not zero rows — got #{inspect(ids)}"

      assert ids == [ctx.shared.doc_id]
    end

    test "(4) nil is UNCHANGED — the explicit global read still sees everything", ctx do
      ids = doc_ids(Events.replay_since(ctx.dataset, 0, workspace_id: nil))

      assert ctx.owned_a.doc_id in ids
      assert ctx.owned_b.doc_id in ids
      assert ctx.shared.doc_id in ids
    end
  end
end
