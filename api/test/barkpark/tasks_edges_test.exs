defmodule Barkpark.TasksEdgesTest do
  @moduledoc """
  W7a step 2 — `task_edges` table + typed dep graph CRUD.

  Six surfaces under test (per the brief's VERIFY gate):

    1. `add_dep` + `dependencies` / `dependents` — happy path returns the
       right docs in the right direction.
    2. Idempotency — adding the same edge twice returns `{:ok, _}` no error,
       no duplicate row.
    3. `remove_dep` — removes only the specified edge, leaves siblings.
    4. Kind discrimination — `blocks` and `discovered-from` edges don't
       bleed across each other's queries.
    5. Cascade — deleting a referenced document cascades the edge (FK
       `on_delete: :delete_all` on both `from_id` and `to_id`).
    6. Tenancy inheritance — edges only connect documents within the same
       workspace IN PRACTICE; this isn't enforced at the edge table (the
       edge is a leaf relation with no scope columns) but the application
       layer always ferries scoped document IDs.

  Mirrors the W7-01 test conventions (`tasks_test.exs`): per-test sandbox,
  scope helpers from `TenancyFixtures`, schema registration in setup,
  raw-insert defense-in-depth verifies the DB guarantees the application
  layer leans on.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Edge

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

    %{scope: scope, workspace: ws, project: project}
  end

  # ─── small helper: create a valid task doc, return the %Document{} ─────────

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # ─── (1) Happy path: add_dep + dependencies + dependents ───────────────────

  describe "add_dep/3 + dependencies/2 + dependents/2" do
    test "child blocks on parent: dependencies(child) returns [parent], dependents(parent) returns [child]",
         %{scope: scope} do
      parent = mk_task!("dep-parent-1", scope)
      child = mk_task!("dep-child-1", scope)

      assert {:ok, %Edge{from_id: from_id, to_id: to_id, kind: "blocks"}} =
               Tasks.add_dep(child.id, parent.id)

      assert from_id == child.id, "from_id MUST be the child (the dependent)"
      assert to_id == parent.id, "to_id MUST be the parent (the blocker)"

      # dependencies(child) -> blockers of child -> [parent]
      assert [%Document{id: pid}] = Tasks.dependencies(child.id)
      assert pid == parent.id

      # dependents(parent) -> who depends on parent -> [child]
      assert [%Document{id: cid}] = Tasks.dependents(parent.id)
      assert cid == child.id

      # Symmetric absence: parent has no blockers; child has no dependents.
      assert Tasks.dependencies(parent.id) == []
      assert Tasks.dependents(child.id) == []
    end

    test "child with many blockers — dependencies returns all of them in insert order",
         %{scope: scope} do
      a = mk_task!("multi-a", scope)
      b = mk_task!("multi-b", scope)
      c = mk_task!("multi-c", scope)
      child = mk_task!("multi-child", scope)

      {:ok, _} = Tasks.add_dep(child.id, a.id)
      {:ok, _} = Tasks.add_dep(child.id, b.id)
      {:ok, _} = Tasks.add_dep(child.id, c.id)

      ids = Tasks.dependencies(child.id) |> Enum.map(& &1.id)
      assert ids == [a.id, b.id, c.id], "expected insertion order, got #{inspect(ids)}"
    end

    test "rejects a self-edge", %{scope: scope} do
      task = mk_task!("self-edge", scope)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Tasks.add_dep(task.id, task.id)

      assert {_msg, _} = errors[:to_id]
    end

    test "rejects an unknown kind", %{scope: scope} do
      a = mk_task!("k-a", scope)
      b = mk_task!("k-b", scope)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Tasks.add_dep(a.id, b.id, :unknown_kind)

      assert {msg, _} = errors[:kind]
      assert msg =~ "must be one of"
    end

    test "rejects an FK target that doesn't exist (random uuid)", %{scope: scope} do
      real = mk_task!("fk-real", scope)
      ghost = Ecto.UUID.generate()

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Tasks.add_dep(real.id, ghost)

      # foreign_key_constraint surfaces on the column that was the dangling end.
      assert errors[:to_id] || errors[:from_id]
    end
  end

  # ─── (2) Idempotency: re-adding the same edge is a no-op ───────────────────

  describe "add_dep/3 idempotency" do
    test "adding the same (from, to, kind) twice returns {:ok, _} both times",
         %{scope: scope} do
      parent = mk_task!("idem-parent", scope)
      child = mk_task!("idem-child", scope)

      assert {:ok, %Edge{id: id1}} = Tasks.add_dep(child.id, parent.id)
      assert {:ok, %Edge{id: id2}} = Tasks.add_dep(child.id, parent.id)

      # The second call returns the SAME edge (no duplicate row created).
      assert id1 == id2

      assert [^id1] =
               Repo.all(Ecto.Query.from(e in Edge, where: e.from_id == ^child.id, select: e.id))
    end

    test "two DIFFERENT kinds between the same docs are NOT a conflict — both land",
         %{scope: scope} do
      parent = mk_task!("two-kinds-parent", scope)
      child = mk_task!("two-kinds-child", scope)

      assert {:ok, %Edge{kind: "blocks"}} =
               Tasks.add_dep(child.id, parent.id, :blocks)

      assert {:ok, %Edge{kind: "discovered-from"}} =
               Tasks.add_dep(child.id, parent.id, :"discovered-from")

      kinds =
        Tasks.edges(child.id, direction: :outbound)
        |> Enum.map(& &1.kind)
        |> Enum.sort()

      assert kinds == ["blocks", "discovered-from"]
    end
  end

  # ─── (3) remove_dep: removes specified, leaves siblings ────────────────────

  describe "remove_dep/3" do
    test "removes only the specified edge, leaves siblings intact", %{scope: scope} do
      parent = mk_task!("rem-parent", scope)
      other_parent = mk_task!("rem-other-parent", scope)
      child = mk_task!("rem-child", scope)

      {:ok, _} = Tasks.add_dep(child.id, parent.id)
      {:ok, _} = Tasks.add_dep(child.id, other_parent.id)

      assert :ok = Tasks.remove_dep(child.id, parent.id, :blocks)

      remaining_ids = Tasks.dependencies(child.id) |> Enum.map(& &1.id)
      assert remaining_ids == [other_parent.id]
    end

    test "removing an edge that doesn't exist is a no-op (still :ok)", %{scope: scope} do
      a = mk_task!("rem-ghost-a", scope)
      b = mk_task!("rem-ghost-b", scope)

      assert :ok = Tasks.remove_dep(a.id, b.id, :blocks)
    end

    test "remove_dep is kind-specific — the other kind survives", %{scope: scope} do
      parent = mk_task!("rem-kind-parent", scope)
      child = mk_task!("rem-kind-child", scope)

      {:ok, _} = Tasks.add_dep(child.id, parent.id, :blocks)
      {:ok, _} = Tasks.add_dep(child.id, parent.id, :"discovered-from")

      :ok = Tasks.remove_dep(child.id, parent.id, :blocks)

      kinds =
        Tasks.edges(child.id, direction: :outbound)
        |> Enum.map(& &1.kind)

      assert kinds == ["discovered-from"]
    end
  end

  # ─── (4) Kind discrimination ───────────────────────────────────────────────

  describe "kind discrimination" do
    test "blocks edges don't surface in discovered-from queries (and vice versa)",
         %{scope: scope} do
      blocker = mk_task!("kd-blocker", scope)
      ancestor = mk_task!("kd-ancestor", scope)
      child = mk_task!("kd-child", scope)

      {:ok, _} = Tasks.add_dep(child.id, blocker.id, :blocks)
      {:ok, _} = Tasks.add_dep(child.id, ancestor.id, :"discovered-from")

      # Default is :blocks — should ONLY see the blocker.
      assert [%Document{id: id}] = Tasks.dependencies(child.id)
      assert id == blocker.id

      # Explicit discovered-from filter — should ONLY see the ancestor.
      assert [%Document{id: id2}] =
               Tasks.dependencies(child.id, kind: :"discovered-from")

      assert id2 == ancestor.id

      # `:all` returns both.
      all_ids = Tasks.dependencies(child.id, kind: :all) |> Enum.map(& &1.id) |> Enum.sort()
      assert all_ids == Enum.sort([blocker.id, ancestor.id])
    end

    test "edges/2 :both direction returns inbound + outbound regardless of kind",
         %{scope: scope} do
      a = mk_task!("ed-a", scope)
      b = mk_task!("ed-b", scope)
      c = mk_task!("ed-c", scope)

      # a -> b (outbound of a)
      {:ok, _} = Tasks.add_dep(a.id, b.id, :blocks)
      # c -> a (inbound of a)
      {:ok, _} = Tasks.add_dep(c.id, a.id, :"discovered-from")

      ids =
        Tasks.edges(a.id, direction: :both)
        |> Enum.map(&{&1.from_id, &1.to_id, &1.kind})
        |> Enum.sort()

      expected =
        Enum.sort([
          {a.id, b.id, "blocks"},
          {c.id, a.id, "discovered-from"}
        ])

      assert ids == expected
    end
  end

  # ─── (5) Cascade — document delete reaps edges on both sides ───────────────

  describe "cascade on document delete" do
    test "deleting the parent document cascades the edge (to_id side)",
         %{scope: scope} do
      parent = mk_task!("casc-parent", scope)
      child = mk_task!("casc-child", scope)
      {:ok, %Edge{id: edge_id}} = Tasks.add_dep(child.id, parent.id)

      assert Repo.get(Edge, edge_id)

      Repo.delete!(parent)

      refute Repo.get(Edge, edge_id),
             "deleting the parent document should have cascade-deleted the edge (to_id FK on_delete: :delete_all)"
    end

    test "deleting the child document cascades the edge (from_id side)",
         %{scope: scope} do
      parent = mk_task!("casc-from-parent", scope)
      child = mk_task!("casc-from-child", scope)
      {:ok, %Edge{id: edge_id}} = Tasks.add_dep(child.id, parent.id)

      assert Repo.get(Edge, edge_id)

      Repo.delete!(child)

      refute Repo.get(Edge, edge_id),
             "deleting the child document should have cascade-deleted the edge (from_id FK on_delete: :delete_all)"
    end

    test "workspace delete cascades documents which in turn cascades their edges" do
      # Standalone workspace (not the shared default) so a wholesale delete
      # is safe inside the sandbox.
      ws = TenancyFixtures.create_workspace!()
      project = TenancyFixtures.create_project!(ws)
      scope = [workspace_id: ws.id, project_id: project.id]

      # Per-workspace schema registration so create_document/4 resolves.
      for schema_def <- Tasks.schema_definitions(@dataset) do
        attrs =
          schema_def
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        Content.upsert_schema(attrs, @dataset, scope)
      end

      parent = mk_task!("ws-casc-parent", scope)
      child = mk_task!("ws-casc-child", scope)
      {:ok, %Edge{id: edge_id}} = Tasks.add_dep(child.id, parent.id)

      assert Repo.get(Edge, edge_id)

      # The workspace cascade chain (20260527160000 + 20260527170000) deletes
      # the workspace -> projects -> datasets -> documents. The edge's FKs
      # then cascade with the document.
      Barkpark.Tenancy.delete_workspace(ws)

      refute Repo.get(Edge, edge_id),
             "workspace delete should have transitively cascade-deleted the edge"

      refute Repo.get(Document, parent.id)
      refute Repo.get(Document, child.id)
    end
  end

  # ─── (6) Tenancy — edges are a leaf relation, scoped by their endpoints ───

  describe "tenancy" do
    test "the edge table has NO scope columns of its own — scope rides via the docs" do
      # Defensive structural check — if anyone adds workspace_id/project_id/
      # dataset_id to task_edges in a future migration, this test catches it
      # and forces a deliberate review of the scope-via-endpoints contract
      # (see the moduledoc on the migration).
      assert %{__struct__: Edge} = struct(Edge, %{})

      fields = Edge.__schema__(:fields)
      refute :workspace_id in fields
      refute :project_id in fields
      refute :dataset_id in fields
    end

    test "an edge CAN be constructed between documents in different workspaces (no DB-level enforcement) — documented behaviour, callers must scope" do
      ws_a = TenancyFixtures.create_workspace!()
      proj_a = TenancyFixtures.create_project!(ws_a)
      ws_b = TenancyFixtures.create_workspace!()
      proj_b = TenancyFixtures.create_project!(ws_b)

      scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
      scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

      for ws_scope <- [scope_a, scope_b] do
        for schema_def <- Tasks.schema_definitions(@dataset) do
          attrs =
            schema_def
            |> Map.from_struct()
            |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
            |> Map.new(fn {k, v} -> {to_string(k), v} end)

          Content.upsert_schema(attrs, @dataset, ws_scope)
        end
      end

      task_a = mk_task!("ten-a", scope_a)
      task_b = mk_task!("ten-b", scope_b)

      # The edge table itself doesn't forbid this — the contract says
      # cross-workspace edges aren't a real path because callers go through
      # scoped reads to obtain document IDs. This test PINS that behaviour
      # so future "should we enforce it at the table?" reviews start from
      # ground truth.
      assert {:ok, %Edge{}} = Tasks.add_dep(task_a.id, task_b.id)
    end
  end
end
