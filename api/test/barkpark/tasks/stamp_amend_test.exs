defmodule Barkpark.Tasks.StampAmendTest do
  @moduledoc """
  THE SEALED-ROW CRITERION-TEXT AMENDMENT (task-a1df012e89b1e289).

  A criterion's TEXT was immutable once its row sealed. `--withdraw` lowers a
  met flag and `--miss` appends an attempt, but neither can touch the wording,
  `bp task close --set criteria:=[…]` is close-only, `bp task stage` reaches
  only row-level slots, and `Tasks.TerminalCriteriaFence` refuses the document
  door outright. So a criterion sentence that turns out FALSE — one asserting
  an absence `origin/main` refutes — could not be corrected anywhere a reader
  reaches.

  `--amend` is that verb, and it is `--withdraw`'s shape on purpose:

    * the superseded wording is PRESERVED on an unbounded `amendments` list,
      signed who / why / when — never a silent rewrite;
    * the criterion-text CAS is MANDATORY, exactly as it is for a met-flip and
      a withdrawal — re-wording the wrong neighbour is as much a lie as
      flipping it;
    * the fence is chosen from the STORED row's LIVENESS: an `in_progress` row
      is holder + epoch; any other row pins `--observed-rev`;
    * `met` and `evidence` are pinned, so an amendment can never fabricate or
      erase a verdict.

  BOTH SURFACES, ONE CAS. A task's `brief.blocks[criteria-list].items` is
  composed verbatim from the criterion texts, and patching one surface only is
  the exact half-fix this row was found by. It comes from
  `Internal.fenced_content_write/4`, which re-derives the mirrored blocks in
  the SAME rev-fenced `Repo.update_all` — one statement, one rev, both
  surfaces or neither. `writes both surfaces in ONE CAS write` pins it, and
  the rev-count assertion is what makes it ONE write rather than two.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Tasks.{Close, Internal, Stamp}
  alias BarkparkWeb.TasksController.Params

  import Ecto.Query, only: [from: 2]

  @dataset "production"

  @c0 "the code they describe is NOT on origin/main"
  @c1 "docs updated"

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

  defp default_criteria do
    [
      %{"criterion" => @c0, "met" => false, "evidence" => ""},
      %{"criterion" => @c1, "met" => false, "evidence" => ""}
    ]
  end

  # A task carrying a REAL brief, because the second surface is the whole point.
  # The `operator-notes` block is hand-authored prose the mirror must not touch.
  defp mk_task!(doc_id, scope, criteria \\ nil) do
    criteria = criteria || default_criteria()

    content = %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "description" => "a row whose criterion prose outlived the tree",
      "acceptance_criteria" => criteria,
      "brief" => %{
        "version" => 1,
        "blocks" => [
          %{
            "id" => "operator-notes",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "prose only a human wrote"}]
          },
          %{
            "id" => "criteria-list",
            "type" => "bulleted_list",
            "items" => Enum.map(criteria, & &1["criterion"])
          }
        ]
      }
    }

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp claim!(doc_id, worker, scope) do
    {:ok, claimed} = Tasks.claim_by_id(doc_id, worker, scope)
    {claimed, claimed.content["claim"]["epoch"]}
  end

  defp reload(task_id), do: Repo.get!(Document, task_id)
  defp criteria_of(task_id), do: reload(task_id).content["acceptance_criteria"]

  defp brief_items(task_id) do
    reload(task_id).content["brief"]["blocks"]
    |> Enum.find(&(&1["id"] == "criteria-list"))
    |> Map.get("items")
  end

  defp criterion_events(doc_id) do
    from(e in MutationEvent,
      where: e.doc_id == ^doc_id and e.mutation == "task.criterion",
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  # A row whose criterion 0 is stamped MET with real evidence and then CLOSED —
  # the exact state both live specimens are in.
  defp sealed_task!(scope, worker \\ "w") do
    doc_id = uniq("stamp-amend")
    task = mk_task!(doc_id, scope)
    {_claimed, epoch} = claim!(doc_id, worker, scope)

    {:ok, _} =
      Stamp.stamp(task.id, worker,
        observed_epoch: epoch,
        criterion: 0,
        criterion_text: @c0,
        outcome: {:met, "PR #15408 merged to main as dc91635f56"}
      )

    {:ok, closed} =
      Close.close(task.id, worker,
        observed_epoch: epoch,
        lifecycle_status: "done",
        criteria_override: "closing with criterion 1 unmet on purpose"
      )

    # THE PRECONDITION, asserted rather than assumed: every refusal below is
    # about a SEALED row, so a test whose fixture silently stayed in_progress
    # would measure the live arm and print a verdict about the sealed one.
    assert closed.content["lifecycle_status"] == "done"
    assert closed.content["claim"]["closed_at"] != nil

    {task, closed}
  end

  @new_c0 "the code they describe IS on origin/main (paper-surface.css:2061 carries overflow-wrap)"

  describe "stamp/3 — --amend corrects the wording and signs the correction" do
    test "replaces the text, preserves the superseded wording, pins met and evidence",
         %{scope: scope} do
      {task, closed} = sealed_task!(scope)

      before = Enum.at(criteria_of(task.id), 0)
      assert before["criterion"] == @c0
      assert before["met"] == true
      assert Map.get(before, "amendments") == nil

      assert {:ok, amended} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: @c0,
                 observed_rev: closed.rev,
                 amended_criterion: @new_c0,
                 outcome: {:amend, {@new_c0, "origin/main refutes the absence this asserts"}}
               )

      row = Enum.at(amended.content["acceptance_criteria"], 0)

      assert row["criterion"] == @new_c0, "the amendment did not land"

      # An amendment is NOT a verdict. It cannot fabricate a done and it cannot
      # erase a proof — both directions are pinned here.
      assert row["met"] == true, "an amendment must never move the lock"

      assert row["evidence"] == "PR #15408 merged to main as dc91635f56",
             "an amendment must never touch the evidence"

      # NEVER A SILENT REWRITE. The superseded wording is still readable, and
      # the record says who, why and when.
      assert [record] = row["amendments"]
      assert record["superseded_criterion"] == @c0
      assert record["note"] == "origin/main refutes the absence this asserts"
      assert record["worker"] == "reviewer"
      assert {:ok, _, _} = DateTime.from_iso8601(record["ts"])

      # The neighbour and the seal are untouched.
      assert Enum.at(amended.content["acceptance_criteria"], 1) ==
               %{"criterion" => @c1, "met" => false, "evidence" => ""}

      assert amended.content["lifecycle_status"] == "done"
      assert amended.content["claim"]["closed_at"] != nil
    end

    test "writes BOTH surfaces in ONE CAS write", %{scope: scope} do
      {task, closed} = sealed_task!(scope)

      assert brief_items(task.id) == [@c0, @c1],
             "fixture is broken: the brief never mirrored the criteria, so this " <>
               "test could not tell a both-surfaces write from a one-surface one"

      assert {:ok, amended} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: @c0,
                 observed_rev: closed.rev,
                 amended_criterion: @new_c0,
                 outcome: {:amend, {@new_c0, "origin/main refutes it"}}
               )

      stored = reload(task.id)

      assert stored.content["acceptance_criteria"] |> Enum.at(0) |> Map.get("criterion") ==
               @new_c0

      assert brief_items(task.id) == [@new_c0, @c1],
             "the brief still carries the superseded wording — a reader opening " <>
               "the brief (which precedes description in `bp task get`) sees the " <>
               "sentence origin/main refutes"

      # ONE write, not two: the returned doc IS the stored doc at the single new
      # rev. A second CAS write for the brief would leave stored.rev ahead of it.
      assert stored.rev == amended.rev
      assert stored.rev != closed.rev

      # The hand-authored block is untouched.
      assert stored.content["brief"]["blocks"]
             |> Enum.find(&(&1["id"] == "operator-notes"))
             |> get_in(["content", Access.at(0), "value"]) == "prose only a human wrote"
    end

    test "a second amendment APPENDS — corrections are never dropped", %{scope: scope} do
      {task, closed} = sealed_task!(scope)

      {:ok, once} =
        Stamp.stamp(task.id, "reviewer",
          observed_epoch: 0,
          criterion: 0,
          criterion_text: @c0,
          observed_rev: closed.rev,
          amended_criterion: @new_c0,
          outcome: {:amend, {@new_c0, "first correction"}}
        )

      {:ok, _twice} =
        Stamp.stamp(task.id, "reviewer-2",
          observed_epoch: 0,
          criterion: 0,
          criterion_text: @new_c0,
          observed_rev: once.rev,
          amended_criterion: "a third wording",
          outcome: {:amend, {"a third wording", "second correction"}}
        )

      assert [first, second] = Enum.at(criteria_of(task.id), 0)["amendments"]
      assert first["superseded_criterion"] == @c0
      assert first["note"] == "first correction"
      assert second["superseded_criterion"] == @new_c0
      assert second["note"] == "second correction"
      assert Enum.at(criteria_of(task.id), 0)["criterion"] == "a third wording"
    end

    test "the event carries result=amended, an amended marker and post_close", %{scope: scope} do
      {task, closed} = sealed_task!(scope)

      {:ok, _} =
        Stamp.stamp(task.id, "reviewer",
          observed_epoch: 0,
          criterion: 0,
          criterion_text: @c0,
          observed_rev: closed.rev,
          amended_criterion: @new_c0,
          outcome: {:amend, {@new_c0, "origin/main refutes it"}}
        )

      payload =
        task.doc_id
        |> criterion_events()
        |> List.last()
        |> Map.get(:document)
        |> Map.get("criterion_stamp")

      assert payload["result"] == "amended"
      assert payload["amended"] == true
      assert payload["post_close"] == true
      assert payload["index"] == 0
      assert payload["worker"] == "reviewer"
    end

    test "a merge-gated criterion is amendable without --merge-gated", %{scope: scope} do
      criteria = [
        %{
          "criterion" => "MERGE GATE (lead): the PR is merged",
          "met" => true,
          "evidence" => "PR #1 merged",
          "merge_gate" => true
        }
      ]

      doc_id = uniq("stamp-amend-gate")
      task = mk_task!(doc_id, scope, criteria)
      stored = reload(task.id)

      assert {:ok, _} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: "MERGE GATE (lead): the PR is merged",
                 observed_rev: stored.rev,
                 amended_criterion: "MERGE GATE (lead): PR #1 is merged to main",
                 outcome:
                   {:amend, {"MERGE GATE (lead): PR #1 is merged to main", "wording correction"}}
               )

      assert Enum.at(criteria_of(task.id), 0)["criterion"] ==
               "MERGE GATE (lead): PR #1 is merged to main",
             "amending a gate's WORDING cannot fabricate a done — it flips nothing"
    end
  end

  describe "stamp/3 — --amend refusals (each one writes NOTHING)" do
    test "without --observed-rev on a sealed row → :observed_rev_required", %{scope: scope} do
      {task, _closed} = sealed_task!(scope)

      assert {:error, :observed_rev_required} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: @c0,
                 amended_criterion: @new_c0,
                 outcome: {:amend, {@new_c0, "no rev pinned"}}
               )

      assert Enum.at(criteria_of(task.id), 0)["criterion"] == @c0
      assert brief_items(task.id) == [@c0, @c1]
    end

    test "a stale rev → :stale_claim — you cannot correct a row you did not read",
         %{scope: scope} do
      {task, _closed} = sealed_task!(scope)

      assert {:error, :stale_claim} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: @c0,
                 observed_rev: "not-the-rev-you-read",
                 amended_criterion: @new_c0,
                 outcome: {:amend, {@new_c0, "stale"}}
               )

      assert Enum.at(criteria_of(task.id), 0)["criterion"] == @c0
    end

    test "no criterion-text guard → :criterion_text_required", %{scope: scope} do
      {task, closed} = sealed_task!(scope)

      assert {:error, :criterion_text_required} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 observed_rev: closed.rev,
                 amended_criterion: @new_c0,
                 outcome: {:amend, {@new_c0, "unguarded index"}}
               )

      assert Enum.at(criteria_of(task.id), 0)["criterion"] == @c0
    end

    test "a guard that does not match the row → :criteria_mismatch", %{scope: scope} do
      {task, closed} = sealed_task!(scope)

      assert {:error, :criteria_mismatch} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 1,
                 criterion_text: @c0,
                 observed_rev: closed.rev,
                 amended_criterion: @new_c0,
                 outcome: {:amend, {@new_c0, "off by one"}}
               )

      assert Enum.at(criteria_of(task.id), 1)["criterion"] == @c1
    end

    test "an empty note → :note_required (a correction without a why is a silent rewrite)",
         %{scope: scope} do
      {task, closed} = sealed_task!(scope)

      assert {:error, :note_required} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: @c0,
                 observed_rev: closed.rev,
                 amended_criterion: @new_c0,
                 outcome: {:amend, {@new_c0, "   "}}
               )

      assert Enum.at(criteria_of(task.id), 0)["criterion"] == @c0
    end

    test "blank replacement wording → :amended_criterion_required", %{scope: scope} do
      {task, closed} = sealed_task!(scope)

      assert {:error, :amended_criterion_required} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: @c0,
                 observed_rev: closed.rev,
                 amended_criterion: "   ",
                 outcome: {:amend, {"   ", "blanking a criterion is a deletion, not a fix"}}
               )

      assert Enum.at(criteria_of(task.id), 0)["criterion"] == @c0
    end

    test "wording identical to the stored text → :criterion_unchanged", %{scope: scope} do
      {task, closed} = sealed_task!(scope)

      assert {:error, :criterion_unchanged} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: @c0,
                 observed_rev: closed.rev,
                 amended_criterion: @c0,
                 outcome: {:amend, {@c0, "a no-op correction record would only mislead"}}
               )

      assert Enum.at(criteria_of(task.id), 0)["amendments"] == nil
    end

    test "an amendment cannot SEED a criterion one past the end", %{scope: scope} do
      {task, closed} = sealed_task!(scope)

      assert {:error, :criteria_index_out_of_range} =
               Stamp.stamp(task.id, "reviewer",
                 observed_epoch: 0,
                 criterion: 2,
                 criterion_text: "a criterion that does not exist",
                 observed_rev: closed.rev,
                 amended_criterion: "an invented criterion",
                 outcome: {:amend, {"an invented criterion", "smuggling a new criterion in"}}
               )

      assert length(criteria_of(task.id)) == 2
    end
  end

  describe "stamp/3 — --amend on a LIVE row is fenced like any stamp" do
    test "holder + epoch fence; a stranger and a stale epoch both refuse", %{scope: scope} do
      doc_id = uniq("stamp-amend-live")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:error, :not_holder} =
               Stamp.stamp(task.id, "someone-else",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: @c0,
                 amended_criterion: @new_c0,
                 outcome: {:amend, {@new_c0, "not mine to amend"}}
               )

      assert {:error, :fenced_off} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch + 7,
                 criterion: 0,
                 criterion_text: @c0,
                 amended_criterion: @new_c0,
                 outcome: {:amend, {@new_c0, "stale epoch"}}
               )

      assert Enum.at(criteria_of(task.id), 0)["criterion"] == @c0
    end

    test "the holder amends under the live epoch, no --observed-rev needed", %{scope: scope} do
      doc_id = uniq("stamp-amend-live-ok")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, _} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: @c0,
                 amended_criterion: @new_c0,
                 outcome: {:amend, {@new_c0, "corrected mid-claim"}}
               )

      assert Enum.at(criteria_of(task.id), 0)["criterion"] == @new_c0
      assert brief_items(task.id) == [@new_c0, @c1]
    end
  end

  # ── THE TWO BLANK-WORDING GUARDS, MEASURED SEPARATELY ────────────────────
  #
  # The refusal is written TWICE on purpose — `Stamp.build_update/4` before any
  # DB work, and `Internal.merge_criteria/2` inside the write — so every caller
  # of every surface fails closed from one rule. That is also a hazard: MEASURED
  # here, deleting EITHER one alone left the whole suite above green (19/19,
  # exit 0), because the surviving sibling produced the identical atom. Two
  # guards that only ever red together are one guard with a spare.
  #
  # These two tests give each arm a detector that the other cannot satisfy. They
  # are the CLEAR for that hazard: with both guards intact they pass, and each
  # one reds when ITS guard alone is removed.
  describe "the blank-wording refusal is enforced at BOTH grains" do
    test "Stamp refuses blank wording BEFORE the transaction — on a row that does not exist" do
      # THE DISCRIMINATOR: this id resolves to nothing. If `build_update/4`
      # refuses, the answer is :amended_criterion_required and no DB read ever
      # happens. If it does not, the call reaches the transaction and the only
      # possible answer is :not_found — so this test cannot be satisfied by the
      # store-side sibling.
      absent = Ecto.UUID.generate()

      assert {:error, :amended_criterion_required} =
               Stamp.stamp(absent, "reviewer",
                 observed_epoch: 0,
                 criterion: 0,
                 criterion_text: @c0,
                 observed_rev: "whatever",
                 amended_criterion: "   ",
                 outcome: {:amend, {"   ", "blank wording must not reach the store"}}
               )
    end

    test "Internal.merge_criteria refuses blank wording at the STORE grain" do
      # Called directly, so `Stamp.build_update/4` is not in the path at all and
      # cannot answer for this arm.
      content = %{
        "acceptance_criteria" => [%{"criterion" => @c0, "met" => true, "evidence" => "e"}]
      }

      update = %{
        "index" => 0,
        "criterion" => @c0,
        "amended_criterion" => "   ",
        "amendment" => %{"note" => "why", "ts" => "2026-09-23T00:00:00Z", "worker" => "reviewer"}
      }

      assert {:error, :amended_criterion_required} = Internal.merge_criteria(content, [update])
    end

    test "Internal.merge_criteria amends BOTH nothing else — met, evidence and the neighbour" do
      content = %{
        "acceptance_criteria" => [
          %{"criterion" => @c0, "met" => true, "evidence" => "e0"},
          %{"criterion" => @c1, "met" => false, "evidence" => ""}
        ]
      }

      update = %{
        "index" => 0,
        "criterion" => @c0,
        "amended_criterion" => @new_c0,
        "amendment" => %{"note" => "why", "ts" => "2026-09-23T00:00:00Z", "worker" => "reviewer"}
      }

      assert {:ok, merged} = Internal.merge_criteria(content, [update])
      [first, second] = merged["acceptance_criteria"]

      assert first["criterion"] == @new_c0
      assert first["met"] == true
      assert first["evidence"] == "e0"
      assert [%{"superseded_criterion" => @c0}] = first["amendments"]
      assert second == %{"criterion" => @c1, "met" => false, "evidence" => ""}
    end
  end

  describe "Params.parse_stamp/1 — the --amend wire shape" do
    test "kebab and snake spellings both reach the amend outcome" do
      for key <- ["amended_criterion", "amended-criterion"] do
        assert {:ok, 0, {:amend, {"NEW", "why"}}, "OLD"} =
                 Params.parse_stamp(%{
                   "criterion" => 0,
                   "amend" => "true",
                   key => "NEW",
                   "note" => "why",
                   "criterion_text" => "OLD"
                 })
      end
    end

    test "--amend without replacement wording is a 400, not a silent deletion" do
      assert {:error, :invalid_stamp, msg} =
               Params.parse_stamp(%{"criterion" => 0, "amend" => "true", "note" => "why"})

      assert msg =~ "amended-criterion"
    end

    test "--amend without a note is a 400" do
      assert {:error, :invalid_stamp, msg} =
               Params.parse_stamp(%{
                 "criterion" => 0,
                 "amend" => "true",
                 "amended_criterion" => "NEW"
               })

      # The catch-all "pass one of --met/--miss/--withdraw" sentence ALSO
      # contains "--note", so a loose match here passes on a server that never
      # learned the verb at all. Match the amend-specific sentence.
      assert msg =~ "--amend requires non-empty --note"
    end

    test "--amend with another verb is refused" do
      assert {:error, :invalid_stamp, msg} =
               Params.parse_stamp(%{
                 "criterion" => 0,
                 "amend" => "true",
                 "withdraw" => "true",
                 "note" => "why",
                 "amended_criterion" => "NEW"
               })

      assert msg =~ "exactly one"
    end
  end
end
