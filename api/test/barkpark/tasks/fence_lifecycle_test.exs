defmodule Barkpark.Tasks.FenceLifecycleTest do
  @moduledoc """
  The RESOURCE fence lifecycle — the `--resources` fence that `claim_by_id/3`
  takes, NOT the epoch fence of `Tasks.Fence`/`Tasks.ClaimFence`.

  Pins the ruling on WHEN a fenced resource is freed, so no lifecycle state can
  hold a resource that no verb can release:

    * a REFUSED claim (`resource_conflict`) writes NOTHING — no claim map, no
      lifecycle flip, no rev bump, no mutation_event;
    * `close` frees the fence (the overlap scan is `in_progress`-only), for
      every terminal status — done / cancelled / blocked;
    * `release` frees the fence and, like the TTL reap, stops REPRESENTING the
      dead fence on the re-opened row;
    * the TTL reap frees the fence;
    * `release` on a terminal task still refuses (`{:not_in_progress, status}`)
      — and that refusal is NOT a deadlock, because a terminal task holds no
      fence for it to free.

  Concurrency arms drive the refusal, close, release and lease-expiry paths
  from spawned processes sharing the sandbox connection.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Tasks.{Close, Release, TtlSweeper}

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope, res: uniq("fence/res")}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(scope, prefix) do
    doc_id = uniq(prefix)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          # PDS-D291: one MET criterion keeps this file's `done` closes out of
          # the close-artifact gate (a criteria-less `done` close whose reason
          # names no PR+sha is refused). These tests measure the resource fence.
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
          }
        },
        @dataset,
        scope
      )

    doc
  end

  defp reload(doc), do: Repo.get!(Document, doc.id)
  defp epoch_of(doc), do: get_in(reload(doc).content, ["claim", "epoch"])

  defp events_for(doc) do
    Repo.all(from(e in MutationEvent, where: e.doc_id == ^doc.doc_id, select: e.mutation))
  end

  # ─── (1) a refused claim persists NOTHING ──────────────────────────────────

  describe "resource_conflict refusal is atomic" do
    test "the refused caller's row is byte-identical: no claim, no assignee, same rev, no event",
         %{scope: scope, res: res} do
      holder = mk_task!(scope, "fl-holder")
      contender = mk_task!(scope, "fl-contender")

      assert {:ok, _} = Tasks.claim_by_id(holder.doc_id, "w-holder", scope ++ [resources: [res]])

      before = reload(contender)
      before_events = events_for(contender)

      assert {:error, {:resource_conflict, [conflict]}} =
               Tasks.claim_by_id(contender.doc_id, "w-contender", scope ++ [resources: [res]])

      assert conflict.doc_id == holder.doc_id
      assert conflict.worker == "w-holder"
      assert res in conflict.resources

      # The refused caller left NO server state on its own row.
      after_doc = reload(contender)
      assert after_doc.rev == before.rev
      assert after_doc.content["lifecycle_status"] == "open"
      refute Map.has_key?(after_doc.content, "claim")
      refute Map.has_key?(after_doc.content, "assignee")
      assert events_for(contender) == before_events

      # …and none on the holder's row either (the scan is a read).
      assert reload(holder).content["claim"]["worker"] == "w-holder"
    end

    test "a repeated refusal still writes nothing (no drip of ghost claims)",
         %{scope: scope, res: res} do
      holder = mk_task!(scope, "fl-holder2")
      contender = mk_task!(scope, "fl-contender2")

      assert {:ok, _} = Tasks.claim_by_id(holder.doc_id, "w-holder", scope ++ [resources: [res]])
      before = reload(contender)
      before_events = events_for(contender)

      for _ <- 1..5 do
        assert {:error, {:resource_conflict, _}} =
                 Tasks.claim_by_id(contender.doc_id, "w-contender", scope ++ [resources: [res]])
      end

      after_doc = reload(contender)
      assert after_doc.rev == before.rev
      refute Map.has_key?(after_doc.content, "claim")
      assert events_for(contender) == before_events
      refute "task.claimed" in before_events
    end
  end

  # ─── (2) every terminal path frees the fence ───────────────────────────────

  describe "terminal transitions free the fence" do
    for status <- ~w(done cancelled blocked) do
      test "close → #{status} frees the resource for the next claimer", %{
        scope: scope,
        res: res
      } do
        status = unquote(status)
        holder = mk_task!(scope, "fl-close-#{status}")
        next = mk_task!(scope, "fl-next-#{status}")

        assert {:ok, _} =
                 Tasks.claim_by_id(holder.doc_id, "w-holder", scope ++ [resources: [res]])

        assert {:ok, _} =
                 Close.close(holder.id, "w-holder",
                   observed_epoch: epoch_of(holder),
                   lifecycle_status: status,
                   # task-650d7844d8fe7199: a `cancelled` close needs a reason.
                   # Passed for every status in the loop so the three arms stay
                   # one shape; `done` and `blocked` ignore it.
                   reason: "closed #{status} by the fence lifecycle fixture"
                 )

        assert reload(holder).content["lifecycle_status"] == status

        assert {:ok, claimed} =
                 Tasks.claim_by_id(next.doc_id, "w-next", scope ++ [resources: [res]])

        assert claimed.content["claim"]["resources"] == [res]
      end
    end

    test "release frees the resource AND stops representing it on the re-opened row",
         %{scope: scope, res: res} do
      holder = mk_task!(scope, "fl-rel-holder")
      next = mk_task!(scope, "fl-rel-next")

      assert {:ok, _} = Tasks.claim_by_id(holder.doc_id, "w-holder", scope ++ [resources: [res]])

      assert {:ok, _} = Release.release(holder.id, "w-holder", observed_epoch: epoch_of(holder))

      released = reload(holder)
      assert released.content["lifecycle_status"] == "open"

      # Same ruling the TTL reap already applies: the dead fence must not keep
      # painting "holds <res>" on an OPEN, unowned row.
      refute Map.has_key?(released.content["claim"], "resources")

      assert {:ok, _} = Tasks.claim_by_id(next.doc_id, "w-next", scope ++ [resources: [res]])
    end

    test "a TTL reap frees the resource", %{scope: scope, res: res} do
      holder = mk_task!(scope, "fl-reap-holder")
      next = mk_task!(scope, "fl-reap-next")

      assert {:ok, _} = Tasks.claim_by_id(holder.doc_id, "w-holder", scope ++ [resources: [res]])

      # ttl 0 → every live claim is expired. sweep/1 returns a %{swept:, skipped:}
      # tally, not an {:ok, _} tuple.
      assert %{swept: swept} = TtlSweeper.sweep(0)
      assert swept >= 1

      reaped = reload(holder)
      assert reaped.content["lifecycle_status"] == "open"
      refute Map.has_key?(reaped.content["claim"], "resources")

      assert {:ok, _} = Tasks.claim_by_id(next.doc_id, "w-next", scope ++ [resources: [res]])
    end
  end

  # ─── (3) the terminal-release refusal is not a deadlock ────────────────────

  describe "release on a terminal task" do
    test "refuses with {:not_in_progress, status} — and the row holds no fence to free",
         %{scope: scope, res: res} do
      holder = mk_task!(scope, "fl-done-holder")
      next = mk_task!(scope, "fl-done-next")

      assert {:ok, _} = Tasks.claim_by_id(holder.doc_id, "w-holder", scope ++ [resources: [res]])
      epoch = epoch_of(holder)
      assert {:ok, _} = Close.close(holder.id, "w-holder", observed_epoch: epoch)

      # The refusal the filing called a deadlock:
      assert {:error, {:not_in_progress, "done"}} =
               Release.release(holder.id, "w-holder", observed_epoch: epoch + 1)

      # …but there is nothing left to free — the fence died with the close.
      assert {:ok, _} = Tasks.claim_by_id(next.doc_id, "w-next", scope ++ [resources: [res]])
    end
  end

  # ─── concurrency arms ──────────────────────────────────────────────────────

  describe "concurrent contention" do
    test "N concurrent claims of one resource: exactly one winner, N-1 refusals, one live fence",
         %{scope: scope, res: res} do
      tasks = for i <- 1..6, do: mk_task!(scope, "fl-race-#{i}")
      parent = self()

      results =
        tasks
        |> Enum.map(fn t ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            Tasks.claim_by_id(t.doc_id, "w-#{t.doc_id}", scope ++ [resources: [res]])
          end)
        end)
        |> Enum.map(&Task.await(&1, 15_000))

      winners = Enum.count(results, &match?({:ok, _}, &1))
      refusals = Enum.count(results, &match?({:error, {:resource_conflict, _}}, &1))

      assert winners == 1
      assert refusals == 5

      live =
        Enum.count(tasks, fn t ->
          c = reload(t).content
          c["lifecycle_status"] == "in_progress" and get_in(c, ["claim", "resources"]) == [res]
        end)

      assert live == 1
    end

    test "concurrent close + claim: the fence is free exactly once the close commits",
         %{scope: scope, res: res} do
      holder = mk_task!(scope, "fl-cc-holder")
      next = mk_task!(scope, "fl-cc-next")
      parent = self()

      assert {:ok, _} = Tasks.claim_by_id(holder.doc_id, "w-holder", scope ++ [resources: [res]])
      epoch = epoch_of(holder)

      closer =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          Close.close(holder.id, "w-holder", observed_epoch: epoch)
        end)

      assert {:ok, _} = Task.await(closer, 15_000)

      assert {:ok, _} = Tasks.claim_by_id(next.doc_id, "w-next", scope ++ [resources: [res]])
      assert reload(holder).content["lifecycle_status"] == "done"
    end

    test "concurrent releases: one succeeds, the loser is fenced, and no fence survives",
         %{scope: scope, res: res} do
      holder = mk_task!(scope, "fl-rr-holder")
      parent = self()

      assert {:ok, _} = Tasks.claim_by_id(holder.doc_id, "w-holder", scope ++ [resources: [res]])
      epoch = epoch_of(holder)

      results =
        1..3
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            Release.release(holder.id, "w-holder", observed_epoch: epoch)
          end)
        end)
        |> Enum.map(&Task.await(&1, 15_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1

      released = reload(holder)
      assert released.content["lifecycle_status"] == "open"
      refute Map.has_key?(released.content["claim"], "resources")
    end

    test "lease expiry under contention: the reaped fence is claimable, the reaped row is not held",
         %{scope: scope, res: res} do
      holder = mk_task!(scope, "fl-exp-holder")
      next = mk_task!(scope, "fl-exp-next")
      parent = self()

      assert {:ok, _} = Tasks.claim_by_id(holder.doc_id, "w-holder", scope ++ [resources: [res]])

      sweeper =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          TtlSweeper.sweep(0)
        end)

      assert %{swept: swept} = Task.await(sweeper, 15_000)
      assert swept >= 1

      assert {:ok, _} = Tasks.claim_by_id(next.doc_id, "w-next", scope ++ [resources: [res]])
      assert reload(holder).content["claim"]["worker"] == nil
    end
  end
end
