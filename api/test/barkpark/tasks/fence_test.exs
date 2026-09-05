defmodule Barkpark.Tasks.FenceTest do
  @moduledoc """
  rail-l4 — allow-and-fence + same-worker lease renewal.

  Mutating the world of an `in_progress` task (a blocker edge, a re-parent)
  bumps its claim epoch WITHOUT rejecting the mutator; the holder recovers via a
  same-worker re-claim (renewal). Covers:

    * THE canonical case: A claims t5; B adds a blocker t5→t9 (B not rejected);
      t5's epoch is bumped; A's old-epoch close → :fenced_off; A renews (same
      worker) → new epoch; A closes with the new epoch → commits.
    * a move of a claimed task bumps its epoch (payload notes fenced:reparented).
    * an edge add on a NON-claimed task bumps nothing.
    * renewal refreshes ts_iso (the TTL sweeper won't reap a renewed lease).
    * renewal does NOT restamp work_digest (a foreign brief edit BEFORE the
      renewal still 409s doc_changed_since_claim at close).
    * a DIFFERENT worker's targeted claim on an in_progress task still :not_ready.
  """

  use Barkpark.DataCase, async: true

  import Ecto.Query

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Tasks.{Internal, TtlSweeper}

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
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

  defp mk_task!(doc_id, scope, content_extra) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ],
          "lifecycle_status" => "open"
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

  # Raw CAS content patch that PRESERVES the claim — the "someone edited it while
  # I held the claim" race (also used to backdate ts_iso).
  defp foreign_patch_content!(task_id, patch) do
    doc = Repo.get!(Document, task_id)
    new_content = Map.merge(doc.content, patch)

    {1, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev)
      |> Repo.update_all(set: [content: new_content, rev: Internal.generate_rev()])

    :ok
  end

  defp reload(task_id), do: Repo.get!(Document, task_id)
  defp epoch_of(%Document{content: c}), do: get_in(c, ["claim", "epoch"])

  defp events(doc_id, mutation) do
    Repo.all(
      from e in MutationEvent,
        where: e.doc_id == ^doc_id and e.mutation == ^mutation,
        order_by: e.id
    )
  end

  # ─── canonical: edge fence → fenced_off → renewal → commit ───────────────

  describe "canonical allow-and-fence + renewal" do
    test "A claims, B blocks it (not rejected), A fenced_off, A renews, A closes",
         %{scope: scope} do
      t5 = mk_task!(uniq("t5"), scope, %{})
      t9 = mk_task!(uniq("t9"), scope, %{})

      {:ok, claimed} = Tasks.claim_by_id(t5.doc_id, "A", scope)
      assert epoch_of(claimed) == 1

      # B files a blocks edge onto A's claimed task — B is NOT rejected.
      assert {:ok, _edge} = Tasks.add_dep(t5.id, t9.id, :blocks)

      # t5's epoch is now bumped (the fence).
      assert epoch_of(reload(t5.id)) == 2

      # A's close with the OLD epoch is fenced off.
      assert {:error, :fenced_off} = Tasks.close(t5.id, "A", observed_epoch: 1)

      # A renews (same worker) → new epoch (fence +1, renewal +1 = 3).
      assert {:ok, renewed} = Tasks.claim_by_id(t5.doc_id, "A", scope)
      assert epoch_of(renewed) == 3

      # A closes with the NEW epoch → commits.
      assert {:ok, closed} =
               Tasks.close(t5.id, "A", observed_epoch: 3, lifecycle_status: "blocked")

      assert closed.content["lifecycle_status"] == "blocked"
    end

    test "the edge adder is never rejected + a task.mutated fence event lands",
         %{scope: scope} do
      dep = mk_task!(uniq("dep"), scope, %{})
      blk = mk_task!(uniq("blk"), scope, %{})
      {:ok, _} = Tasks.claim_by_id(dep.doc_id, "w", scope)

      assert {:ok, _edge} = Tasks.add_dep(dep.id, blk.id, :blocks)

      assert [ev] = events(dep.doc_id, "task.mutated")
      assert ev.document["fenced"] == "edge_added"
    end
  end

  # ─── edge add on a non-claimed task bumps nothing ────────────────────────

  describe "no fence when the dependent is not a live claim" do
    test "edge add on an open task bumps no epoch and emits no task.mutated",
         %{scope: scope} do
      dep = mk_task!(uniq("open-dep"), scope, %{})
      blk = mk_task!(uniq("open-blk"), scope, %{})

      assert {:ok, _edge} = Tasks.add_dep(dep.id, blk.id, :blocks)

      reread = reload(dep.id)
      assert reread.content["lifecycle_status"] == "open"
      refute Map.has_key?(reread.content, "claim")
      assert events(dep.doc_id, "task.mutated") == []
    end
  end

  # ─── move of a claimed task fences it ────────────────────────────────────

  describe "move fence" do
    test "moving an in_progress task bumps its epoch + notes fenced:reparented",
         %{scope: scope} do
      dst = uniq("dstEpic")
      _p = mk_task!(dst, scope, %{})
      task = mk_task!(uniq("mvclaimed"), scope, %{})

      {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "w", scope)
      assert epoch_of(claimed) == 1

      assert {:ok, moved} = Tasks.move_by_id(task.id, dst)
      assert epoch_of(moved) == 2

      assert [ev] = events(task.doc_id, "task.reparented")
      assert ev.document["fenced"] == "reparented"
    end
  end

  # ─── renewal: ts_iso refresh + work_digest preservation + worker check ───

  describe "renewal semantics" do
    test "renewal refreshes ts_iso so the TTL sweeper won't reap a renewed lease",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      task = mk_task!(uniq("renew-ttl"), scope, %{})
      {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "w", scope)

      # Backdate the lease an hour so it LOOKS expired to the sweeper.
      stale_iso = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
      claim = Map.put(claimed.content["claim"], "ts_iso", stale_iso)
      :ok = foreign_patch_content!(task.id, %{"claim" => claim})

      # Renew (same worker) — refreshes ts_iso to ~now.
      {:ok, renewed} = Tasks.claim_by_id(task.doc_id, "w", scope)
      assert renewed.content["claim"]["ts_iso"] != stale_iso

      # A 5-minute sweep must NOT reap the renewed lease.
      TtlSweeper.sweep(300)
      survived = reload(task.id)
      assert survived.content["lifecycle_status"] == "in_progress"
      assert survived.content["claim"]["worker"] == "w"
    end

    test "renewal keeps the original work_digest — a foreign brief edit before it still 409s at close",
         %{scope: scope} do
      task = mk_task!(uniq("renew-digest"), scope, %{"description" => "original brief"})
      {:ok, _claimed} = Tasks.claim_by_id(task.doc_id, "w", scope)

      # A foreign actor rewrites the brief BEFORE the renewal.
      :ok = foreign_patch_content!(task.id, %{"description" => "rewritten brief"})

      # Renewal does NOT restamp the work_digest.
      {:ok, renewed} = Tasks.claim_by_id(task.doc_id, "w", scope)
      new_epoch = epoch_of(renewed)

      # Close on the renewed lease still catches the drifted brief.
      assert {:error, {:doc_changed_since_claim, _rev, changed}} =
               Tasks.close(task.id, "w", observed_epoch: new_epoch)

      assert changed == ["description"]
    end

    test "a DIFFERENT worker's targeted claim on an in_progress task is still not_ready",
         %{scope: scope} do
      task = mk_task!(uniq("other-worker"), scope, %{})
      {:ok, _} = Tasks.claim_by_id(task.doc_id, "holder", scope)

      assert {:error, :not_ready} = Tasks.claim_by_id(task.doc_id, "intruder", scope)
    end
  end
end
