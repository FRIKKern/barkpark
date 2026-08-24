defmodule Barkpark.Tasks.CloseAcknowledgementTest do
  @moduledoc """
  THE ACKNOWLEDGEMENT GATE — the fourth close honesty gate (the reporter loop).

  A `gh-<num>` row exists because somebody OUTSIDE this ledger filed a bug and
  can see nothing but their GitHub issue. Measured 2026-08-24: nine issues had
  been intaken; six were still open carrying exactly ONE comment — the bridge's
  own birth backlink, oldest 29 days old — while the defects had been fixed here,
  and the row that closed `done` over it carried ZERO acceptance criteria, so the
  D289 criteria gate was VACUOUSLY satisfied and could not see it.

  What this file pins:

    * the refusal fires on `done` AND on `cancelled`, and is EXEMPT on `blocked`;
    * `criteria_override` does NOT discharge it — the two are different
      admissions, and folding them is how the gap would reopen;
    * `ack_override` lands it with `close_override.acknowledgement` on the record;
    * an ordinary task — including an OUTBOUND-mirrored one carrying
      `content.github` — closes exactly as before. That negative is proven by
      closing one, not by reading the predicate.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.Acknowledgement
  alias Barkpark.Tasks.Close

  @dataset "production"

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

  defp uniq_issue, do: 900_000 + System.unique_integer([:positive])

  # An intake-born row, shaped exactly as `Github.Intake` births it.
  defp mk_intake!(scope, opts \\ []) do
    number = Keyword.get(opts, :issue, uniq_issue())
    doc_id = "gh-#{number}"

    criteria =
      case Keyword.fetch(opts, :criteria) do
        {:ok, list} -> list
        :error -> [Acknowledgement.criterion("FRIKKern/barkpark", number)]
      end

    content =
      %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "labels" => ["src:github", "needs-human"],
        "github" => %{
          "repo" => "FRIKKern/barkpark",
          "issue" => number,
          "state" => "intake"
        }
      }
      |> then(fn c ->
        if criteria == nil, do: c, else: Map.put(c, "acceptance_criteria", criteria)
      end)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => "outsider report ##{number}", "content" => content},
        @dataset,
        scope
      )

    {doc, number}
  end

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

  defp met_criterion(number),
    do:
      Map.merge(Acknowledgement.criterion("FRIKKern/barkpark", number), %{
        "met" => true,
        "evidence" => "https://github.com/FRIKKern/barkpark/issues/#{number}#issuecomment-1"
      })

  describe "the refusal" do
    test "a done close of an intake row with an unmet ack criterion is REFUSED", %{scope: scope} do
      {task, number} = mk_intake!(scope)

      assert {:error, {:acknowledgement_unposted, ^number}} =
               Close.close(task.id, "w", observed_epoch: 0, lifecycle_status: "done")

      # Nothing was written: the row is still open, so the refusal is a refusal
      # and not a decoration on a close that already landed.
      assert Repo.get!(Document, task.id).content["lifecycle_status"] == "open"
    end

    test "a ZERO-criteria intake row is refused too — the D289 gate cannot see it", %{
      scope: scope
    } do
      # This is the exact shape of every one of the nine orphaned rows: no
      # acceptance_criteria key at all. `check_criteria_proven` passes it
      # vacuously (an empty unmet list), so if this gate keyed on criteria
      # progress instead of on the flag it would wave the whole population
      # through — which is what happened to gh-11555.
      {task, number} = mk_intake!(scope, criteria: nil)

      assert Repo.get!(Document, task.id).content["acceptance_criteria"] == nil

      assert {:error, {:acknowledgement_unposted, ^number}} =
               Close.close(task.id, "w", observed_epoch: 0, lifecycle_status: "done")
    end

    test "a CANCELLED close is refused — silence is worst exactly when we say no", %{
      scope: scope
    } do
      {task, number} = mk_intake!(scope)

      assert {:error, {:acknowledgement_unposted, ^number}} =
               Close.close(task.id, "w", observed_epoch: 0, lifecycle_status: "cancelled")
    end

    test "a BLOCKED close is EXEMPT by name — the work continues, the answer is not due", %{
      scope: scope
    } do
      {task, _number} = mk_intake!(scope)

      assert {:ok, closed} =
               Close.close(task.id, "w", observed_epoch: 0, lifecycle_status: "blocked")

      assert closed.content["lifecycle_status"] == "blocked"
      refute Map.has_key?(closed.content, "close_override")
    end
  end

  describe "what discharges it" do
    test "a MET ack criterion lets the close land with no override at all", %{scope: scope} do
      number = uniq_issue()
      {task, ^number} = mk_intake!(scope, issue: number, criteria: [met_criterion(number)])

      assert {:ok, closed} =
               Close.close(task.id, "w", observed_epoch: 0, lifecycle_status: "done")

      assert closed.content["lifecycle_status"] == "done"
      refute Map.has_key?(closed.content, "close_override")
    end

    test "ack_override lands it and writes close_override.acknowledgement", %{scope: scope} do
      {task, number} = mk_intake!(scope)

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 ack_override: "duplicate of an issue already answered upstream"
               )

      record = closed.content["close_override"]["acknowledgement"]
      assert record["reason"] == "duplicate of an issue already answered upstream"
      assert record["actor"] == "w"
      assert record["issue"] == number
      assert record["had_criterion"] == true
      assert is_binary(record["ts"])

      # An override never flips the criterion — the reporter still has not been
      # told, and the row must not claim otherwise.
      assert closed.content["acceptance_criteria"] |> hd() |> Map.get("met") == false
    end

    test "a BLANK ack_override is not an override", %{scope: scope} do
      {task, number} = mk_intake!(scope)

      assert {:error, {:acknowledgement_unposted, ^number}} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 ack_override: "   "
               )
    end
  end

  describe "the two overrides are not interchangeable" do
    test "criteria_override does NOT discharge the acknowledgement gate", %{scope: scope} do
      number = uniq_issue()

      {task, ^number} =
        mk_intake!(scope,
          issue: number,
          criteria: [
            %{"criterion" => "the fix ships", "met" => false, "evidence" => ""},
            Acknowledgement.criterion("FRIKKern/barkpark", number)
          ]
        )

      # criteria_override buys past D289 — and then this gate still stops it.
      assert {:error, {:acknowledgement_unposted, ^number}} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria_override: "shipped, criterion wording is stale"
               )
    end

    test "ack_override deducts ONLY the ack criterion, never a neighbouring one", %{scope: scope} do
      number = uniq_issue()

      {task, ^number} =
        mk_intake!(scope,
          issue: number,
          criteria: [
            %{"criterion" => "the fix ships", "met" => false, "evidence" => ""},
            Acknowledgement.criterion("FRIKKern/barkpark", number)
          ]
        )

      # The ack override answers index 1 and is deducted from the D289 count, so
      # what comes back names index 0 ALONE. If the deduction were written by
      # "an ack override was passed" rather than by the ack rows' indices, this
      # would land and `ack_override` would quietly become a universal
      # criteria bypass.
      assert {:error, {:criteria_unmet, [0]}} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 ack_override: "reporter answered by email, not on the issue"
               )
    end

    test "both overrides together land, and BOTH are recorded separately", %{scope: scope} do
      number = uniq_issue()

      {task, ^number} =
        mk_intake!(scope,
          issue: number,
          criteria: [
            %{"criterion" => "the fix ships", "met" => false, "evidence" => ""},
            Acknowledgement.criterion("FRIKKern/barkpark", number)
          ]
        )

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria_override: "shipped, criterion wording is stale",
                 ack_override: "reporter answered by email, not on the issue"
               )

      override = closed.content["close_override"]
      assert override["criteria"]["reason"] == "shipped, criterion wording is stale"

      assert override["acknowledgement"]["reason"] ==
               "reporter answered by email, not on the issue"
    end
  end

  describe "the negative — ordinary tasks are untouched" do
    test "a plain task closes done exactly as before", %{scope: scope} do
      task = mk_task!("plain-#{System.unique_integer([:positive])}", scope, %{})

      assert {:ok, closed} =
               Close.close(task.id, "w", observed_epoch: 0, lifecycle_status: "done")

      assert closed.content["lifecycle_status"] == "done"
    end

    test "an OUTBOUND-mirrored task carrying content.github closes exactly as before", %{
      scope: scope
    } do
      # This is the population the gate must never touch: 7,832 rows carry
      # `content.github` because nearly every internal task is mirrored out to an
      # issue. They keep their `task-<hash>` slug, so the id-vs-issue pair check
      # excludes them — proven here by closing one, not by reading the regex.
      doc_id = "task-mirrored-#{System.unique_integer([:positive])}"

      task =
        mk_task!(doc_id, scope, %{
          "github" => %{
            "repo" => "FRIKKern/barkpark",
            "issue" => 13_754,
            "state" => "synced",
            "synced_rev" => "abc"
          }
        })

      assert {:ok, closed} =
               Close.close(task.id, "w", observed_epoch: 0, lifecycle_status: "done")

      assert closed.content["lifecycle_status"] == "done"
      refute Map.has_key?(closed.content, "close_override")
    end
  end
end
