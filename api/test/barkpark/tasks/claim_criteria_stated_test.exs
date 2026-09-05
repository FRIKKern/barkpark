defmodule Barkpark.Tasks.ClaimCriteriaStatedTest do
  @moduledoc """
  task-9554c64bf51a0f81 — a row with zero acceptance criteria is one whose done
  state can be attested ONLY by artifact and never by criterion. The artifact
  says something landed; it cannot say what the row was FOR.

  The close door already refuses that shape, and by then it is too late by
  construction: the work is finished, so the criteria that would have defined
  success get written after the fact by whoever is trying to get the row shut.
  At claim time they still SHAPE the work.

  ## Why a refusal rather than a warning

  Not taste, and not a new posture. `close.ex` already made this exact call for
  the sibling gate on this exact evidence: `Plugins.Tasks.warn_if_create_zero/1`
  is a soft `Logger.warning` on a zero-criteria task, it fired on 9 of 11 births
  and changed nothing, because its only reader is the server journal. A second
  warning would be the same instrument aimed at the same blind spot.

  ## What this file has to prove, not just assert

  Most of it describes things that must STILL WORK. A refusal is easy; a
  refusal that fires only where it should is the whole job, and the exempt
  shapes are where a careless version does its damage — thirty agents drive
  this verb daily.

  ## The last describe block corrected the population figure

  The lead asked for one claim to be PROVEN rather than reasoned: that the 41
  criteria-less orphan DRAFT rows on the live ledger are structurally
  unreachable by this gate, because "unreachable" is exactly the kind of claim
  that turns out to have one path nobody enumerated.

  It did. `Tasks.claim_by_id/3` resolves a `drafts.<id>` and this gate refuses
  it. The test was written to assert unreachability, FAILED, and the analysis
  was wrong rather than the code: the governing population is 134, not the 93 I
  first reported, and the exclusion of the drafts was unfounded.

  Not exempting drafts is also the right behaviour and not merely the observed
  one. A claim is where work starts, and the argument that criteria should
  shape the work rather than describe it does not weaken because the row has
  not been published. A draft somebody is claiming is a draft somebody is
  working.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks}

  @dataset "production"

  setup do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
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

  defp mk!(scope, extra, doc_id \\ nil) do
    doc_id = doc_id || uniq("cc")

    content =
      Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  @criterion [%{"criterion" => "the thing is measurably done", "met" => false, "evidence" => ""}]

  describe "the refusal" do
    test "a criteria-less work row cannot be claimed", %{scope: scope} do
      doc = mk!(scope, %{})

      assert {:error, :criteria_unstated} =
               Tasks.claim_by_id(doc.content["doc_id"] || doc.doc_id, "w-cc", scope)
    end

    test "nothing is written when the claim is refused", %{scope: scope} do
      doc = mk!(scope, %{})
      doc_id = doc.doc_id

      assert {:error, :criteria_unstated} = Tasks.claim_by_id(doc_id, "w-cc", scope)

      stored = Barkpark.Repo.get!(Barkpark.Content.Document, doc.id)
      assert stored.content["lifecycle_status"] == "open"
      refute Map.has_key?(stored.content, "claim")
    end

    test "the refusal message names the row, the fix and the override verbatim" do
      msg = BarkparkWeb.TasksController.Params.criteria_unstated_message("task-abc", "w-cc")

      # A refusal that does not carry its own remedy costs ~30 agents a round
      # trip each. The message is part of the contract, not decoration.
      assert msg =~ "task-abc"
      assert msg =~ "NO acceptance criteria"
      assert msg =~ "bp doc patch task task-abc"
      assert msg =~ "acceptance_criteria:="
      assert msg =~ "bp task claim task-abc w-cc"
      assert msg =~ ~s|criteria_unstated_override=|
      # It must also point at the honest alternative to overriding.
      assert msg =~ "Containers are exempt"
    end

    test "the override lands, and it must be non-empty", %{scope: scope} do
      doc = mk!(scope, %{})
      doc_id = doc.doc_id

      # Blank is not a reason.
      assert {:error, :criteria_unstated} =
               Tasks.claim_by_id(doc_id, "w-cc", scope ++ [criteria_unstated_override: "   "])

      assert {:ok, claimed} =
               Tasks.claim_by_id(
                 doc_id,
                 "w-cc",
                 scope ++ [criteria_unstated_override: "spike, deliberately unscoped"]
               )

      assert claimed.content["claim"]["worker"] == "w-cc"
    end
  end

  describe "what must STILL work — the exempt shapes" do
    test "a row WITH criteria claims normally", %{scope: scope} do
      doc = mk!(scope, %{"acceptance_criteria" => @criterion})

      assert {:ok, claimed} = Tasks.claim_by_id(doc.doc_id, "w-cc", scope)
      assert claimed.content["claim"]["worker"] == "w-cc"
    end

    test "a decision-labelled row claims with no criteria", %{scope: scope} do
      doc = mk!(scope, %{"labels" => ["decision"]})
      assert {:ok, _} = Tasks.claim_by_id(doc.doc_id, "w-cc", scope)
    end

    test "a phase:goal label segment exempts — matching is SEGMENT-wise",
         %{scope: scope} do
      doc = mk!(scope, %{"labels" => ["phase:goal"]})
      assert {:ok, _} = Tasks.claim_by_id(doc.doc_id, "w-cc", scope)

      # ...and a label that merely CONTAINS the word does not exempt, which is
      # the whole reason the shared predicate splits on ":" rather than
      # substring-matching. A substring rule would hand this row a silent permit.
      other = mk!(scope, %{"labels" => ["proj:goalkeeper-rewrite"]})
      assert {:error, :criteria_unstated} = Tasks.claim_by_id(other.doc_id, "w-cc", scope)
    end

    test "a row somebody names as their parent is a container and exempts",
         %{scope: scope} do
      parent = mk!(scope, %{}, uniq("cc-parent"))
      _child = mk!(scope, %{"parent_id" => parent.doc_id, "acceptance_criteria" => @criterion})

      assert {:ok, _} = Tasks.claim_by_id(parent.doc_id, "w-cc", scope)
    end

    test "a lease RENEWAL is never refused, even on a criteria-less row",
         %{scope: scope} do
      # A worker re-claiming a row it already holds is recovering a lease after
      # a fence bump. Refusing that would strand LIVE work behind a paperwork
      # gate — the door belongs where work starts, not where it resumes.
      doc = mk!(scope, %{})
      doc_id = doc.doc_id

      {:ok, _} =
        Tasks.claim_by_id(doc_id, "w-cc", scope ++ [criteria_unstated_override: "spike"])

      assert {:ok, renewed} = Tasks.claim_by_id(doc_id, "w-cc", scope)
      assert renewed.content["claim"]["worker"] == "w-cc"
    end
  end

  describe "the 41 criteria-less DRAFTS — REACHED, not unreachable" do
    test "a drafts.<id> row IS refused, so the 41 are in the population after all",
         %{scope: scope} do
      # THIS TEST WAS WRITTEN TO ASSERT THE OPPOSITE AND FAILED, which is the
      # only reason the population figure is right.
      #
      # The population analysis excluded 41 criteria-less DRAFT rows on the
      # grounds that a draft is unreachable as work. The lead asked for that
      # PROVEN rather than reasoned, because "unreachable" is exactly the kind
      # of claim that turns out to have one path nobody enumerated. It did:
      # `Tasks.claim_by_id/3` resolves a `drafts.<id>` and this gate refuses it.
      #
      # So the exclusion was wrong and the governing population is 134, not 93.
      #
      # And NOT exempting drafts is the correct behaviour, not merely the
      # observed one. A claim is where work starts; the argument that criteria
      # should shape the work rather than describe it does not weaken because
      # the row has not been published yet. A draft somebody is claiming is a
      # draft somebody is working.
      draft = mk!(scope, %{}, "drafts." <> uniq("cc-orphan"))

      assert {:error, :criteria_unstated} = Tasks.claim_by_id(draft.doc_id, "w-cc", scope)
    end

    test "an exempt DRAFT still claims, so the gate is not simply refusing all drafts",
         %{scope: scope} do
      # Non-vacuity for the arm above: if drafts were refused for some unrelated
      # reason, the previous test would pass while proving nothing about this
      # gate.
      draft = mk!(scope, %{"acceptance_criteria" => @criterion}, "drafts." <> uniq("cc-ok"))

      assert {:ok, claimed} = Tasks.claim_by_id(draft.doc_id, "w-cc", scope)
      assert claimed.content["claim"]["worker"] == "w-cc"
    end
  end
end
