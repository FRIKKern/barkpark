defmodule Barkpark.Tasks.StampConcurrencyTest do
  @moduledoc """
  The OUTCOME half of the `bp task stamp` lost-update question
  (task-b4ccea2693ce9d5e, spun out of task-bf3adebfec5833df).

  ## What this is, and what it is NOT

  `test/barkpark/tasks/stamp_serialization_test.exs` is a SQL-SHAPE ORACLE: it
  watches the statements `Stamp.stamp/3` emits and asserts that an advisory
  lock is taken, that the re-read follows it, and that the update follows both.
  It pins the MECHANISM.

  This file pins the OUTCOME, and it **supersedes nothing** — the oracle stays,
  because the two catch different regressions:

    * the oracle reds when the mechanism changes shape, even if the invariant
      still holds (a `SELECT … FOR UPDATE` refactor would red it); and
    * this file reds when the invariant BREAKS, whatever shape the mechanism
      has — including a replacement that emits the same statements in the same
      order and still loses updates.

  Neither is redundant with the other, and neither alone is enough. Nothing in
  here asserts on SQL text.

  ## Why it needs its own case template

  The Ecto SQL sandbox cannot host a two-connection race — see
  `Barkpark.ConcurrencyCase` for the full reasoning and for the isolation
  mechanism that makes leaving it safe.

  ## Proven non-vacuous by mutation, 2026-09-18

  A green concurrency test is worth nothing until someone has watched it go
  red. Two mutations were applied to the code under test and both were caught,
  by DIFFERENT assertions — which is the interesting part:

    * **Delete the advisory lock** (`stamp.ex`, the
      `pg_advisory_xact_lock(hashtext($1))` line) → `assert length(accepted) ==
      @writers` fails with `left: 1, right: 6`. No update is LOST: the six
      writers all read the same `rev` and five of them lose the rev-CAS and
      return `:stale_claim`. That is the honest reading — the advisory lock is
      what makes concurrent stamps SUCCEED; the rev-CAS is the backstop that
      keeps a failure from becoming a silent loss.
    * **Delete the lock AND the rev fence** (`internal.ex`,
      `fenced_content_write/4`'s `d.rev == ^observed_rev`) → `assert lost == []`
      fails with `5 of 6 ACCEPTED stamps did not land`. That is the real
      lost update: six writers each got `{:ok, _}`, one survived in the row.

  So the two assertions are not redundant. Weakening the serialization trips
  the first; removing the loss protection underneath it trips the second.

  ## Reading a red here

  The first two tests are the harness's CONTROLS, and they red for their own
  reasons:

    * "writers overlap on separate connections" red = the harness stopped
      measuring concurrency. Fix the harness; the third test's verdict is
      worthless until it passes.
    * "an UNSERIALIZED read-modify-write loses an update" red = the harness can
      no longer SEE a lost update. That control deliberately reproduces the
      defect the filing hypothesised, with no lock, and asserts the loss
      happens. If it stops failing to protect the row, the third test's green
      proves nothing, because a green that cannot become red is theatre.
    * "every accepted stamp lands" red = the real thing. Something removed or
      weakened the serialization in `Barkpark.Tasks.Stamp`. Re-derive the
      invariant against whatever replaced it; do not relax this test.
  """

  use Barkpark.ConcurrencyCase

  alias Barkpark.{Content, Tasks}
  alias Barkpark.Tasks.Stamp

  # Six writers, six criteria slots: enough pairs (15) that a serialised
  # harness cannot pass the overlap control by luck, and well inside the test
  # pool (BARKPARK_TEST_POOL_SIZE, default 20).
  @writers 6

  setup %{dataset: dataset} do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put("dataset", dataset)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end

    %{scope: scope}
  end

  defp criterion_text(i), do: "slot #{i}"

  defp mk_task!(doc_id, dataset, scope) do
    content = %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "acceptance_criteria" =>
        for i <- 0..(@writers - 1) do
          %{"criterion" => criterion_text(i), "met" => false, "evidence" => ""}
        end
    }

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        dataset,
        scope
      )

    doc
  end

  defp criteria(uuid) do
    %{rows: [[content]]} =
      Repo.query!("SELECT content FROM documents WHERE id = $1", [Ecto.UUID.dump!(uuid)])

    content["acceptance_criteria"]
  end

  defp evidence_at(uuid, index), do: criteria(uuid) |> Enum.at(index) |> Map.get("evidence")

  describe "the harness proves its own non-vacuity" do
    test "writers overlap in wall-clock time on separate database connections" do
      runs = run_concurrently(@writers, fn _i -> Process.sleep(150) end)
      report = assert_genuinely_concurrent!(runs)

      # The span is the whole batch start-to-finish. Six 150ms sleeps run
      # SERIALLY would take ~900ms; run concurrently they take ~150ms. This is
      # a third, independent reading of the same fact, and it is the one a
      # human can sanity-check at a glance.
      assert report.span_us < 600_000,
             "six concurrent 150ms sleeps took #{report.span_us}us — that is serial, not concurrent"
    end

    test "an UNSERIALIZED read-modify-write DOES lose an update", ctx do
      %{dataset: dataset, scope: scope} = ctx
      task = mk_task!("stamp-cx-control-#{System.unique_integer([:positive])}", dataset, scope)

      # Deliberately WITHOUT the advisory lock: read the whole criteria array,
      # hold it while the sibling reads the same array, then write the whole
      # array back. This is exactly the shape task-bf3adebfec5833df
      # hypothesised, minus the protection Stamp actually has.
      runs =
        run_concurrently(2, fn i ->
          Repo.transaction(fn ->
            %{rows: [[content]]} =
              Repo.query!("SELECT content FROM documents WHERE id = $1", [
                Ecto.UUID.dump!(task.id)
              ])

            # Both writers are past their READ before either writes: the loss
            # is constructed, not raced for, so this control cannot flake.
            Process.sleep(400)

            updated =
              Map.put(
                content,
                "acceptance_criteria",
                List.update_at(
                  content["acceptance_criteria"],
                  i,
                  &Map.put(&1, "evidence", "unserialized-#{i}")
                )
              )

            Repo.query!("UPDATE documents SET content = $1 WHERE id = $2", [
              updated,
              Ecto.UUID.dump!(task.id)
            ])
          end)
        end)

      assert_genuinely_concurrent!(runs)

      landed = for i <- 0..1, evidence_at(task.id, i) == "unserialized-#{i}", do: i

      assert length(landed) < 2,
             """
             the unserialized control did NOT lose an update.

             Both writers' evidence survived, so this harness can no longer
             detect a lost update — which means the serialization test below
             is a green that cannot go red. Something (a trigger, a stricter
             isolation level, a changed column type) is protecting the row
             behind the test's back; find it before trusting anything else in
             this file.

             criteria now: #{inspect(criteria(task.id), pretty: true)}
             """
    end
  end

  describe "Stamp.stamp/3 under genuinely concurrent writers" do
    test "every accepted stamp lands — no criterion is silently dropped", ctx do
      %{dataset: dataset, scope: scope} = ctx
      doc_id = "stamp-cx-#{System.unique_integer([:positive])}"
      task = mk_task!(doc_id, dataset, scope)
      {:ok, claimed} = Tasks.claim_by_id(doc_id, "w-cx", scope)
      epoch = claimed.content["claim"]["epoch"]

      runs =
        run_concurrently(@writers, fn i ->
          Stamp.stamp(task.id, "w-cx",
            observed_epoch: epoch,
            criterion: i,
            criterion_text: criterion_text(i),
            outcome: {:met, "stamp-concurrency-#{i}"}
          )
        end)

      assert_genuinely_concurrent!(runs)

      # The discriminator is the WRITE'S OWN RECEIPT, not the row. A stamp that
      # reported failure is allowed to be absent; a stamp that reported success
      # is not. Reading the row alone is how the original hand-run nearly
      # reported rate-limited refusals as lost updates.
      accepted = Enum.filter(runs, &match?({:ok, _}, &1.result))

      assert accepted != [],
             "no stamp was accepted at all — the race was never set up. runs: #{inspect(runs, pretty: true)}"

      final = criteria(task.id)

      lost =
        for run <- accepted,
            entry = Enum.at(final, run.index),
            entry["evidence"] != "stamp-concurrency-#{run.index}" or entry["met"] != true,
            do: {run.index, entry}

      assert lost == [],
             """
             #{length(lost)} of #{length(accepted)} ACCEPTED stamps did not land.

             Each of these returned {:ok, _} to its caller and is missing from
             the published row, which is a LOST UPDATE: the serialization in
             Barkpark.Tasks.Stamp is gone or no longer covers the
             read-modify-write of content.acceptance_criteria.

             lost: #{inspect(lost, pretty: true)}
             final criteria: #{inspect(final, pretty: true)}
             """

      # THE SERIALIZATION DETECTOR. `lost == []` above catches a silent loss;
      # this catches the lock going away, which does NOT lose an update — it
      # turns five of six stamps into `:stale_claim` refusals as they lose the
      # rev-CAS. Deleting the `pg_advisory_xact_lock` line reds exactly here
      # (left: 1, right: 6). Do not relax it to `>= 1`.
      assert length(accepted) == @writers,
             """
             only #{length(accepted)} of #{@writers} concurrent stamps were accepted.

             Nothing was lost — the rev-CAS refused the rest — but the whole
             point of the close-family advisory lock is that concurrent stamps
             QUEUE and all succeed rather than fighting over one rev. This many
             refusals means stamp is no longer serializing its
             read-modify-write.

             results: #{inspect(Enum.map(runs, &{&1.index, &1.result}), pretty: true)}
             """

      assert Enum.map(final, & &1["evidence"]) ==
               for(i <- 0..(@writers - 1), do: "stamp-concurrency-#{i}")
    end
  end

  describe "the teardown predicate" do
    test "purge_dataset!/1 removes every row this test's dataset owns", ctx do
      %{dataset: dataset, scope: scope} = ctx
      doc_id = "stamp-cx-teardown-#{System.unique_integer([:positive])}"
      task = mk_task!(doc_id, dataset, scope)
      {:ok, _} = Tasks.claim_by_id(doc_id, "w-teardown", scope)

      before = count_dataset_rows(dataset)

      assert before["documents"] >= 1,
             "the fixture did not commit — this test would prove the purge works on an empty set. counts: #{inspect(before)}"

      assert Map.has_key?(before, "schema_definitions")

      # The revision is the one row the purge has to work for: `documents` does
      # NOT cascade to it (the FK is ON DELETE SET NULL), and the
      # `revisions_immutable` trigger refuses a direct DELETE. If this
      # assertion ever stops holding, the purge's trigger dance has become
      # unnecessary and should be deleted rather than left as cargo.
      assert before["revisions"] >= 1,
             "no revision was committed, so this test would not exercise the append-only purge. counts: #{inspect(before)}"

      assert %{} == purge_dataset!(dataset)

      # Re-read rather than trust the DELETE's own report.
      assert %{} == count_dataset_rows(dataset)

      assert %{rows: []} =
               Repo.query!("SELECT id FROM documents WHERE id = $1", [Ecto.UUID.dump!(task.id)])

      # The purge disables `revisions_immutable` to get past the append-only
      # guard. Leaving it disabled in a database every agent on this box shares
      # would silently retire a production invariant, so prove it came back.
      # Asked of the catalog, not of a DELETE: a row-level BEFORE DELETE
      # trigger never fires for a statement that matches no rows, so a
      # `assert_raise` on an empty delete would pass with the guard still off.
      # 'O' is enabled-on-origin, 'D' is disabled.
      assert %{rows: [["O"]]} =
               Repo.query!(
                 "SELECT tgenabled::text FROM pg_trigger WHERE tgrelid = 'revisions'::regclass AND tgname = 'revisions_immutable'",
                 []
               )
    end
  end
end
