defmodule Barkpark.Tasks.StampAmendConfirmTest do
  @moduledoc """
  THE SECOND PAIR OF EYES ON AN AMENDED CRITERION (task-e9c6aa61af536112).

  The worker who amends a criterion's wording cannot stamp it met, or close
  `done` over it met, until a DIFFERENT worker confirms the new wording with
  `--confirm-amendment`. A stamp on a criterion nobody amended is unchanged.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Tasks.{AmendmentConfirmation, Close, Internal, Stamp, Validation}
  alias BarkparkWeb.TasksController.Params

  import Ecto.Query, only: [from: 2]

  @dataset "production"

  @c0 "the importer keeps every heading"
  @c1 "docs updated"
  @new_c0 "the importer keeps every heading and every table"
  @evidence "PR #24999 merged to main as 9b76b4bfc9"

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

    doc_id = "amend-confirm-#{System.unique_integer([:positive])}"

    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "description" => "a row whose criterion gets reworded mid-claim",
            "acceptance_criteria" => [
              %{"criterion" => @c0, "met" => false, "evidence" => ""},
              %{"criterion" => @c1, "met" => true, "evidence" => "docs/x.md"}
            ]
          }
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(doc_id, "builder", scope)
    %{task: task, doc_id: doc_id, scope: scope, epoch: claimed.content["claim"]["epoch"]}
  end

  defp reload(task), do: Repo.get!(Document, task.id)
  defp entry(task, i), do: Enum.at(reload(task).content["acceptance_criteria"], i)

  defp amend!(task, epoch, worker \\ "builder", from \\ @c0, to \\ @new_c0) do
    {:ok, _} =
      Stamp.stamp(task.id, worker,
        observed_epoch: epoch,
        criterion: 0,
        criterion_text: from,
        outcome: {:amend, {to, "the old wording missed tables"}}
      )
  end

  defp met(task, epoch, text \\ @new_c0) do
    Stamp.stamp(task.id, "builder",
      observed_epoch: epoch,
      criterion: 0,
      criterion_text: text,
      outcome: {:met, @evidence}
    )
  end

  defp confirm(task, worker, opts \\ []) do
    Stamp.stamp(task.id, worker,
      observed_epoch: 0,
      criterion: Keyword.get(opts, :criterion, 0),
      criterion_text: Keyword.get(opts, :text, @new_c0),
      observed_rev: Keyword.get(opts, :rev, reload(task).rev),
      outcome: {:confirm, "read the new wording against the importer tests"}
    )
  end

  describe "the amender's own --met" do
    test "is refused while the amendment is unconfirmed, and nothing is written",
         %{task: task, epoch: epoch} do
      amend!(task, epoch)
      rev = reload(task).rev

      assert {:error, {:amendment_unconfirmed, [0]}} = met(task, epoch)

      assert reload(task).rev == rev
      assert entry(task, 0)["met"] == false
      assert entry(task, 0)["evidence"] == ""
    end

    test "goes through once a different worker confirms the new wording",
         %{task: task, epoch: epoch} do
      amend!(task, epoch)

      assert {:ok, _} = confirm(task, "reviewer")
      assert {:ok, _} = met(task, epoch)

      e = entry(task, 0)
      assert e["met"] == true
      assert e["evidence"] == @evidence

      assert [%{"worker" => "reviewer", "amendment" => 1, "note" => note}] = e["confirmations"]
      assert note =~ "importer tests"
    end

    test "a second amendment needs its own confirmation", %{task: task, epoch: epoch} do
      amend!(task, epoch)
      assert {:ok, _} = confirm(task, "reviewer")
      amend!(task, epoch, "builder", @new_c0, @c0)

      assert {:error, {:amendment_unconfirmed, [0]}} = met(task, epoch, @c0)

      assert {:ok, _} = confirm(task, "reviewer", text: @c0)
      assert {:ok, _} = met(task, epoch, @c0)
    end

    test "only the LAST amender waits: a worker whose wording was re-amended by another may stamp" do
      entry = %{
        "criterion" => @c0,
        "amendments" => [%{"worker" => "builder"}, %{"worker" => "reviewer"}]
      }

      assert AmendmentConfirmation.awaiting_amender(entry) == "reviewer"
    end

    test "a confirmation by the amender never counts" do
      entry = %{
        "criterion" => @c0,
        "amendments" => [%{"worker" => "builder"}],
        "confirmations" => [%{"worker" => "builder", "amendment" => 1}]
      }

      assert AmendmentConfirmation.awaiting_amender(entry) == "builder"
    end
  end

  describe "a stamp with no amendment is unchanged" do
    test "the holder's --met lands exactly as before", %{task: task, epoch: epoch} do
      assert {:ok, _} = met(task, epoch, @c0)

      e = entry(task, 0)
      assert e == %{"criterion" => @c0, "met" => true, "evidence" => @evidence}
    end

    test "another worker's amendment does not block the holder",
         %{task: task, doc_id: doc_id, scope: scope} do
      {:ok, _} =
        Close.close(task.id, "builder",
          observed_epoch: reload(task).content["claim"]["epoch"],
          lifecycle_status: "blocked",
          reason: "waiting on review"
        )

      {:ok, _} =
        Stamp.stamp(task.id, "reviewer",
          observed_epoch: 0,
          criterion: 0,
          criterion_text: @c0,
          observed_rev: reload(task).rev,
          outcome: {:amend, {@new_c0, "the reviewer corrected the wording"}}
        )

      {:ok, reclaimed} = Tasks.claim_by_id(doc_id, "builder", scope)
      assert {:ok, _} = met(task, reclaimed.content["claim"]["epoch"])
    end
  end

  describe "--confirm-amendment refusals (each writes nothing)" do
    test "the amender cannot confirm their own wording", %{task: task, epoch: epoch} do
      amend!(task, epoch)
      rev = reload(task).rev

      assert {:error, :self_confirmation} = confirm(task, "builder")
      assert reload(task).rev == rev
    end

    test "a never-amended criterion has nothing to confirm", %{task: task} do
      assert {:error, :nothing_to_confirm} = confirm(task, "reviewer", text: @c0)
    end

    test "no rev, a stale rev, no text, the old text, past the end", %{task: task, epoch: epoch} do
      amend!(task, epoch)
      rev = reload(task).rev

      assert {:error, :observed_rev_required} = confirm(task, "reviewer", rev: nil)
      assert {:error, :stale_claim} = confirm(task, "reviewer", rev: "not-the-rev")
      assert {:error, :criterion_text_required} = confirm(task, "reviewer", text: nil)
      assert {:error, :criteria_mismatch} = confirm(task, "reviewer", text: @c0)

      assert {:error, :criteria_index_out_of_range} =
               confirm(task, "reviewer", criterion: 2, text: "a criterion nobody wrote")

      assert reload(task).rev == rev
    end

    test "a blank note is refused before any write", %{task: task} do
      assert {:error, :note_required} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: @new_c0,
                 observed_rev: "x",
                 outcome: {:confirm, "  "}
               )
    end

    test "a confirm moves no lock and bumps no epoch", %{task: task, epoch: epoch} do
      amend!(task, epoch)
      assert {:ok, _} = confirm(task, "reviewer")

      assert entry(task, 0)["met"] == false
      assert reload(task).content["claim"]["epoch"] == epoch
    end

    test "the event names the confirmation on a boolean", %{task: task, epoch: epoch} do
      amend!(task, epoch)
      {:ok, _} = confirm(task, "reviewer")

      stamp =
        from(e in MutationEvent,
          where: e.doc_id == ^task.doc_id and e.mutation == "task.criterion",
          order_by: [asc: e.inserted_at]
        )
        |> Repo.all()
        |> List.last()
        |> Map.get(:document)
        |> Map.get("criterion_stamp")

      assert stamp["result"] == "confirmed"
      assert stamp["amendment_confirmed"] == true
      assert stamp["worker"] == "reviewer"
    end
  end

  describe "the close side" do
    test "met first, amended after: a done close by the amender is refused until confirmed",
         %{task: task, epoch: epoch} do
      {:ok, _} = met(task, epoch, @c0)
      amend!(task, epoch)
      rev = reload(task).rev

      assert {:error, {:amendment_unconfirmed, [0]}} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "done",
                 observed_rev: rev
               )

      assert reload(task).rev == rev

      assert {:ok, _} = confirm(task, "reviewer")

      assert {:ok, closed} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "done",
                 observed_rev: reload(task).rev
               )

      assert closed.content["lifecycle_status"] == "done"
    end

    test "the merge-gate autostamp cannot seal a gate its closer amended", %{scope: scope} do
      gate = "MERGE GATE (lead): PR #24999 is merged to main"
      doc_id = "amend-confirm-gate-#{System.unique_integer([:positive])}"

      {:ok, task} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => doc_id,
            "content" => %{
              "kind" => "task",
              "lifecycle_status" => "open",
              "description" => "a row whose merge gate gets reworded by the lead",
              "acceptance_criteria" => [
                %{"criterion" => gate, "met" => false, "evidence" => "", "merge_gate" => true}
              ],
              "merge_gate_autostamp" => %{"merge_event" => %{"prs" => ["24999"]}}
            }
          },
          @dataset,
          scope
        )

      {:ok, claimed} = Tasks.claim_by_id(doc_id, "lead", scope)
      epoch = claimed.content["claim"]["epoch"]
      amend!(task, epoch, "lead", gate, gate <> " as 9b76b4bfc9")

      close = fn ->
        Close.close(task.id, "lead",
          observed_epoch: epoch,
          lifecycle_status: "done",
          landed: %{"prs" => [24_999], "commits" => ["9b76b4bfc9"]},
          observed_rev: reload(task).rev
        )
      end

      assert {:error, {:amendment_unconfirmed, [0]}} = close.()
      assert {:ok, _} = confirm(task, "reviewer", text: gate <> " as 9b76b4bfc9")
      assert {:ok, closed} = close.()
      assert Enum.at(closed.content["acceptance_criteria"], 0)["met"] == true
    end

    test "a done close that LOWERS the self-amended criterion on the record is not refused",
         %{task: task, epoch: epoch} do
      {:ok, _} = met(task, epoch, @c0)
      amend!(task, epoch)

      assert {:ok, closed} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "done",
                 criteria: [%{"index" => 0, "met" => false}],
                 criteria_override: "the new wording is not proven yet",
                 observed_rev: reload(task).rev
               )

      assert Enum.at(closed.content["acceptance_criteria"], 0)["met"] == false
    end

    test "a blocked close is not a seal and is not refused", %{task: task, epoch: epoch} do
      {:ok, _} = met(task, epoch, @c0)
      amend!(task, epoch)

      assert {:ok, _} =
               Close.close(task.id, "builder",
                 observed_epoch: epoch,
                 lifecycle_status: "blocked",
                 reason: "waiting on review",
                 observed_rev: reload(task).rev
               )
    end

    test "the close gate reads the criteria as the close leaves them" do
      content = %{
        "acceptance_criteria" => [
          %{"criterion" => @new_c0, "met" => true, "amendments" => [%{"worker" => "builder"}]}
        ]
      }

      assert {:ok, merged} =
               Internal.merge_criteria(content, [%{"index" => 0, "met" => false}])

      assert AmendmentConfirmation.self_amended_met(merged["acceptance_criteria"], "builder") ==
               []

      assert AmendmentConfirmation.self_amended_met(content["acceptance_criteria"], "builder") ==
               [0]

      assert AmendmentConfirmation.self_amended_met(content["acceptance_criteria"], "other") == []
    end
  end

  test "confirmations is a declared criterion key, so a publish of a confirmed row is not refused" do
    assert Validation.criteria_violation([
             %{"criterion" => @c0, "met" => false, "confirmations" => []}
           ]) ==
             nil
  end

  describe "the wire" do
    test "--confirm-amendment parses in both spellings and needs a note" do
      for key <- ["confirm_amendment", "confirm-amendment"] do
        assert {:ok, 0, {:confirm, "checked"}, @new_c0} =
                 Params.parse_stamp(%{
                   "criterion" => "0",
                   key => "true",
                   "note" => "checked",
                   "criterion-text" => @new_c0
                 })
      end

      assert {:error, :invalid_stamp, msg} =
               Params.parse_stamp(%{"criterion" => "0", "confirm-amendment" => "true"})

      assert msg =~ "--confirm-amendment requires non-empty --note"

      assert {:error, :invalid_stamp, two} =
               Params.parse_stamp(%{
                 "criterion" => "0",
                 "confirm-amendment" => "true",
                 "met" => "true",
                 "evidence" => "e",
                 "note" => "n"
               })

      assert two =~ "exactly one of"
    end

    test "the refusal names the confirm command on both surfaces" do
      assert Params.reason_to_string({:amendment_unconfirmed, [0, 2]}) ==
               "amendment_unconfirmed:0,2"

      for surface <- [:stamp, :close] do
        hint = Params.criteria_hint({:amendment_unconfirmed, [2]}, surface)
        assert hint =~ "--confirm-amendment"
        assert hint =~ "--criterion 2"
        assert hint =~ "--observed-rev"
        assert hint =~ "acceptance_criteria[2]"
      end
    end
  end
end
