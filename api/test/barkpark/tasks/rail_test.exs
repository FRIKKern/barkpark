defmodule Barkpark.Tasks.RailTest do
  @moduledoc """
  rail-l1 — digest tests for `Barkpark.Tasks.Rail`.

  The `rail_rev` ETag is deliberately CONSERVATIVE: any change to the rail's
  child set, a child's `(lifecycle_status, priority, rev)` tuple, or the
  `blocks` edges touching a child flips the digest. Covered here:

    * changes on child create, close, re-parent (in AND out), priority bump;
    * changes on a `blocks`-edge add/remove touching a child;
    * STABILITY under an edit to a NON-child task (a task in another rail);
    * `nil` parent → `nil` digest (a parentless task has no rail).

  Note: because a child's `rev` is a digest input, ANY edit to a child (even
  a description tweak) flips the digest — that is intended and documented in
  the module. Stability is therefore asserted against a NON-child edit, not a
  child description edit.
  """

  use Barkpark.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Internal
  alias Barkpark.Tasks.Rail

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

    %{scope: scope, opts: Keyword.put(scope, :dataset, @dataset)}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(doc_id, scope, content_extra) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # Faithful in-place content write: bumps `rev` exactly as every real task
  # write path does (Internal.generate_rev/0), so the digest sees the same
  # (content, rev) delta a re-parent / priority / close would produce.
  defp update_content!(%Document{} = doc, fun) do
    new_content = fun.(doc.content)

    {1, _} =
      from(d in Document, where: d.id == ^doc.id)
      |> Repo.update_all(
        set: [content: new_content, rev: Internal.generate_rev(), updated_at: DateTime.utc_now()]
      )

    %{doc | content: new_content}
  end

  describe "rev/2 — sensitivity to rail changes" do
    test "nil parent → nil digest (a parentless task has no rail)", %{opts: opts} do
      assert Rail.rev(nil, opts) == nil
    end

    test "stable across two reads of an unchanged rail", %{scope: scope, opts: opts} do
      parent = uniq("epic")
      _c1 = mk_task!(uniq("c"), scope, %{"parent_id" => parent})
      _c2 = mk_task!(uniq("c"), scope, %{"parent_id" => parent})

      rev1 = Rail.rev(parent, opts)
      rev2 = Rail.rev(parent, opts)

      assert is_binary(rev1)
      assert byte_size(rev1) == 16
      assert rev1 == rev2
    end

    test "changes on child create", %{scope: scope, opts: opts} do
      parent = uniq("epic")
      _c1 = mk_task!(uniq("c"), scope, %{"parent_id" => parent})
      before = Rail.rev(parent, opts)

      _c2 = mk_task!(uniq("c"), scope, %{"parent_id" => parent})
      after_ = Rail.rev(parent, opts)

      refute before == after_
    end

    test "changes on child close (lifecycle_status flip)", %{scope: scope, opts: opts} do
      parent = uniq("epic")
      child = mk_task!(uniq("c"), scope, %{"parent_id" => parent})
      before = Rail.rev(parent, opts)

      _ = update_content!(child, &Map.put(&1, "lifecycle_status", "done"))
      after_ = Rail.rev(parent, opts)

      refute before == after_
    end

    test "changes on child priority change", %{scope: scope, opts: opts} do
      parent = uniq("epic")
      child = mk_task!(uniq("c"), scope, %{"parent_id" => parent, "priority" => 3})
      before = Rail.rev(parent, opts)

      _ = update_content!(child, &Map.put(&1, "priority", 0))
      after_ = Rail.rev(parent, opts)

      refute before == after_
    end

    test "changes on re-parent OUT (child leaves the rail)", %{scope: scope, opts: opts} do
      parent = uniq("epic")
      keep = mk_task!(uniq("c"), scope, %{"parent_id" => parent})
      leaver = mk_task!(uniq("c"), scope, %{"parent_id" => parent})
      before = Rail.rev(parent, opts)

      _ = update_content!(leaver, &Map.put(&1, "parent_id", uniq("other-epic")))
      after_ = Rail.rev(parent, opts)

      refute before == after_
      # keep is still a child — sanity that the rail isn't empty now.
      assert Content.get_document(keep.doc_id, "task", @dataset, scope)
    end

    test "changes on re-parent IN (a task joins the rail)", %{scope: scope, opts: opts} do
      parent = uniq("epic")
      _c1 = mk_task!(uniq("c"), scope, %{"parent_id" => parent})
      outsider = mk_task!(uniq("out"), scope, %{"parent_id" => uniq("other-epic")})
      before = Rail.rev(parent, opts)

      _ = update_content!(outsider, &Map.put(&1, "parent_id", parent))
      after_ = Rail.rev(parent, opts)

      refute before == after_
    end

    test "changes on blocks-edge add then remove touching a child",
         %{scope: scope, opts: opts} do
      parent = uniq("epic")
      child = mk_task!(uniq("c"), scope, %{"parent_id" => parent})
      blocker = mk_task!(uniq("blk"), scope, %{})

      base = Rail.rev(parent, opts)

      # Add: child blocks on blocker (from_id = child, to_id = blocker).
      {:ok, _} = Tasks.add_dep(child.id, blocker.id, :blocks)
      with_edge = Rail.rev(parent, opts)
      refute base == with_edge

      # Remove: digest returns to the pre-edge value (edge set restored).
      :ok = Tasks.remove_dep(child.id, blocker.id, :blocks)
      after_remove = Rail.rev(parent, opts)
      assert after_remove == base
      refute after_remove == with_edge
    end

    test "STABLE under an edit to a NON-child task (another rail)",
         %{scope: scope, opts: opts} do
      parent = uniq("epic")
      _c1 = mk_task!(uniq("c"), scope, %{"parent_id" => parent})
      before = Rail.rev(parent, opts)

      # A task in a DIFFERENT rail — editing it must not move our digest.
      outsider = mk_task!(uniq("out"), scope, %{"parent_id" => uniq("other-epic")})
      _ = update_content!(outsider, &Map.put(&1, "description", "edited elsewhere"))

      after_ = Rail.rev(parent, opts)
      assert before == after_
    end
  end

  describe "unsatisfied_blockers/1" do
    test "returns unsatisfied blockers' doc_ids; empty when none / all satisfied",
         %{scope: scope} do
      task = mk_task!(uniq("t"), scope, %{})
      assert Tasks.unsatisfied_blockers(task.id) == []

      blocker = mk_task!(uniq("blk"), scope, %{})
      {:ok, _} = Tasks.add_dep(task.id, blocker.id, :blocks)
      assert Tasks.unsatisfied_blockers(task.id) == [blocker.doc_id]

      # Flip the blocker DONE AND ATTRIBUTABLE → no longer surfaced. A bare
      # `lifecycle_status: "done"` is NOT enough: the claim door refuses such a
      # blocker (Tasks.DependencySatisfaction — done AND a record of the close),
      # and this notice reads the same set, so the fixture has to close it the
      # way a close actually does. See the next test.
      _ =
        update_content!(blocker, fn c ->
          c
          |> Map.put("lifecycle_status", "done")
          |> Map.put("close_reason", "fixture: closed through the verb")
        end)

      assert Tasks.unsatisfied_blockers(task.id) == []
    end

    test "a blocker that reads done but records NO close still surfaces",
         %{scope: scope} do
      task = mk_task!(uniq("t-forged"), scope, %{})
      blocker = mk_task!(uniq("blk-forged"), scope, %{})
      {:ok, _} = Tasks.add_dep(task.id, blocker.id, :blocks)

      _ = update_content!(blocker, &Map.put(&1, "lifecycle_status", "done"))

      assert Tasks.unsatisfied_blockers(task.id) == [blocker.doc_id],
             "the claim door refuses an unattributable `done` blocker; the notice " <>
               "that exists to SAY WHY must not report the row as unblocked"
    end

    test "a blocker recorded only in content.dependencies surfaces too",
         %{scope: scope} do
      blocker = mk_task!(uniq("blk-json"), scope, %{})

      task =
        mk_task!(uniq("t-json"), scope, %{"dependencies" => [blocker.doc_id]})

      # No edge at all — the dependency lives only in the JSON list.
      assert Tasks.dependencies(task.id, kind: :blocks) == []

      assert Tasks.unsatisfied_blockers(task.id) == [blocker.doc_id],
             "task-814b2d28bdb4b2f5: this probe used to read `blocks` edges ONLY, so " <>
               "the claim door refused with blocked_by_unsatisfied_deps while the " <>
               "notice reported nothing blocking"

      _ =
        update_content!(blocker, fn c ->
          c
          |> Map.put("lifecycle_status", "done")
          |> Map.put("close_reason", "fixture: closed through the verb")
        end)

      assert Tasks.unsatisfied_blockers(task.id) == []
    end
  end
end
