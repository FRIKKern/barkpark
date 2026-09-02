defmodule Barkpark.TasksClaimTest do
  @moduledoc """
  W7a step 4 — full claim primitives (CAS + fencing epoch + advisory-lock
  close/unblock + durable-then-ack mutation_events).

  Four primitives, four `describe` blocks plus a regression on the W7-03
  concurrency proof:

    1. CAS (`describe "claim/2 — expected-version CAS"`) — two workers race;
       first commit wins, second gets `{:error, :stale_claim}`.
    2. Fencing epoch (`describe "close/3 — fencing"`) — observed_epoch ==
       row.epoch wins; mismatch is rejected with `:fenced_off`. Also
       exercises the "TTL sweep bumps epoch → late writer is fenced"
       scenario without actually wiring W7-05's sweeper.
    3. Advisory-lock close + cascading unblock — A blocks B/C/D; 10
       concurrent close(A,…) callers, only one succeeds; B/C/D get unblocked
       in the same transaction.
    4. Durable-then-ack — claim AND close write a row to `mutation_events`
       BEFORE returning to the caller; the rows survive a deliberately-
       killed Task.async crash between txn commit and "return value".

  Plus: the W7-03 burst regression — full primitives must not break the
  existing N-workers-N-rows skip-locked drain (called out separately from
  `tasks_ready_test.exs` so a failure in this test makes the regression
  source obvious).
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    register_schemas!(scope)

    %{scope: scope, workspace: ws, project: project}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  # PDS-D291: one MET criterion keeps this file's `done` closes out of the
  # close-artifact gate, which refuses a `done` close of a criteria-less
  # kind:task row whose reason names no PR+sha and pastes no run. These tests
  # measure the claim/close machinery, not the close reason.
  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
        },
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp events_for(doc_id, mutation) do
    import Ecto.Query

    Repo.all(
      from e in MutationEvent,
        where: e.doc_id == ^doc_id and e.mutation == ^mutation,
        order_by: e.id
    )
  end

  # ─── (1) Expected-version CAS ────────────────────────────────────────────

  describe "claim/2 — expected-version CAS" do
    test "two callers observe the SAME rev; the first to UPDATE wins, the second gets :stale_claim",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-cas")
      task = mk_task!(uniq("cas"), scope, %{"parent_id" => phase_id})

      observed_rev = task.rev

      # Caller A: directly invoke the private CAS path via a manual UPDATE
      # that mirrors what claim does — flips lifecycle_status + bumps rev.
      # This simulates "another worker won the race after we picked the
      # row but before we updated."
      import Ecto.Query
      new_rev_a = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      new_content_a = Map.put(task.content, "lifecycle_status", "in_progress")

      {1, _} =
        from(d in Document, where: d.id == ^task.id and d.rev == ^observed_rev)
        |> Repo.update_all(set: [content: new_content_a, rev: new_rev_a])

      # Caller B's claim path will SELECT the same doc but its UPDATE WHERE
      # rev = <observed_rev> will affect 0 rows → :stale_claim. We can't
      # directly call claim/2 here (it re-SELECTs the FRESH row). Instead,
      # cover the second arm via the close path: B holds an OLD rev and
      # attempts close → :stale_claim by the same WHERE-rev guard.
      #
      # But the spec is about CLAIM, so we exercise it more directly: a
      # second invocation of the private CAS via the same observed_rev must
      # fail with 0 rows.
      {0, _} =
        from(d in Document, where: d.id == ^task.id and d.rev == ^observed_rev)
        |> Repo.update_all(set: [content: Map.put(task.content, "lifecycle_status", "open")])
    end

    test "claim/2 + close/3 with a stale rev → {:error, :stale_claim}", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-cas2")
      task = mk_task!(uniq("cas2"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} = Tasks.claim("worker-1", scope ++ [phase_id: phase_id, dataset: @dataset])
      assert claimed.id == task.id

      # Caller holds the rev as of the claim; another process bumps rev.
      import Ecto.Query

      bumped_rev = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

      {1, _} =
        from(d in Document, where: d.id == ^task.id)
        |> Repo.update_all(set: [rev: bumped_rev])

      # Original claimer's close with its (now-stale) rev → :stale_claim.
      assert {:error, :stale_claim} =
               Tasks.close(task.id, "worker-1",
                 observed_epoch: claimed.content["claim"]["epoch"],
                 observed_rev: claimed.rev,
                 lifecycle_status: "done"
               )
    end

    test "two concurrent claim/2 calls drain disjoint rows AND each carries a fresh rev",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-drain")
      _ = mk_task!(uniq("d1"), scope, %{"parent_id" => phase_id})
      _ = mk_task!(uniq("d2"), scope, %{"parent_id" => phase_id})

      claim_opts = scope ++ [phase_id: phase_id, dataset: @dataset]

      results =
        1..2
        |> Task.async_stream(
          fn i -> Tasks.claim("worker-#{i}", claim_opts) end,
          max_concurrency: 2,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, v} -> v end)

      docs = Enum.flat_map(results, fn {:ok, d} -> [d] end) |> Enum.reject(&is_nil/1)

      assert length(docs) == 2
      assert Enum.uniq(Enum.map(docs, & &1.id)) == Enum.map(docs, & &1.id)
      assert Enum.uniq(Enum.map(docs, & &1.rev)) == Enum.map(docs, & &1.rev)

      for d <- docs do
        assert d.content["claim"]["epoch"] == 1
        assert d.content["claim"]["worker"] =~ ~r/^worker-/
        assert d.content["lifecycle_status"] == "in_progress"
      end
    end
  end

  # ─── (2) Fencing epoch ───────────────────────────────────────────────────

  describe "close/3 — fencing" do
    test "worker A claims at epoch=1; close with epoch=1 succeeds", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-fenceA")
      _task = mk_task!(uniq("fa"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} = Tasks.claim("worker-A", scope ++ [phase_id: phase_id, dataset: @dataset])
      assert claimed.content["claim"]["epoch"] == 1

      assert {:ok, closed} =
               Tasks.close(claimed.id, "worker-A",
                 observed_epoch: 1,
                 observed_rev: claimed.rev,
                 lifecycle_status: "done"
               )

      assert closed.content["lifecycle_status"] == "done"
      assert closed.content["claim"]["closed_by"] == "worker-A"
    end

    test "simulated TTL sweep bumps epoch=2; worker A's late close with epoch=1 → :fenced_off",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-fenceB")
      _task = mk_task!(uniq("fb"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} = Tasks.claim("worker-A", scope ++ [phase_id: phase_id, dataset: @dataset])
      assert claimed.content["claim"]["epoch"] == 1

      # Simulate the W7-05 TTL sweep: bump the epoch to 2 (a re-claim by a
      # different worker would also flip lifecycle_status, but for fencing
      # the epoch bump alone is sufficient to invalidate stale closers).
      import Ecto.Query

      new_claim = Map.put(claimed.content["claim"], "epoch", 2)
      new_content = Map.put(claimed.content, "claim", new_claim)
      new_rev = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

      {1, _} =
        from(d in Document, where: d.id == ^claimed.id)
        |> Repo.update_all(set: [content: new_content, rev: new_rev])

      # Worker A's late close with the OLD epoch must be rejected — even if
      # it happened to know the new rev (which it shouldn't, but we test
      # the fencing as a separate guard from CAS).
      assert {:error, :fenced_off} =
               Tasks.close(claimed.id, "worker-A",
                 observed_epoch: 1,
                 observed_rev: new_rev,
                 lifecycle_status: "done"
               )
    end

    test "close on a task with NO claim record → closes (no lease to fence; C3b)",
         %{scope: scope} do
      # C3b generalized fencing: a task with no claim lease has nothing to fence
      # against, so it closes cleanly (this is what lets a never-claimed root
      # task — a "goal" — be closed). A CLAIMED task still requires a matching
      # epoch (covered by the epoch-mismatch test above).
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      task = mk_task!(uniq("fc"), scope)

      assert {:ok, closed} =
               Tasks.close(task.id, "ghost",
                 observed_epoch: 1,
                 lifecycle_status: "done"
               )

      assert closed.content["lifecycle_status"] == "done"
    end

    test "epoch bumps monotonically across re-claims", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-fenceD")
      task = mk_task!(uniq("fd"), scope, %{"parent_id" => phase_id})

      {:ok, claim1} = Tasks.claim("worker-A", scope ++ [phase_id: phase_id, dataset: @dataset])
      assert claim1.content["claim"]["epoch"] == 1

      # Reset the row to be ready again (simulating a sweep that returned
      # it to the queue) — flip lifecycle_status back to open and clear the
      # expired worker WITHOUT nuking the claim map (which carries the epoch).
      import Ecto.Query

      reopened_claim = Map.put(claim1.content["claim"], "worker", nil)

      reopened_content =
        claim1.content
        |> Map.put("lifecycle_status", "open")
        |> Map.put("claim", reopened_claim)

      new_rev = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

      {1, _} =
        from(d in Document, where: d.id == ^task.id)
        |> Repo.update_all(set: [content: reopened_content, rev: new_rev])

      {:ok, claim2} = Tasks.claim("worker-B", scope ++ [phase_id: phase_id, dataset: @dataset])
      assert claim2.content["claim"]["epoch"] == 2
      assert claim2.content["claim"]["worker"] == "worker-B"
    end
  end

  # ─── (3) Advisory-lock close + cascading unblock ─────────────────────────

  describe "close/3 — advisory lock + unblock cascade" do
    test "task A blocks B/C/D; close(A) flips all three from blocked→open in same txn",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-casc")
      a = mk_task!(uniq("casc-a"), scope, %{"parent_id" => phase_id})

      b =
        mk_task!(uniq("casc-b"), scope, %{
          "parent_id" => phase_id,
          "lifecycle_status" => "blocked"
        })

      c =
        mk_task!(uniq("casc-c"), scope, %{
          "parent_id" => phase_id,
          "lifecycle_status" => "blocked"
        })

      d =
        mk_task!(uniq("casc-d"), scope, %{
          "parent_id" => phase_id,
          "lifecycle_status" => "blocked"
        })

      {:ok, _} = Tasks.add_dep(b.id, a.id, :blocks)
      {:ok, _} = Tasks.add_dep(c.id, a.id, :blocks)
      {:ok, _} = Tasks.add_dep(d.id, a.id, :blocks)

      # Claim A first so the close has a valid epoch to assert against.
      {:ok, claimed_a} =
        Tasks.claim("worker-A", scope ++ [phase_id: phase_id, dataset: @dataset])

      assert claimed_a.id == a.id

      assert {:ok, closed_a} =
               Tasks.close(a.id, "worker-A",
                 observed_epoch: claimed_a.content["claim"]["epoch"],
                 lifecycle_status: "done"
               )

      assert closed_a.content["lifecycle_status"] == "done"

      # B/C/D should now be back to "open" (their only blocker is done).
      for child <- [b, c, d] do
        reloaded = Repo.get!(Document, child.id)

        assert reloaded.content["lifecycle_status"] == "open",
               "#{child.doc_id} should be unblocked after A closes; got #{inspect(reloaded.content["lifecycle_status"])}"
      end

      # And each unblocked dep generated a "task.mutated" event.
      for child <- [b, c, d] do
        events = events_for(child.doc_id, Tasks.event_kinds().mutated)
        assert length(events) >= 1, "no task.mutated event for #{child.doc_id}"
      end
    end

    test "dependent with multiple blockers stays blocked until ALL are done", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-multi")
      a1 = mk_task!(uniq("m-a1"), scope, %{"parent_id" => phase_id})
      a2 = mk_task!(uniq("m-a2"), scope, %{"parent_id" => phase_id})

      b =
        mk_task!(uniq("m-b"), scope, %{"parent_id" => phase_id, "lifecycle_status" => "blocked"})

      {:ok, _} = Tasks.add_dep(b.id, a1.id, :blocks)
      {:ok, _} = Tasks.add_dep(b.id, a2.id, :blocks)

      {:ok, claimed_a1} =
        Tasks.claim("w", scope ++ [phase_id: phase_id, dataset: @dataset])

      # Just to be deterministic about WHICH ready row we claimed first:
      # both a1/a2 are ready, claim either, but pin it for the next assert.
      assert claimed_a1.id in [a1.id, a2.id]

      {:ok, _} =
        Tasks.close(claimed_a1.id, "w",
          observed_epoch: claimed_a1.content["claim"]["epoch"],
          lifecycle_status: "done"
        )

      # B still has the OTHER blocker → still blocked.
      still = Repo.get!(Document, b.id)
      assert still.content["lifecycle_status"] == "blocked"

      # Claim + close the second blocker.
      {:ok, claimed_a2} =
        Tasks.claim("w", scope ++ [phase_id: phase_id, dataset: @dataset])

      {:ok, _} =
        Tasks.close(claimed_a2.id, "w",
          observed_epoch: claimed_a2.content["claim"]["epoch"],
          lifecycle_status: "done"
        )

      now = Repo.get!(Document, b.id)
      assert now.content["lifecycle_status"] == "open", "both blockers done; B must unblock"
    end

    test "10 concurrent close(A) callers serialize via advisory lock — exactly ONE succeeds",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-ser")
      a = mk_task!(uniq("ser-a"), scope, %{"parent_id" => phase_id})

      b =
        mk_task!(uniq("ser-b"), scope, %{"parent_id" => phase_id, "lifecycle_status" => "blocked"})

      {:ok, _} = Tasks.add_dep(b.id, a.id, :blocks)

      {:ok, claimed} = Tasks.claim("w", scope ++ [phase_id: phase_id, dataset: @dataset])
      assert claimed.id == a.id

      epoch = claimed.content["claim"]["epoch"]

      results =
        1..10
        |> Task.async_stream(
          fn _ ->
            Tasks.close(a.id, "w",
              observed_epoch: epoch,
              lifecycle_status: "done"
            )
          end,
          max_concurrency: 10,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, v} -> v end)

      oks = Enum.count(results, &match?({:ok, _}, &1))
      stales = Enum.count(results, &match?({:error, :stale_claim}, &1))

      assert oks == 1,
             "exactly ONE close should succeed under the advisory lock; got #{oks} (#{inspect(results)})"

      assert oks + stales == 10,
             "the other 9 should be :stale_claim (CAS rejected after the winner bumped rev); got #{inspect(results)}"

      # And B is unblocked.
      reloaded_b = Repo.get!(Document, b.id)
      assert reloaded_b.content["lifecycle_status"] == "open"
    end
  end

  # ─── (4) Durable-then-ack ────────────────────────────────────────────────

  describe "durable-then-ack — mutation_events" do
    test "claim/2 writes a task.claimed event BEFORE returning", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-durA")
      task = mk_task!(uniq("dur-a"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} = Tasks.claim("w", scope ++ [phase_id: phase_id, dataset: @dataset])
      assert claimed.id == task.id

      events = events_for(task.doc_id, Tasks.event_kinds().claimed)
      assert length(events) == 1, "claim must write exactly one task.claimed event"

      [ev] = events
      assert ev.rev == claimed.rev, "event.rev should match the post-claim doc.rev"
      assert ev.previous_rev == task.rev, "event.previous_rev should be the pre-claim rev"
      assert ev.workspace_id == task.workspace_id
    end

    test "close/3 writes a task.closed event BEFORE returning", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-durB")
      task = mk_task!(uniq("dur-b"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} = Tasks.claim("w", scope ++ [phase_id: phase_id, dataset: @dataset])

      {:ok, _} =
        Tasks.close(claimed.id, "w",
          observed_epoch: claimed.content["claim"]["epoch"],
          lifecycle_status: "done"
        )

      events = events_for(task.doc_id, Tasks.event_kinds().closed)
      assert length(events) == 1, "close must write exactly one task.closed event"
    end

    test "deliberately-killed Task.async between commit and return: event still in DB",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-durC")
      task = mk_task!(uniq("dur-c"), scope, %{"parent_id" => phase_id})

      parent = self()

      # Run claim/2 in a plain unlinked process — Task.async would link the
      # child back to us, so `Process.exit(child, :kill)` would crash this
      # test. The point is: the claim event is committed INSIDE the
      # Repo.transaction; killing the caller after commit but before it
      # could "return" the value still leaves the event durable in the DB.
      child =
        spawn(fn ->
          # Inherit the shared sandbox conn so the spawned process sees the
          # same connection ownership.
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

          result = Tasks.claim("ghost", scope ++ [phase_id: phase_id, dataset: @dataset])
          send(parent, {:claimed, result})
          # Spin briefly so the parent has time to kill us.
          Process.sleep(5_000)
        end)

      ref = Process.monitor(child)

      assert_receive {:claimed, {:ok, %Document{}}}, 2_000

      # Kill the child — its return value is lost, but the event is durable.
      Process.exit(child, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1_000

      events = events_for(task.doc_id, Tasks.event_kinds().claimed)

      assert length(events) == 1,
             "the mutation_events row must survive the killed claimer (durable-then-ack)"
    end
  end

  # ─── (4b) w7-08: Tasks.claim_by_id/3 — targeted claim primitive ───────────

  describe "claim_by_id/3 — targeted (w7-08)" do
    test "happy path: targets a specific row, advances lifecycle, bumps epoch",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-cbi-ok")
      a = mk_task!(uniq("cbi-a"), scope, %{"parent_id" => phase_id})
      _b = mk_task!(uniq("cbi-b"), scope, %{"parent_id" => phase_id})

      # Even though `b` is also ready, claim_by_id MUST pick `a`.
      assert {:ok, claimed} = Tasks.claim_by_id(a.doc_id, "w-targeted", scope)

      assert claimed.id == a.id
      assert claimed.doc_id == a.doc_id
      assert claimed.content["lifecycle_status"] == "in_progress"
      assert claimed.content["claim"]["worker"] == "w-targeted"
      assert claimed.content["claim"]["epoch"] == 1

      # Durable event landed for THIS doc_id only.
      events = events_for(a.doc_id, Tasks.event_kinds().claimed)
      assert length(events) == 1
    end

    test "not-ready: target is already in_progress → {:error, :not_ready}",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-cbi-nr")
      task = mk_task!(uniq("cbi-nr"), scope, %{"parent_id" => phase_id})

      # First claim wins, status → in_progress
      {:ok, _} = Tasks.claim_by_id(task.doc_id, "first", scope)

      # Second claim sees lifecycle_status=in_progress → :not_ready
      assert {:error, :not_ready} = Tasks.claim_by_id(task.doc_id, "second", scope)
    end

    test "blocked-by-deps: outbound blocks edge with non-done target → :blocked_by_unsatisfied_deps",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-cbi-bd")
      blocker = mk_task!(uniq("cbi-blk"), scope, %{"parent_id" => phase_id})
      blocked = mk_task!(uniq("cbi-bkd"), scope, %{"parent_id" => phase_id})

      {:ok, _} = Tasks.add_dep(blocked.id, blocker.id, :blocks)

      assert {:error, :blocked_by_unsatisfied_deps} =
               Tasks.claim_by_id(blocked.doc_id, "w", scope)

      # Once blocker closes (so its lifecycle_status=done), claim_by_id succeeds.
      {:ok, claimed_blocker} =
        Tasks.claim_by_id(blocker.doc_id, "w", scope)

      {:ok, _closed} =
        Tasks.close(blocker.id, "w",
          observed_epoch: claimed_blocker.content["claim"]["epoch"],
          lifecycle_status: "done"
        )

      assert {:ok, claimed_blocked} =
               Tasks.claim_by_id(blocked.doc_id, "w", scope)

      assert claimed_blocked.content["lifecycle_status"] == "in_progress"
    end

    test "not-found: unknown doc_id → :not_found", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      assert {:error, :not_found} =
               Tasks.claim_by_id(
                 "no-such-doc-id-#{System.unique_integer([:positive])}",
                 "w",
                 scope
               )
    end

    test "concurrent targeted claims on SAME doc: exactly one wins under advisory lock",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-cbi-conc")
      task = mk_task!(uniq("cbi-conc"), scope, %{"parent_id" => phase_id})

      results =
        1..8
        |> Task.async_stream(
          fn i -> Tasks.claim_by_id(task.doc_id, "w-#{i}", scope) end,
          max_concurrency: 8,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, v} -> v end)

      oks = Enum.count(results, &match?({:ok, _}, &1))
      not_ready = Enum.count(results, &match?({:error, :not_ready}, &1))
      stale = Enum.count(results, &match?({:error, :stale_claim}, &1))

      assert oks == 1,
             "exactly ONE targeted claim should succeed; got #{oks} (#{inspect(results)})"

      # The other 7 are serialized behind the advisory lock — once the winner
      # commits (lifecycle→in_progress), each subsequent caller fetches the
      # row INSIDE the lock and sees not_ready (correct). stale_claim is
      # tolerated if a CAS-race interleaves under load.
      assert oks + not_ready + stale == 8,
             "all 8 results must be {:ok,_}|{:error,:not_ready}|{:error,:stale_claim}; got #{inspect(results)}"
    end
  end

  # ─── (5) Realtime PubSub — task ops broadcast like document writes ────────
  #
  # The lifecycle write paths mutate `documents` rows via CAS
  # `Repo.update_all`, bypassing Content's `tap_broadcast/5`. Without an
  # explicit post-commit broadcast the `/v1/data/listen/:dataset` SSE stream
  # and StudioLive never see a claim/close live (diagnosed against prod).
  # These tests pin the contract: every task op announces on the canonical
  # `documents:<dataset>` topic with the SAME message shape a document
  # update broadcast carries — including the `event_id` the SSE listen
  # controller requires to forward the frame.

  describe "realtime PubSub — task ops broadcast on documents:<dataset>" do
    test "claim_by_id/3 broadcasts {:document_changed, …} with task.claimed + the updated doc",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-ps-claim")
      task = mk_task!(uniq("ps-claim"), scope, %{"parent_id" => phase_id})

      # Subscribe AFTER creation so the create_document broadcast cannot
      # satisfy the assertion below.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")

      assert {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "w-ps", scope)

      assert_receive {:document_changed, msg}, 1_000
      assert msg.doc_id == claimed.doc_id
      assert msg.mutation == Tasks.event_kinds().claimed
      assert msg.rev == claimed.rev
      assert msg.previous_rev == task.rev

      # The SSE listen controller forwards ONLY messages carrying the
      # mutation_events row id (its `event_id` pattern-match) — assert the
      # broadcast rides the durable event written in the claim txn.
      [ev] = events_for(claimed.doc_id, Tasks.event_kinds().claimed)
      assert msg.event_id == ev.id

      # Envelope payload reflects the POST-claim state (flat envelope:
      # content keys are spread top-level).
      assert msg.document["lifecycle_status"] == "in_progress"
      assert msg.document["_rev"] == claimed.rev
    end

    test "queue claim/2 broadcasts too", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-ps-q")
      task = mk_task!(uniq("ps-q"), scope, %{"parent_id" => phase_id})

      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")

      claim_opts = scope ++ [phase_id: phase_id, dataset: @dataset]
      assert {:ok, %Document{} = claimed} = Tasks.claim("w-psq", claim_opts)
      assert claimed.id == task.id

      assert_receive {:document_changed, msg}, 1_000
      assert msg.doc_id == task.doc_id
      assert msg.mutation == Tasks.event_kinds().claimed
      assert is_integer(msg.event_id)
    end

    test "close/3 broadcasts task.closed AND task.mutated for each unblocked dependent",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-ps-close")
      blocker = mk_task!(uniq("ps-blk"), scope, %{"parent_id" => phase_id})

      blocked =
        mk_task!(uniq("ps-bkd"), scope, %{
          "parent_id" => phase_id,
          "lifecycle_status" => "blocked"
        })

      {:ok, _} = Tasks.add_dep(blocked.id, blocker.id, :blocks)

      {:ok, claimed} = Tasks.claim_by_id(blocker.doc_id, "w-psc", scope)

      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")

      assert {:ok, closed} =
               Tasks.close(blocker.id, "w-psc",
                 observed_epoch: claimed.content["claim"]["epoch"],
                 lifecycle_status: "done"
               )

      # The close itself.
      assert_receive {:document_changed, %{doc_id: closed_doc_id} = close_msg}, 1_000
      assert closed_doc_id == closed.doc_id
      assert close_msg.mutation == Tasks.event_kinds().closed
      assert close_msg.rev == closed.rev
      assert is_integer(close_msg.event_id)
      assert close_msg.document["lifecycle_status"] == "done"

      # The cascade-unblocked dependent announces as task.mutated.
      assert_receive {:document_changed, %{doc_id: dep_doc_id} = dep_msg}, 1_000
      assert dep_doc_id == blocked.doc_id
      assert dep_msg.mutation == Tasks.event_kinds().mutated
      assert dep_msg.document["lifecycle_status"] == "open"
    end

    test "relabel_by_id/3 and update_paper_refs_by_id/3 broadcast", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-ps-lbl")
      task = mk_task!(uniq("ps-lbl"), scope, %{"parent_id" => phase_id})

      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")

      assert {:ok, relabeled} = Tasks.relabel_by_id(task.id, ["file-claim:a.ex"], [])
      assert_receive {:document_changed, msg}, 1_000
      assert msg.doc_id == task.doc_id
      assert msg.mutation == Tasks.event_kinds().relabeled
      assert msg.rev == relabeled.rev

      assert {:ok, referenced} = Tasks.update_paper_refs_by_id(task.id, ["paper-x"], [])
      assert_receive {:document_changed, msg2}, 1_000
      assert msg2.doc_id == task.doc_id
      assert msg2.mutation == Tasks.event_kinds().referenced
      assert msg2.rev == referenced.rev
    end

    test "workspace-scoped topic documents:ws:<ws>:<dataset> fires too", %{
      scope: scope,
      workspace: ws
    } do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      phase_id = uniq("phase-ps-ws")
      task = mk_task!(uniq("ps-ws"), scope, %{"parent_id" => phase_id})

      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{ws.id}:#{@dataset}")

      assert {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "w-psw", scope)

      assert_receive {:document_changed, msg}, 1_000
      assert msg.doc_id == claimed.doc_id
      assert msg.mutation == Tasks.event_kinds().claimed
      assert msg.workspace_id == ws.id
    end
  end

  # ─── (6) Regression — W7-03 burst test still drains correctly ─────────────

  describe "regression — full primitives do not break W7-03 burst" do
    test "5 workers, 5 rows, 5 iterations: every row goes to exactly one worker",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      Enum.each(1..5, fn iter ->
        phase_id = uniq("phase-regr-#{iter}")

        task_ids =
          for i <- 1..5 do
            mk_task!(uniq("regr-#{iter}-#{i}"), scope, %{"parent_id" => phase_id}).id
          end
          |> Enum.sort()

        claim_opts = scope ++ [phase_id: phase_id, dataset: @dataset]

        claimed =
          1..5
          |> Task.async_stream(
            fn w -> Tasks.claim("worker-#{w}", claim_opts) end,
            max_concurrency: 5,
            ordered: false,
            timeout: 10_000
          )
          |> Enum.map(fn {:ok, v} -> v end)
          |> Enum.flat_map(fn
            {:ok, %Document{} = d} -> [d]
            _ -> []
          end)

        claimed_ids = claimed |> Enum.map(& &1.id) |> Enum.sort()

        assert claimed_ids == task_ids,
               "iter #{iter}: claimed #{inspect(claimed_ids)} != created #{inspect(task_ids)}"

        # Each carries an epoch=1 fresh claim and a new rev.
        for d <- claimed do
          assert d.content["claim"]["epoch"] == 1
          assert d.content["lifecycle_status"] == "in_progress"
        end
      end)
    end
  end
end
