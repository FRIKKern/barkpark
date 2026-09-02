defmodule Barkpark.Tasks.CloseArtifactTest do
  @moduledoc """
  THE CLOSE ARTIFACT GATE (PDS-D291) — the hole D289 cannot see.

  D289 measures the acceptance criteria a row HAS. On a row with NONE it is
  vacuously satisfied — `unmet_criteria/1` returns `[]` — so a `done` close
  landed on whatever prose the closer typed. LEAD3-jsweb measured 14 of 15
  closes in one lane sitting on exactly that shape, and the `gh-11555` close
  the acknowledgement gate was built for went through the same hole.

  Main's ruling on task-ce0c0ffff6edde23 (2026-09-02) is what this pins:
  "a row with ZERO acceptance criteria may close done only when its
  close_reason names the merged PR number + sha (or the run output) that
  discharged its title; if no such artifact exists it is NOT done — add
  criteria or cancel with the reason. A merge condition written only in prose
  does not bind."

  RED-WITHOUT / GREEN-WITH. On origin/main every `refuses` test below returns
  `{:ok, doc}` — that is the defect. Every `exempt`/`accepts` test is green on
  origin/main too, and must STAY green: a gate that also refuses the shapes the
  ruling exempts has not implemented the ruling, it has replaced it.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Close, Internal}
  alias BarkparkWeb.TasksController.Params

  @dataset "production"

  # A real artifact: a PR number AND a 7-40 hex sha, the shape the ruling names.
  @artifact "landed #14383 @ 63b89bef30 — one envelope reader"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
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

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # The shape the ruling is about: kind:task, ZERO acceptance criteria, no
  # labels, no children. Unclaimed on purpose — `check_fencing/2` and
  # `check_close_holder/3` both pass cleanly on an unclaimed row, so the ONLY
  # gate a close of this fixture can trip is the one under test.
  defp mk_task!(scope, content_extra \\ %{}) do
    doc_id = uniq("bare-task")
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

  # A raw content write, CAS'd on the observed rev — the only way to produce a
  # row whose `kind` is not "task", since `Tasks.Validation` refuses one at birth.
  defp patch_kind!(%Document{} = doc, kind) do
    stored = Repo.get!(Document, doc.id)

    {1, _} =
      from(d in Document, where: d.id == ^stored.id and d.rev == ^stored.rev)
      |> Repo.update_all(
        set: [content: Map.put(stored.content, "kind", kind), rev: Internal.generate_rev()]
      )

    :ok
  end

  defp close(%Document{} = doc, opts) do
    Close.close(doc.id, "worker-1", Keyword.merge([observed_epoch: 1], opts))
  end

  # ─── The refusal ────────────────────────────────────────────────────────

  describe "done close of a criteria-less task row" do
    test "is REFUSED when the reason is bare prose", %{scope: scope} do
      doc = mk_task!(scope)

      assert {:error, :close_reason_needs_artifact} =
               close(doc, reason: "done — the merge condition is satisfied")

      # Nothing was written: the refusal aborts before any content write, so the
      # row is still closeable the honest way. A gate that refused AFTER the
      # flip would leave a `done` row wearing a refusal.
      assert %Document{content: %{"lifecycle_status" => "open"}} = Repo.get!(Document, doc.id)
    end

    test "is REFUSED when there is no reason at all", %{scope: scope} do
      doc = mk_task!(scope)
      assert {:error, :close_reason_needs_artifact} = close(doc, [])
    end

    test "is REFUSED when the reason names a PR but no sha", %{scope: scope} do
      doc = mk_task!(scope)
      assert {:error, :close_reason_needs_artifact} = close(doc, reason: "merged in #14383")
    end

    test "is REFUSED when the reason names a sha but no PR", %{scope: scope} do
      doc = mk_task!(scope)
      assert {:error, :close_reason_needs_artifact} = close(doc, reason: "shipped as 63b89bef30")
    end

    # The label rule is SEGMENT-wise, not substring. A mission label that merely
    # CONTAINS "goal" must not buy an exemption — a silent permit is the failure
    # mode this family of gates exists to end.
    test "is REFUSED on a row whose label merely contains the word goal", %{scope: scope} do
      doc = mk_task!(scope, %{"labels" => ["proj:goalkeeper-rewrite"]})
      assert {:error, :close_reason_needs_artifact} = close(doc, reason: "done")
    end

    # criteria_override is the flag callers reach for reflexively. If it bought
    # this refusal too, the rare admission would be discharged by the routine one.
    test "criteria_override does NOT discharge it", %{scope: scope} do
      doc = mk_task!(scope)

      assert {:error, :close_reason_needs_artifact} =
               close(doc, reason: "done", criteria_override: "the criteria were never written")
    end

    # A blank override is not an override — the same rule the other three gates
    # apply (`override_reason/1`), asserted here so an empty string cannot be
    # used to launder this one.
    test "a blank close_reason_override is not an override", %{scope: scope} do
      doc = mk_task!(scope)

      assert {:error, :close_reason_needs_artifact} =
               close(doc, reason: "done", close_reason_override: "   ")
    end
  end

  # ─── What discharges it ─────────────────────────────────────────────────

  describe "an artifact in the close_reason" do
    test "a PR number AND a sha lands the close", %{scope: scope} do
      doc = mk_task!(scope)
      assert {:ok, %Document{content: content}} = close(doc, reason: @artifact)
      assert content["lifecycle_status"] == "done"
      # No override was needed, so no override record is written.
      refute Map.has_key?(content, "close_override")
    end

    test "a fenced run block lands the close", %{scope: scope} do
      doc = mk_task!(scope)

      reason = """
      verified by running the gate:

      ```
      12 tests, 0 failures
      ```
      """

      assert {:ok, %Document{content: %{"lifecycle_status" => "done"}}} =
               close(doc, reason: reason)
    end

    test "a pasted `$ ` command line lands the close", %{scope: scope} do
      doc = mk_task!(scope)

      reason =
        "proved it:\n  $ mix test test/barkpark/tasks/close_test.exs\n  74 tests, 0 failures"

      assert {:ok, %Document{content: %{"lifecycle_status" => "done"}}} =
               close(doc, reason: reason)
    end

    # The STRUCTURED twin of the prose form. A lead seal close rides a `landed`
    # digest naming the PR and the merge commit; demanding those same two facts
    # be retyped into prose would break that ritual for no gain.
    test "a landed digest naming both a PR and a commit lands the close", %{scope: scope} do
      doc = mk_task!(scope)

      assert {:ok, %Document{content: %{"lifecycle_status" => "done"}}} =
               close(doc,
                 reason: "sealed",
                 landed: %{"prs" => [14_383], "commit" => "63b89bef30"}
               )
    end

    # The merge-event bridge writes `commits` (a LIST) where the lead seal writes
    # `commit` (a scalar) — `landed_summary/1` already reads both, so the gate
    # must too. Reading only one of them would refuse half the sealed closes in
    # the repo while the close's own receipt line names the merge.
    test "the merge-event `commits` list counts, not just the seal's `commit`",
         %{scope: scope} do
      doc = mk_task!(scope)

      assert {:ok, %Document{content: %{"lifecycle_status" => "done"}}} =
               close(doc,
                 reason: "sealed",
                 landed: %{"prs" => [14_383], "commits" => ["63b89bef30"]}
               )
    end

    test "a landed digest with a PR but NO commit does not", %{scope: scope} do
      doc = mk_task!(scope)

      assert {:error, :close_reason_needs_artifact} =
               close(doc, reason: "sealed", landed: %{"prs" => [14_383]})
    end

    test "close_reason_override lands it and is recorded on the row", %{scope: scope} do
      doc = mk_task!(scope)

      assert {:ok, %Document{content: content}} =
               close(doc,
                 reason: "done",
                 close_reason_override: "the work was a decision, recorded in the paper"
               )

      assert content["lifecycle_status"] == "done"
      record = get_in(content, ["close_override", "close_reason"])
      assert record["reason"] == "the work was a decision, recorded in the paper"
      assert record["actor"] == "worker-1"
      assert is_binary(record["ts"])
      # The other three gates' records are untouched — one key per admission.
      refute Map.has_key?(content["close_override"], "criteria")
    end
  end

  # ─── Exempt BY NAME ─────────────────────────────────────────────────────

  describe "shapes the ruling exempts" do
    test "cancelled and blocked close on a bare reason", %{scope: scope} do
      for status <- ~w(cancelled blocked) do
        doc = mk_task!(scope)

        assert {:ok, %Document{content: content}} =
                 close(doc, lifecycle_status: status, reason: "not doing this")

        assert content["lifecycle_status"] == status
      end
    end

    test "a row that carries acceptance criteria is D289's business, not this gate's",
         %{scope: scope} do
      doc =
        mk_task!(scope, %{
          "acceptance_criteria" => [%{"criterion" => "the gate is green", "met" => true}]
        })

      assert {:ok, %Document{content: %{"lifecycle_status" => "done"}}} =
               close(doc, reason: "done — no PR, no sha, and that is fine here")
    end

    test "a row with criteria still hears criteria_unmet, never this refusal", %{scope: scope} do
      doc =
        mk_task!(scope, %{
          "acceptance_criteria" => [%{"criterion" => "the gate is green", "met" => false}]
        })

      assert {:error, {:criteria_unmet, [0]}} = close(doc, reason: "done")
    end

    # `Validation.kinds/0` is `~w(task)`, so a non-task kind cannot be BORN
    # through `create_document` — it is refused at the write path. The exemption
    # exists for rows that already carry one (a legacy or foreign write), which
    # is what the raw content patch below reproduces. Asserting the refusal at
    # birth first is what keeps this test honest about which door the shape
    # comes through.
    test "kind other than task is exempt", %{scope: scope} do
      assert {:error, {:invalid_task_content, %{"kind" => _}}} =
               Content.create_document(
                 "task",
                 %{
                   "doc_id" => uniq("epic"),
                   "title" => "epic",
                   "content" => %{"kind" => "epic", "lifecycle_status" => "open"}
                 },
                 @dataset,
                 scope
               )

      doc = mk_task!(scope)
      patch_kind!(doc, "epic")

      assert {:ok, %Document{content: %{"lifecycle_status" => "done"}}} =
               close(doc, reason: "done")
    end

    # TASK-SYSTEM.md §5: "Real work tasks carry acceptance_criteria … Decisions
    # and goals may omit them." The vocabulary is the bare gate label plus the
    # `phase:<…>` / `kind:<…>` forms, so every segment shape must exempt.
    test "a decision or goal label segment is exempt", %{scope: scope} do
      for labels <- [["decision"], ["goal"], ["phase:goal"], ["proj:x", "phase:decision"]] do
        doc = mk_task!(scope, %{"labels" => labels})

        # Bound first, then asserted on a BOOLEAN: `assert pattern = expr, msg`
        # raises MatchError before assert/2 can ever reach its message, so the
        # label that failed would be invisible — and naming it is the whole
        # point of looping over four label shapes.
        result = close(doc, reason: "done")

        assert match?({:ok, %Document{content: %{"lifecycle_status" => "done"}}}, result),
               "labels #{inspect(labels)} should be exempt, got #{inspect(result)}"
      end
    end

    # NOT an invented rule: the board decides goal-ness by `parent_id` (the
    # `:goal` swimlane groups on it) and Tasks.Schema says "a goal is a root
    # task, a phase is a task with children". A row somebody names as parent is
    # a container in that exact vocabulary; its artifacts live on its children.
    test "a row that HAS children is exempt", %{scope: scope} do
      parent = mk_task!(scope)
      _child = mk_task!(scope, %{"parent_id" => parent.doc_id})

      assert {:ok, %Document{content: %{"lifecycle_status" => "done"}}} =
               close(parent, reason: "every rail landed")
    end

    test "the same row with its child removed is refused again", %{scope: scope} do
      parent = mk_task!(scope)
      child = mk_task!(scope, %{"parent_id" => parent.doc_id})

      # Proves the exemption is CAUSED by the child and not by something else
      # about the fixture — the same row, one fact different, opposite verdict.
      Repo.delete!(Repo.get!(Document, child.id))
      assert {:error, :close_reason_needs_artifact} = close(parent, reason: "every rail landed")
    end
  end

  # ─── The hint (the refusal must TEACH) ──────────────────────────────────

  describe "the 409 hint" do
    test "quotes the ruling and names both the honest exits and the override" do
      hint = Params.criteria_hint(:close_reason_needs_artifact, :close)

      assert is_binary(hint)
      # The ruling, verbatim — the refusal's whole content.
      assert hint =~
               "a row with ZERO acceptance criteria may close done only when its close_reason names the merged PR"

      assert hint =~ "A merge condition written only in prose does not bind."
      # The honest exits the ruling itself names come BEFORE the override.
      assert hint =~ "add criteria or cancel with the reason"
      assert hint =~ ~s|--set close_reason_override=|
      # And the wire token stays the machine-readable contract.
      assert Params.reason_to_string(:close_reason_needs_artifact) ==
               "close_reason_needs_artifact"
    end
  end
end
