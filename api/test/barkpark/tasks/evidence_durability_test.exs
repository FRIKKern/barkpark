defmodule Barkpark.Tasks.EvidenceDurabilityTest do
  @moduledoc """
  task-f6fba9a87369ce8e — a stamp whose evidence names only a BRANCH describes a
  tree that may no longer exist, so the criterion reads MET forever and no
  auditor can confirm or refute it.

  The four arms here mirror the row's four criteria, and the fourth is the one
  that matters: a test that only proves the new refusal is indistinguishable
  from a guard that refuses EVERYTHING. Three of these four arms exist to prove
  the guard still lets honest evidence through.

  The strings marked REAL are taken verbatim from evidence already on the live
  ledger, so the acceptance arms are not the author's idea of what honest
  evidence looks like.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks}
  alias Barkpark.Tasks.{EvidenceDurability, Stamp}

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

  defp claimed_task!(scope) do
    doc_id = uniq("evid")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [
              %{"criterion" => "the thing is proven", "met" => false, "evidence" => ""}
            ]
          }
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(doc_id, "w-evid", scope)
    {doc, claimed.content["claim"]["epoch"]}
  end

  defp stamp(scope, evidence) do
    {task, epoch} = claimed_task!(scope)

    Stamp.stamp(task.id, "w-evid",
      observed_epoch: epoch,
      criterion: 0,
      criterion_text: "the thing is proven",
      outcome: {:met, evidence}
    )
  end

  # REAL — verbatim from eci-w1-index-note, the ONE genuinely false-done row the
  # 34-row hand-check found. Its branch is gone and `git log --all -S` names zero
  # commits across every ref, so this sentence can never be checked again.
  @the_casualty """
  wc -c docs/INDEX.md = 1187 (<=1200); scripts/check-doc-budgets.sh printed \
  'docs/INDEX.md 1187B <= 1200B' and 'check-doc-budgets: PASS', exit 0 — reviewer \
  re-ran on -r branch.
  """

  describe "criterion 1 — branch-only evidence is REFUSED" do
    test "the refusal fires on the real false-done row's own evidence", %{scope: scope} do
      assert {:error, :branch_only_evidence} = stamp(scope, @the_casualty)
    end

    test "nothing is written when the stamp is refused", %{scope: scope} do
      {task, epoch} = claimed_task!(scope)

      assert {:error, :branch_only_evidence} =
               Stamp.stamp(task.id, "w-evid",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: "the thing is proven",
                 outcome: {:met, @the_casualty}
               )

      # A refusal that half-writes is worse than no guard: the row would read
      # met with the evidence the guard just rejected.
      stored = Barkpark.Repo.get!(Barkpark.Content.Document, task.id)
      [criterion] = stored.content["acceptance_criteria"]
      refute criterion["met"]
      assert criterion["evidence"] == ""
    end

    test "the refusal names the missing thing AND how to supply it" do
      message = EvidenceDurability.message()

      # A guard that refuses without saying what to type is a guard agents route
      # around, so the message is part of the contract, not decoration.
      assert message =~ "BRANCH"
      assert message =~ "commit sha"
      assert message =~ "does NOT have to be on main"
      assert message =~ "path:line"
      assert message =~ "#16238"
    end
  end

  describe "criterion 2 — a live commit sha is ACCEPTED, on main or not" do
    test "a sha that is NOT on main is accepted — the legitimate mid-build case",
         %{scope: scope} do
      # This is the arm an over-tight fix breaks: builders stamp against branch
      # commits before merge, and that is fine, because the sha stays resolvable
      # and whether it landed is a separate question.
      evidence =
        "Committed d9423d32 'docs(index): note what an epic cycle produces' on branch " <>
          "loop-epic/add-the-index-note-9, not yet merged to main."

      assert {:ok, _} = stamp(scope, evidence)
    end

    test "a branch AND a sha together is accepted — REAL, from the survivor row",
         %{scope: scope} do
      # Verbatim from pds-bl-w48-web-sibling-launders, the row the filing names
      # as the contrast case: same disease, opposite outcome, and the only
      # difference was what the evidence pointed at.
      evidence =
        "Run in the worktree on branch loop-epic/two-sibling-web-routes-launder-alongside-5 " <>
          "at commit 7e08e1ce60."

      assert {:ok, _} = stamp(scope, evidence)
    end

    test "a path:line is accepted with no sha at all", %{scope: scope} do
      evidence =
        "The allowlist is defined at api/lib/barkpark_web/controllers/tasks_controller/" <>
          "params.ex:1016 and every declared flag is covered."

      assert {:ok, _} = stamp(scope, evidence)
    end
  end

  describe "criterion 3 — legitimately non-git evidence is ACCEPTED" do
    test "a Paper id, a bp doc id and a host read all pass", %{scope: scope} do
      for evidence <- [
            "Recorded on the Paper /papers/mechanical-spacing-doctrine, section 2.",
            "bp task show task-233cb8a1d033c738 reads lifecycle_status done, 4/4 met.",
            "curl against the host returned 200 with a body naming the tenant.",
            "The operator confirmed by hand that the allowlist env var is unset."
          ] do
        # Bind first, then assert on a boolean: `assert pattern = expr, "msg"`
        # raises MatchError before assert/2 ever reaches the message, so the
        # message would never print on the failure it exists to explain.
        result = stamp(scope, evidence)

        assert match?({:ok, _}, result),
               "non-git evidence was refused: #{evidence} -> #{inspect(result)}"
      end
    end

    test "the overloaded word `branch` about CODE is not a git claim" do
      # Measured on the live ledger: a rule keyed on the word alone refuses 254
      # of 6,200 real evidence strings (4.1%), most of them talking about code
      # paths. These four are the shapes that would have been wrongly caught.
      for evidence <- [
            "push_worker.ex report_halt/4 is called on the halted? branch and logs a warning.",
            "paintRefusal() branches on whether anything is running.",
            "the criterion's 'or truncates with a cue' branch is not the one taken.",
            "Two of the six rows are verdicts about a FAILURE BRANCH, not a success receipt."
          ] do
        assert EvidenceDurability.check(evidence) == :ok,
               "a code-path use of the word `branch` was treated as a git claim: #{evidence}"
      end
    end
  end

  describe "criterion 4 — the guard is not a blanket refusal" do
    # THE NON-VACUITY ARM. A test that only proves the refusal cannot tell a
    # correct guard from one that refuses everything, so this walks a corpus of
    # honest evidence and asserts the guard stays SILENT on all of it.
    test "every one of these honest strings is accepted" do
      honest = [
        # REAL, from rows that survived the hand-check
        "git show --stat 7e08e1ce6 touches exactly four paths.",
        "gh run view 32625191825 --json conclusion,jobs: run conclusion success.",
        "PR #13617. paintRefusal() branches on whether anything is running.",
        "mix test test/barkpark/tasks/ -> 752 tests, 0 failures.",
        "scripts/check-doc-budgets.sh printed PASS, exit 0.",
        "Recorded on the Paper /papers/personal-dev-fleet-mvp.",
        "The class re-derives to 0 rows over 8,567 paged task documents."
      ]

      refused =
        Enum.filter(honest, fn e -> EvidenceDurability.check(e) != :ok end)

      assert refused == [],
             """
             the guard refused evidence it must accept. A guard that refuses
             everything passes the refusal arm and is still broken.

             refused:
             #{Enum.map_join(refused, "\n", &"  - #{&1}")}
             """
    end

    test "the two halves of the decision are independently addressable" do
      # If the guard ever goes wrong, the failure should be attributable to one
      # of two questions rather than to one opaque boolean.
      assert EvidenceDurability.names_a_branch_location?(@the_casualty)
      refute EvidenceDurability.names_something_durable?(@the_casualty)

      with_sha = "verified on the ledger3/foo branch at commit 7e08e1ce60"
      assert EvidenceDurability.names_a_branch_location?(with_sha)
      assert EvidenceDurability.names_something_durable?(with_sha)
      assert EvidenceDurability.check(with_sha) == :ok
    end

    test "the three trigger patterns, and the English that must NOT trigger them" do
      # Each refusal below is a pattern this guard earned; each acceptance is a
      # string that broke an earlier draft of it. Keeping both columns in one
      # test is the point — a guard is only correct if BOTH hold.
      refuse = [
        "reviewer re-ran on -r branch",
        "git diff --stat on this branch returns EMPTY",
        "verified by hand on the loop-epic/foo-9 branch",
        "measured on main branch and the numbers matched"
      ]

      accept = [
        # "right" is an adjective about correctness, not a ref. This exact
        # phrasing lives in this repo's own stamp_test.exs, so the loose draft
        # reddened an existing test rather than any live stamp.
        "re-run on the right branch: 42 green",
        "first: wrong branch",
        "push_worker.ex report_halt/4 fires on the halted? branch",
        # a branch AND a durable pointer is always fine
        "git diff --stat on this branch returns EMPTY, at commit 7e08e1ce60"
      ]

      for e <- refuse do
        assert EvidenceDurability.check(e) == {:error, :branch_only_evidence},
               "should have been refused as branch-only: #{e}"
      end

      for e <- accept do
        assert EvidenceDurability.check(e) == :ok,
               "should have been accepted: #{e}"
      end
    end

    test "a byte count is not a sha" do
      # `1187` and `1200` are digits in hex range; a rule that accepted any
      # hex-looking run would have let the casualty through on its own byte
      # count, which is exactly the number it quotes.
      refute EvidenceDurability.names_something_durable?(
               "wc -c docs/INDEX.md = 1187 (<=1200), verified on the -r branch"
             )
    end
  end
end
