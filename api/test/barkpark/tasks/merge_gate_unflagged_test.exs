defmodule Barkpark.Tasks.MergeGateUnflaggedTest do
  @moduledoc """
  task-d1654bf0d20d5009 — three verbs, three predicates, and close is the
  narrowest of them.

  `stamp.ex` calls `Criteria.merge_gated?/1`, which is flag-OR-PROSE, to REFUSE
  a builder's `--met`. `landed.ex` uses an even wider predicate to PERMIT, and
  inverts one arm for that reason. `close.ex` calls the shared predicate zero
  times: its autostamp keys on the flag alone.

  The row asked for close to be routed through the shared predicate, for
  symmetry with stamp. **That remedy is the harm.** A wide predicate is safe
  gating a refusal and dangerous gating a permit, and `reconcile_locked/4` is a
  permit: it composes evidence and writes synthetic met-flips when a PR merges.

  Measured on the live ledger over 14,699 criteria: 501 are worded as merge
  gates while carrying no flag. 427 open with the marker and are genuine
  declarations; 74 bury it in prose and are criteria ABOUT gating. Widening the
  permit auto-marks those 74 met on the next merge.

  So the flag stays the permit, and the strand becomes a SENTENCE instead of
  silence: the reconcile receipt names the unflagged criteria and stamps
  nothing.

  The last test in this file is the one that matters. It builds a criterion
  taken verbatim from the live ledger which merely TALKS about merge gating, and
  asserts the autostamp does not flip it — the fabricated done the filed remedy
  would have shipped.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks}
  alias Barkpark.Content.Document

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

  defp mk_task!(scope, criteria) do
    doc_id = uniq("mg")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => criteria
          }
        },
        @dataset,
        scope
      )

    doc
  end

  defp reconcile(doc) do
    Tasks.reconcile_merge_gate(doc.id, %{"pr" => 16_250, "commit" => "abc1234"})
  end

  defp stored_criteria(%Document{id: id}) do
    Repo.get!(Document, id).content["acceptance_criteria"]
  end

  # Verbatim shapes from the live ledger.
  @declaration "MERGE-GATED (the lead closes this): the PR is merged to main with the required gates green on its head."
  @about_gating "The four lead-gated rows are adjudicated `open` — NOT closed — each with a reason naming the specific outstanding [MERGE-GATED] lead act."

  describe "the flag is the permit" do
    test "a FLAGGED gate is still autostamped on merge", %{scope: scope} do
      # Non-vacuity for the whole file: if the autostamp stopped working, every
      # refutation below would pass for free.
      doc =
        mk_task!(scope, [
          %{
            "criterion" => @declaration,
            "met" => false,
            "evidence" => "",
            "merge_gate" => true
          }
        ])

      assert {:ok, :stamped, [0]} = reconcile(doc)
      [c] = stored_criteria(doc)
      assert c["met"] == true
    end
  end

  describe "an UNFLAGGED but worded criterion is NAMED, not stamped" do
    test "the receipt names the indices and nothing is written", %{scope: scope} do
      doc =
        mk_task!(scope, [
          %{"criterion" => "something unrelated", "met" => false, "evidence" => ""},
          %{"criterion" => @declaration, "met" => false, "evidence" => ""}
        ])

      # A count says there is a problem; a list says where.
      assert {:ok, :unflagged_merge_gates, [1]} = reconcile(doc)

      criteria = stored_criteria(doc)
      refute Enum.at(criteria, 1)["met"]
      assert Enum.at(criteria, 1)["evidence"] == ""
      refute Enum.at(criteria, 0)["met"]
    end

    test "a row with neither a flag nor gate wording still reads :no_marker",
         %{scope: scope} do
      # The new tag must not swallow the old one — `:no_marker` still has to mean
      # "this row has nothing that looks like a gate at all".
      doc =
        mk_task!(scope, [
          %{"criterion" => "the suite is green", "met" => false, "evidence" => ""}
        ])

      assert {:ok, :no_marker} = reconcile(doc)
    end

    test "an explicit merge_gate false VETOES the wording", %{scope: scope} do
      # `Criteria.merge_gated?/1` honours a declared false. A criterion whose
      # author said it is NOT a gate must not be reported as a stranded one, or
      # the receipt becomes noise the next reader learns to skip.
      doc =
        mk_task!(scope, [
          %{
            "criterion" => @declaration,
            "met" => false,
            "evidence" => "",
            "merge_gate" => false
          }
        ])

      assert {:ok, :no_marker} = reconcile(doc)
    end

    test "an already-met worded criterion is not reported as stranded",
         %{scope: scope} do
      doc =
        mk_task!(scope, [
          %{"criterion" => @declaration, "met" => true, "evidence" => "done by hand"}
        ])

      assert {:ok, :no_marker} = reconcile(doc)
    end
  end

  describe "the harm the filed remedy would have shipped" do
    test "a criterion that merely TALKS about merge gating is NOT flipped on merge",
         %{scope: scope} do
      # Verbatim from the live ledger. Under the remedy the row asked for —
      # routing this filter through the prose predicate — merging a PR would
      # mark this criterion met. It says the rows are adjudicated OPEN, NOT
      # closed. Marking it met asserts the opposite of what it says.
      #
      # 74 criteria on the ledger are this shape.
      doc =
        mk_task!(scope, [
          %{"criterion" => @about_gating, "met" => false, "evidence" => ""}
        ])

      assert {:ok, :unflagged_merge_gates, [0]} = reconcile(doc)

      [c] = stored_criteria(doc)

      refute c["met"],
             """
             a criterion that only DISCUSSES merge gating was marked met by the
             merge autostamp. This is the fabricated done that widening the
             permit produces, and it is why close.ex keys on the flag.

             criterion: #{c["criterion"]}
             """

      assert c["evidence"] == ""
    end
  end
end
