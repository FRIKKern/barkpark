defmodule Barkpark.TasksTest do
  @moduledoc """
  W7a step 1 — task-document schema, field contract, validation, registration.

  Four surfaces under test (per the brief's VERIFY gate):

    1. **Schema registration** — after seed/boot, `Content.get_schema("task")`
       returns the registered SchemaDefinition; field shape matches the
       contract. Everything is a task — goal/phase/event types are gone.
    2. **Validation** — a task document with valid content creates fine;
       missing required fields (kind / lifecycle_status) is rejected with a
       clear error; invalid lifecycle_status value is rejected.
    3. **Hierarchy / tenancy** — a task document scoped to workspace A does
       not appear in a workspace B query (existing scope helpers carry
       through; tasks-as-documents inherits tenancy correctly).
    4. **Status-axis non-interference** — a task with
       `content.lifecycle_status="open"` still respects the existing
       `documents.status="draft"` flow on the SAME row (choice (b)).
  """

  use Barkpark.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.Tasks.{Close, Internal}

  @dataset "production"

  setup do
    # Register the task schema into the per-test sandbox so
    # `Content.get_schema/2` resolves it. Mirrors what seeds.exs +
    # Plugins.Bootstrap.register_all_schemas/0 do at boot. Idempotent.
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

  # ─── (1) Schema registration ──────────────────────────────────────────────

  describe "schema registration" do
    test "the task schema is queryable via Content.get_schema/2", %{scope: scope} do
      assert {:ok, %SchemaDefinition{name: "task"} = schema} =
               Content.get_schema("task", @dataset, scope)

      assert is_list(schema.fields) and schema.fields != []
      assert schema.visibility == "public"
    end

    test "goal/phase/event are NOT registered types", %{scope: scope} do
      for name <- ~w(goal phase event) do
        assert {:error, _} = Content.get_schema(name, @dataset, scope)
      end
    end

    test "the task schema's field list matches the §1 field contract", %{scope: scope} do
      {:ok, schema} = Content.get_schema("task", @dataset, scope)
      names = Enum.map(schema.fields, & &1["name"])

      for required <- ~w(kind lifecycle_status priority assignee dependencies claim parent_id) do
        assert required in names,
               "task schema missing field #{inspect(required)} (have #{inspect(names)})"
      end
    end

    test "Tasks.lifecycle_statuses/0 and Tasks.kinds/0 are stable contract" do
      # Five original states first (index-stable), then the two thought states
      # appended (task-lifecycle-visibility 5→7). "open means ready" still holds:
      # considering/researching are not in the ready/claim allowlist.
      assert Tasks.lifecycle_statuses() ==
               ~w(open in_progress blocked done cancelled considering researching)

      assert Tasks.kinds() == ~w(task)
    end
  end

  # ─── (2) Validation ───────────────────────────────────────────────────────

  describe "validate_task_content/1 (unit — direct)" do
    test "accepts the minimal valid task content (kind + lifecycle_status)" do
      assert :ok =
               Tasks.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "open"
               })
    end

    test "accepts a fully-populated task content map" do
      assert :ok =
               Tasks.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "in_progress",
                 "priority" => 2,
                 "assignee" => "agent-7",
                 "dependencies" => ["task-a", "task-b"],
                 "claim" => %{"worker" => "w-1", "ts_iso" => "2026-05-27T11:00:00Z", "epoch" => 3},
                 "parent_id" => "phase-build"
               })
    end

    test "rejects missing kind" do
      assert {:error, errors} =
               Tasks.validate_task_content(%{"lifecycle_status" => "open"})

      assert errors["kind"]
    end

    test "rejects wrong kind" do
      assert {:error, errors} =
               Tasks.validate_task_content(%{
                 "kind" => "goal",
                 "lifecycle_status" => "open"
               })

      assert errors["kind"]
    end

    test "rejects missing lifecycle_status" do
      assert {:error, errors} = Tasks.validate_task_content(%{"kind" => "task"})
      assert errors["lifecycle_status"]
    end

    test "rejects invalid lifecycle_status value" do
      assert {:error, errors} =
               Tasks.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "totally-invalid"
               })

      [msg] = errors["lifecycle_status"]
      assert msg =~ "must be one of"
      assert msg =~ "totally-invalid"
    end

    test "rejects every lifecycle_status outside the 5-value set" do
      for bad <- ~w(open- doing closed _open OPEN), reduce: :ok do
        _ ->
          assert {:error, %{"lifecycle_status" => _}} =
                   Tasks.validate_task_content(%{
                     "kind" => "task",
                     "lifecycle_status" => bad
                   })

          :ok
      end
    end

    test "rejects non-list dependencies" do
      assert {:error, errors} =
               Tasks.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "open",
                 "dependencies" => "not-a-list"
               })

      assert errors["dependencies"]
    end

    test "rejects dependencies list with non-string entries" do
      assert {:error, errors} =
               Tasks.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "open",
                 "dependencies" => ["valid-id", 42]
               })

      assert errors["dependencies"]
    end

    test "rejects priority outside 0..4" do
      assert {:error, errors} =
               Tasks.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "open",
                 "priority" => 9
               })

      assert errors["priority"]
    end
  end

  describe "validate_kind_content/2 — only `task` is a valid kind" do
    test "rejects the retired goal/phase/event kinds" do
      for kind <- ~w(goal phase event) do
        assert {:error, %{"kind" => _}} = Tasks.validate_kind_content(kind, %{})
      end
    end

    test "rejects unknown kinds" do
      assert {:error, %{"kind" => _}} = Tasks.validate_kind_content("widget", %{})
    end
  end

  describe "Content.create_document/4 (integration — wired hook)" do
    test "creates a valid task document via the canonical write path", %{scope: scope} do
      assert {:ok, %Document{} = doc} =
               Content.create_document(
                 "task",
                 %{
                   "doc_id" => "t-valid-1",
                   "title" => "wire-bridge",
                   "content" => %{
                     "kind" => "task",
                     "lifecycle_status" => "open",
                     "priority" => 1
                   }
                 },
                 @dataset,
                 scope
               )

      assert doc.type == "task"
      assert doc.content["lifecycle_status"] == "open"
      # documents.status defaults to "draft" — choice (b): the lifecycle axis
      # is on content, the draft/published axis stays on documents.status.
      assert doc.status == "draft"
    end

    test "rejects a task document missing content.kind", %{scope: scope} do
      assert {:error, {:invalid_task_content, errors}} =
               Content.create_document(
                 "task",
                 %{
                   "doc_id" => "t-bad-1",
                   "title" => "missing-kind",
                   "content" => %{"lifecycle_status" => "open"}
                 },
                 @dataset,
                 scope
               )

      assert errors["kind"]
    end

    test "rejects a task document with an unknown lifecycle_status", %{scope: scope} do
      assert {:error, {:invalid_task_content, errors}} =
               Content.create_document(
                 "task",
                 %{
                   "doc_id" => "t-bad-2",
                   "title" => "bad-status",
                   "content" => %{"kind" => "task", "lifecycle_status" => "doing"}
                 },
                 @dataset,
                 scope
               )

      [msg] = errors["lifecycle_status"]
      assert msg =~ "must be one of"
    end

    test "rejects a task document missing content.lifecycle_status", %{scope: scope} do
      assert {:error, {:invalid_task_content, errors}} =
               Content.create_document(
                 "task",
                 %{
                   "doc_id" => "t-bad-3",
                   "title" => "missing-lifecycle",
                   "content" => %{"kind" => "task"}
                 },
                 @dataset,
                 scope
               )

      assert errors["lifecycle_status"]
    end

    test "non-task types (e.g. post) are unaffected by the task hook", %{scope: scope} do
      assert {:ok, %Document{} = doc} =
               Content.create_document(
                 "post",
                 %{
                   "doc_id" => "p-untouched-1",
                   "title" => "a post — no task validation runs"
                 },
                 @dataset,
                 scope
               )

      assert doc.type == "post"
    end
  end

  # ─── (3) Hierarchy / tenancy — sanity check the task type rides scope ────

  describe "tenancy — task documents scope by workspace like every other type" do
    test "a task in workspace A is invisible to a workspace B reader" do
      ws_a = TenancyFixtures.create_workspace!()
      proj_a = TenancyFixtures.create_project!(ws_a)
      ws_b = TenancyFixtures.create_workspace!()
      proj_b = TenancyFixtures.create_project!(ws_b)

      # The schema_definitions for "task" must be visible from BOTH workspaces.
      # Re-register them under each (Content.get_schema's NULL-tolerant scope
      # lets a default-scoped schema serve all tenants, but be explicit so a
      # test sandbox without a Default falls through.)
      for ws <- [ws_a, ws_b], project <- [proj_a, proj_b] do
        if ws.id == proj_a.workspace_id and project == proj_a do
          register_schemas_under(ws, project)
        end

        if ws.id == proj_b.workspace_id and project == proj_b do
          register_schemas_under(ws, project)
        end
      end

      scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
      scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

      {:ok, _doc} =
        Content.create_document(
          "task",
          %{
            "doc_id" => "scoped-task-a",
            "title" => "only in workspace A",
            "content" => %{"kind" => "task", "lifecycle_status" => "open"}
          },
          "test",
          scope_a
        )

      a_ids =
        Content.list_documents("task", "test", [perspective: :raw] ++ scope_a)
        |> Enum.map(& &1.doc_id)

      b_ids =
        Content.list_documents("task", "test", [perspective: :raw] ++ scope_b)
        |> Enum.map(& &1.doc_id)

      assert "drafts.scoped-task-a" in a_ids or "scoped-task-a" in a_ids,
             "expected A's task to be visible under A's scope, got #{inspect(a_ids)}"

      refute "drafts.scoped-task-a" in b_ids,
             "CROSS-WORKSPACE LEAK: A's task surfaced under B's scope (#{inspect(b_ids)})"

      refute "scoped-task-a" in b_ids
    end

    defp register_schemas_under(ws, project) do
      scope = [workspace_id: ws.id, project_id: project.id]

      for schema_def <- Tasks.schema_definitions("test") do
        attrs =
          schema_def
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        Content.upsert_schema(attrs, "test", scope)
      end
    end
  end

  # ─── (4) Status-axis non-interference (choice (b)) ────────────────────────

  describe "status axis non-interference" do
    test "documents.status (draft/published) and content.lifecycle_status are independent",
         %{scope: scope} do
      # A task can hold ANY lifecycle_status while documents.status is "draft":
      # the draft/published flow and the open/in_progress/.../cancelled flow
      # are orthogonal axes, which is exactly what choice (b) is for.
      for ls <- Tasks.lifecycle_statuses() do
        doc_id = "axis-test-#{ls}"

        assert {:ok, %Document{} = doc} =
                 Content.create_document(
                   "task",
                   %{
                     "doc_id" => doc_id,
                     "title" => "axis #{ls}",
                     "content" => %{"kind" => "task", "lifecycle_status" => ls}
                   },
                   @dataset,
                   scope
                 )

        assert doc.status == "draft", "documents.status was clobbered when lifecycle_status=#{ls}"
        assert doc.content["lifecycle_status"] == ls
      end
    end

    test "the DB CHECK constraint rejects a raw insert with a malformed lifecycle_status",
         %{workspace: ws, project: project} do
      # Defense-in-depth: bypass the application validator with a raw
      # Repo.insert and confirm the migration's check constraint catches the
      # bogus lifecycle_status. The 5-value enum lives in BOTH layers.
      attrs = %{
        doc_id: "raw-insert-bypass",
        type: "task",
        dataset: @dataset,
        title: "should be rejected at the DB",
        status: "draft",
        content: %{"kind" => "task", "lifecycle_status" => "totally-bogus"},
        rev: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
        workspace_id: ws.id,
        project_id: project.id
      }

      # Ecto translates the Postgres CHECK violation to either
      # Postgrex.Error (when the changeset hasn't declared the constraint)
      # or Ecto.ConstraintError. Either confirms the DB-level guard fired.
      err =
        assert_raise(Ecto.ConstraintError, fn ->
          %Document{}
          |> Document.changeset(attrs)
          |> Repo.insert!()
        end)

      assert Exception.message(err) =~ "documents_task_lifecycle_status_check"
    end

    test "the DB CHECK constraint allows a task row that omits lifecycle_status entirely",
         %{workspace: ws, project: project} do
      # The migration deliberately tolerates absent `lifecycle_status` so the
      # importer (W7-d) can stage a row before stamping the field. Application
      # validation rejects this case, but at the DB layer it's fine.
      attrs = %{
        doc_id: "raw-insert-no-lifecycle",
        type: "task",
        dataset: @dataset,
        title: "lifecycle absent — DB allows",
        status: "draft",
        content: %{"kind" => "task"},
        rev: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
        workspace_id: ws.id,
        project_id: project.id
      }

      assert {:ok, _} =
               %Document{}
               |> Document.changeset(attrs)
               |> Repo.insert()
    end
  end

  # ─── close-drift recovery contract (S2, task-1471170216ac6b54) ─────────────
  #
  # The doc_changed_since_claim fence is recoverable ONLY by pinning the current
  # rev as observed_rev. The old guidance ("re-read, then close again") is a dead
  # end: a same-worker re-read RENEWS the lease but do_renew deliberately keeps
  # the ORIGINAL claim's work_digest (claim.ex:357), so the fence still fires.
  # These tests weld the true recovery sequence shut against regression.

  defp s2_uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp s2_mk_task!(doc_id, scope, content_extra) do
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

  # Rewrite content while PRESERVING the claim (its work_digest stays put) — the
  # "a reviewer edited the brief while I held the claim" race the fence exists for.
  defp s2_foreign_patch!(task_id, patch) do
    doc = Repo.get!(Document, task_id)
    new_content = Map.merge(doc.content, patch)

    {1, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev)
      |> Repo.update_all(set: [content: new_content, rev: Internal.generate_rev()])

    :ok
  end

  describe "close/3 — re-read is a dead end; observed_rev is the recovery (S2 regression)" do
    test "(a) a same-worker re-read/renewal preserves the claim work_digest, so a plain close STILL 409s doc_changed_since_claim",
         %{scope: scope} do
      doc_id = s2_uniq("s2-reread")
      task = s2_mk_task!(doc_id, scope, %{"description" => "original brief"})

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w", scope)
      epoch = claimed.content["claim"]["epoch"]

      # A reviewer rewrites the brief under the claim.
      :ok = s2_foreign_patch!(task.id, %{"description" => "reviewer-rewritten brief"})

      # The worker tries to "refresh" the way the OLD hint implies — a same-worker
      # re-claim (renewal). It mints a FRESH epoch (so a later close clears the
      # epoch fence) but do_renew DELIBERATELY keeps the ORIGINAL work_digest
      # (`do_renew/3` in claim.ex). The re-read/renewal reconciled nothing the fence compares.
      assert {:ok, renewed} = Tasks.claim_by_id(doc_id, "w", scope)
      fresh_epoch = renewed.content["claim"]["epoch"]
      assert fresh_epoch != epoch

      # Closing with that fresh epoch and NO observed_rev therefore STILL repeats
      # the SAME 409, and the response hands back the current rev + the changed
      # field so the worker need not infer which value to pass.
      assert {:error, {:doc_changed_since_claim, current_rev, changed}} =
               Close.close(task.id, "w", observed_epoch: fresh_epoch, lifecycle_status: "done")

      assert changed == ["description"]
      assert current_rev == Repo.get!(Document, task.id).rev
      assert Repo.get!(Document, task.id).content["lifecycle_status"] == "in_progress"
    end

    test "(b) closing with observed_rev = the current rev the 409 named succeeds",
         %{scope: scope} do
      doc_id = s2_uniq("s2-observed-ok")
      task = s2_mk_task!(doc_id, scope, %{"description" => "original brief"})

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w", scope)
      epoch = claimed.content["claim"]["epoch"]

      :ok = s2_foreign_patch!(task.id, %{"description" => "reviewer-rewritten brief"})

      # First close 409s and NAMES the current rev to reconcile against.
      assert {:error, {:doc_changed_since_claim, current_rev, _changed}} =
               Close.close(task.id, "w", observed_epoch: epoch, lifecycle_status: "done")

      # The documented recovery: pass that exact current rev as observed_rev. It
      # switches to strict full-rev CAS, bypasses the digest fence, and lands.
      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: epoch,
                 observed_rev: current_rev,
                 lifecycle_status: "done"
               )

      assert closed.content["lifecycle_status"] == "done"
    end

    test "(c) a STALE observed_rev still loses the full-rev CAS — the guard is not blanket-bypassed",
         %{scope: scope} do
      doc_id = s2_uniq("s2-stale-rev")
      task = s2_mk_task!(doc_id, scope, %{"description" => "original brief"})

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w", scope)
      epoch = claimed.content["claim"]["epoch"]
      stale_rev = claimed.rev

      # A concurrent write moves the rev on after the worker's read.
      :ok = s2_foreign_patch!(task.id, %{"description" => "moved on after the read"})

      # A stale observed_rev opts into strict full-rev CAS and loses it — the
      # recovery escape hatch never becomes an unconditional bypass.
      assert {:error, :stale_claim} =
               Close.close(task.id, "w",
                 observed_epoch: epoch,
                 observed_rev: stale_rev,
                 lifecycle_status: "done"
               )

      assert Repo.get!(Document, task.id).content["lifecycle_status"] == "in_progress"
    end
  end
end
