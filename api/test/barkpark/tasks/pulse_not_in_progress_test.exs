defmodule Barkpark.Tasks.PulseNotInProgressTest do
  @moduledoc """
  task-b6fcc8e2f57e1cd5 — A GREEN PULSE LOG IS NOT EVIDENCE OF A CLAIM.

  `bp task stage <id> open` is the one sanctioned path out of `in_progress`
  that NEVER writes `content.claim` (Stage.do_stage/8 writes lifecycle_status,
  the engagement lease and the adjudication triple, nothing else). So a staged
  row reads `lifecycle_status: "open"` while `claim.worker` still names the
  departed holder — the exact shape measured on task-ee33b6f088b35bdb and
  task-8f9d3ea8926f387f on 2026-09-06, and the shape reproduced on the probe
  row task-bc494701cb7d7285. The TtlSweeper reap and `release` are the OTHER
  lapse shape: both clear `claim.worker` to nil.

  A pulse on such a row was already refused — but as the bare `:not_holder`
  token, which is ALSO what a thief's pulse gets. One token for two different
  situations tells the keep-alive loop nothing about which of them happened,
  and the remedies differ: a thief must back off, the departed holder must
  RE-CLAIM. This file pins the three arms:

    * NOT in_progress (staged back to open, claim.worker intact) →
      `{:error, {:not_in_progress, "open"}}` — the refusal NAMES the state,
      and the 409's `message` names `bp task claim` as the fix.
    * the holder on a live `in_progress` claim → still `{:ok, _}`.
    * a non-holder on a live `in_progress` claim → still `{:error, :not_holder}`.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias BarkparkWeb.TasksController.Params

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

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp claimed_task!(scope, worker) do
    doc_id = uniq("pulse-nip")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
          }
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(doc.doc_id, worker, scope)
    claimed
  end

  defp reload(doc), do: Repo.get!(Document, doc.id)

  describe "a pulse on a row that is NOT in_progress" do
    test "STAGED back to open with claim.worker intact → {:not_in_progress, \"open\"}, nothing written",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")

      {:ok, staged} = Tasks.stage(doc.id, "open", note: "parked mid-flight")

      # The premise this whole file rests on: the stage left the STALE CLAIM.
      assert staged.content["lifecycle_status"] == "open"

      assert staged.content["claim"]["worker"] == "w-hold",
             "stage must leave claim.worker set — that is the shape under test"

      epoch_before = staged.content["claim"]["epoch"]

      result = Tasks.pulse_by_id(doc.id, "w-hold", text: "still here?")

      assert result == {:error, {:not_in_progress, "open"}},
             "a pulse on an open row must name the state, not answer the ambiguous :not_holder"

      after_content = reload(doc).content
      assert after_content["lifecycle_status"] == "open"
      assert after_content["claim"]["epoch"] == epoch_before
      refute Map.has_key?(after_content["claim"], "now")
    end

    test "the 409 message names the actual state AND `bp task claim`" do
      hint = Params.criteria_hint({:not_in_progress, "open"}, :pulse)

      assert is_binary(hint),
             "the pulse surface must carry a remedy hint for {:not_in_progress, _}"

      assert String.contains?(hint, "open"), "the hint must name the row's ACTUAL state"

      assert String.contains?(hint, "bp task claim"),
             "the hint must name the fix — a re-claim, never a silent retry"
    end
  end

  describe "the two arms that must NOT move" do
    test "the holder's pulse on a live in_progress claim still succeeds", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch_before = doc.content["claim"]["epoch"]

      {:ok, pulsed} = Tasks.pulse_by_id(doc.id, "w-hold", text: "working")

      assert pulsed.content["claim"]["now"]["text"] == "working"
      assert pulsed.content["claim"]["epoch"] == epoch_before + 1
    end

    test "a non-holder on a live in_progress claim is still :not_holder", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")

      result = Tasks.pulse_by_id(doc.id, "w-thief", text: "mine now")

      assert result == {:error, :not_holder},
             "a thief's refusal must stay :not_holder — it is a HOLDER fault, not a state fault"

      refute Map.has_key?(reload(doc).content["claim"], "now")
    end
  end
end
