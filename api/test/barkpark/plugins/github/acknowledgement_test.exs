defmodule Barkpark.Plugins.Github.AcknowledgementTest do
  @moduledoc """
  THE REPORTER LOOP — the detector, the predicate, and the criterion template.

  The close-side guard lives in `Barkpark.Tasks.CloseAcknowledgementTest`; this
  file pins the three things that guard reads:

    * the PREDICATE is the birth invariant, so it catches every intake row AND
      excludes the pre-bridge `gh-1`..`gh-6` rows whose issue number does not
      equal their id number (the enumerated-id-prefix version would sweep all six
      in — that is the soundness half, tested here as a negative);
    * the CRITERION is recognised by its FLAG and never by its wording;
    * the CENSUS counts one waiting reporter ONCE across the draft/published twin
      pair, and buckets terminal rows separately because those never move again.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.{Acknowledgement, Projection}
  alias Barkpark.Repo

  @dataset "production"

  # A raw `documents` row, inserted straight through `Repo` — the census reads
  # the table, so it must be pinned against the table rather than against a
  # write-path fixture that could quietly diverge from it.
  defp insert_task!(doc_id, content, opts \\ []) do
    %Document{}
    |> Ecto.Changeset.change(%{
      doc_id: doc_id,
      type: Keyword.get(opts, :type, "task"),
      dataset: Keyword.get(opts, :dataset, @dataset),
      title: Keyword.get(opts, :title, doc_id),
      status: if(String.starts_with?(doc_id, "drafts."), do: "draft", else: "published"),
      content: content,
      rev: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp intake_content(number, opts \\ []) do
    %{
      "kind" => "task",
      "lifecycle_status" => Keyword.get(opts, :lifecycle_status, "open"),
      "labels" => ["src:github", "needs-human"],
      "github" => %{"repo" => "FRIKKern/barkpark", "issue" => number, "state" => "intake"}
    }
    |> then(fn c ->
      case Keyword.get(opts, :criteria) do
        nil -> c
        list -> Map.put(c, "acceptance_criteria", list)
      end
    end)
  end

  describe "criterion/2 — the template" do
    test "is born unmet, carries the machine flag, and names a checkable place" do
      criterion = Acknowledgement.criterion("FRIKKern/barkpark", 9531)

      assert criterion["met"] == false
      assert criterion["evidence"] == ""
      assert criterion["ack_gate"] == true
      assert criterion["criterion"] =~ "FRIKKern/barkpark#9531"
      assert criterion["criterion"] =~ "comment URL"
    end

    test "names the issue alone when the plugin is dark and has no repo" do
      criterion = Acknowledgement.criterion(nil, 9531)

      assert criterion["criterion"] =~ "issue #9531"
      refute criterion["criterion"] =~ "nil"
      assert criterion["ack_gate"] == true
    end
  end

  describe "criterion/2 reaches the REPORTER, not only the closer" do
    test "the outbound mirror projects it into the issue body as an unchecked box" do
      # This is the consequence a wording edit has to be made in full knowledge
      # of: once a maintainer runs `bp github adopt`, the mirror renders the
      # row's acceptance_criteria into the ISSUE BODY as a GitHub task list. So
      # this sentence lands on the stranger's own issue. Pinned as a TEST rather
      # than as a comment, because a comment cannot stop the next author writing
      # an internal aside into text the reporter reads.
      criterion = Acknowledgement.criterion("FRIKKern/barkpark", 9531)
      body = Projection.upsert_acceptance_marker("the original report", [criterion])

      assert body =~ "### Acceptance criteria"
      assert body =~ "- [ ] ACKNOWLEDGED UPSTREAM"
      assert body =~ "FRIKKern/barkpark#9531"
      # The reporter's own text is preserved outside the fence.
      assert body =~ "the original report"
    end

    test "every clause stays true read from the REPORTER's side" do
      text = Acknowledgement.criterion("FRIKKern/barkpark", 9531)["criterion"]

      # An earlier draft explained to the CLOSER that "the reporter is OUTSIDE
      # this ledger" — true, addressed to the wrong person, and rendered onto the
      # issue of the very reporter it talks about. The explanation for the closer
      # belongs in `criteria_hint/2`, which only the closer ever sees.
      refute text =~ "OUTSIDE this ledger"
      refute text =~ "reporter"
      # and it still says the three checkable things
      assert text =~ "FRIKKern/barkpark#9531"
      assert text =~ "PR or commit"
      assert text =~ "comment URL"
    end
  end

  describe "acknowledged?/1 — the flag is the only signal" do
    test "an unmet ack criterion is NOT acknowledged" do
      content = intake_content(9531, criteria: [Acknowledgement.criterion(nil, 9531)])

      assert Acknowledgement.has_criterion?(content)
      refute Acknowledgement.acknowledged?(content)
    end

    test "a met ack criterion IS acknowledged" do
      met = Map.merge(Acknowledgement.criterion(nil, 9531), %{"met" => true, "evidence" => "url"})
      assert Acknowledgement.acknowledged?(intake_content(9531, criteria: [met]))
    end

    test "ZERO criteria is not acknowledged — the empty list is the blind spot itself" do
      refute Acknowledgement.acknowledged?(intake_content(9531))
      refute Acknowledgement.has_criterion?(intake_content(9531))
      refute Acknowledgement.acknowledged?(intake_content(9531, criteria: []))
    end

    test "criterion WORDING alone never counts — only the flag does" do
      # The exact wording the template mints, with the flag stripped. If the gate
      # ever fell back to text matching, this would read as acknowledged and the
      # merge_gate two-vocabulary drift (2870 worded vs 35 flagged) would be
      # rebuilt here from scratch.
      worded = Map.delete(Acknowledgement.criterion(nil, 9531), "ack_gate")
      worded = %{worded | "met" => true}

      refute Acknowledgement.has_criterion?(intake_content(9531, criteria: [worded]))
      refute Acknowledgement.acknowledged?(intake_content(9531, criteria: [worded]))
    end

    test "another criterion being met does not acknowledge anything" do
      other = %{"criterion" => "the fix ships", "met" => true, "evidence" => "PR #1"}
      ack = Acknowledgement.criterion(nil, 9531)

      refute Acknowledgement.acknowledged?(intake_content(9531, criteria: [other, ack]))
    end
  end

  describe "intake_born?/2 — the predicate is the birth invariant" do
    test "matches an intake row in both its published and draft form" do
      assert Acknowledgement.intake_born?("gh-9531", intake_content(9531))
      assert Acknowledgement.intake_born?("drafts.gh-9531", intake_content(9531))
    end

    test "an issue number stored as a STRING still matches" do
      content = put_in(intake_content(9531), ["github", "issue"], "9531")
      assert Acknowledgement.intake_born?("gh-9531", content)
    end

    test "EXCLUDES the pre-bridge gh-1..gh-6 rows whose issue does not equal their id" do
      # Measured on the live ledger 2026-08-24: gh-1 carries issue 1580, and
      # gh-2..gh-6 carry 2526-2530. They were hand-authored 2026-07-11, before
      # inbound intake existed, and later mirrored OUTBOUND (state "synced").
      # An id-prefix predicate sweeps all six in; the pair check must not.
      for {doc_id, issue} <- [
            {"gh-1", 1580},
            {"gh-2", 2526},
            {"gh-3", 2527},
            {"gh-4", 2528},
            {"gh-5", 2529},
            {"gh-6", 2530}
          ] do
        content = %{
          "labels" => ["deploy-button", "github"],
          "github" => %{"repo" => "FRIKKern/barkpark", "issue" => issue, "state" => "synced"}
        }

        refute Acknowledgement.intake_born?(doc_id, content),
               "#{doc_id} (issue #{issue}) must not read as intake-born"
      end
    end

    test "an OUTBOUND-mirrored row keeps its task slug and can never match" do
      content = %{
        "github" => %{"repo" => "FRIKKern/barkpark", "issue" => 13754, "state" => "synced"}
      }

      refute Acknowledgement.intake_born?("task-88f56036f27570c3", content)
      refute Acknowledgement.intake_born?("drafts.task-88f56036f27570c3", content)
    end

    test "a plain task with no github bookkeeping is not intake-born" do
      refute Acknowledgement.intake_born?("gh-9531", %{"kind" => "task"})
      refute Acknowledgement.intake_born?("task-abc", %{"kind" => "task"})
      refute Acknowledgement.intake_born?(nil, %{"kind" => "task"})
    end
  end

  describe "census/2 — the detector" do
    test "counts an unacknowledged intake row, and drops it once acknowledged" do
      insert_task!("gh-9531", intake_content(9531))

      census = Acknowledgement.census(@dataset)
      assert census.total == 1
      assert census.open == 1
      assert census.closed == 0
      assert census.no_criterion == 1

      row = hd(census.rows)
      assert row.doc_id == "gh-9531"
      assert row.issue == 9531
      assert row.state == "intake"
      assert row.criteria_total == 0
      refute row.has_criterion

      met = Map.merge(Acknowledgement.criterion(nil, 9531), %{"met" => true, "evidence" => "url"})

      Repo.get_by!(Document, doc_id: "gh-9531", type: "task", dataset: @dataset)
      |> Ecto.Changeset.change(%{content: intake_content(9531, criteria: [met])})
      |> Repo.update!()

      assert Acknowledgement.census(@dataset).total == 0
    end

    test "a terminal row lands in the `closed` bucket — its reporter waits forever" do
      insert_task!("gh-11555", intake_content(11555, lifecycle_status: "done"))
      insert_task!("gh-9531", intake_content(9531))

      census = Acknowledgement.census(@dataset)
      assert census.total == 2
      assert census.closed == 1
      assert census.open == 1
    end

    test "one waiting reporter counts ONCE across the draft/published twin pair" do
      insert_task!("gh-9531", intake_content(9531))
      insert_task!("drafts.gh-9531", intake_content(9531))

      census = Acknowledgement.census(@dataset)
      assert census.total == 1
      assert hd(census.rows).doc_id == "gh-9531"
    end

    test "the draft twin's content wins, because it is the write target" do
      met = Map.merge(Acknowledgement.criterion(nil, 9531), %{"met" => true, "evidence" => "url"})
      insert_task!("gh-9531", intake_content(9531))
      insert_task!("drafts.gh-9531", intake_content(9531, criteria: [met]))

      # The published row is still unacknowledged; the fresher draft is not. If
      # the dedupe picked the published row this would count 1 and nag over an
      # answer already given.
      assert Acknowledgement.census(@dataset).total == 0
    end

    test "the census excludes rows the predicate excludes" do
      insert_task!("gh-1", %{
        "github" => %{"repo" => "FRIKKern/barkpark", "issue" => 1580, "state" => "synced"}
      })

      insert_task!("task-88f56036f27570c3", %{
        "github" => %{"repo" => "FRIKKern/barkpark", "issue" => 13754, "state" => "synced"}
      })

      insert_task!("gh-not-a-number", intake_content(9531))

      assert Acknowledgement.census(@dataset).total == 0
    end

    test "a dataset filter narrows; nil is the whole fleet" do
      insert_task!("gh-9531", intake_content(9531), dataset: "production")
      insert_task!("gh-8100", intake_content(8100), dataset: "staging")

      assert Acknowledgement.census("production").total == 1
      assert Acknowledgement.census("staging").total == 1
      assert Acknowledgement.census(nil).total == 2
      assert Acknowledgement.census("  ").total == 2
    end

    test "rows lead with the longest-waiting reporter" do
      insert_task!("gh-8100", intake_content(8100))
      :timer.sleep(1100)
      insert_task!("gh-9531", intake_content(9531))

      assert Enum.map(Acknowledgement.census(@dataset).rows, & &1.doc_id) == [
               "gh-8100",
               "gh-9531"
             ]
    end

    test "the row list caps but the counts stay exact" do
      for n <- 1..5, do: insert_task!("gh-#{9000 + n}", intake_content(9000 + n))

      census = Acknowledgement.census(@dataset, cap: 2)
      assert census.total == 5
      assert length(census.rows) == 2
    end
  end
end
