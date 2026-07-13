defmodule Barkpark.Tasks.StampTest do
  @moduledoc """
  Unit + integration tests for `Barkpark.Tasks.Stamp` (expressive-agent-loops
  D3/D6/D7/D8 — criterion-level mid-claim evidence).

  Covers:
    1. `--met` lands evidence atomically; other entries + the claim untouched.
    2. Evidence or nothing: a met without non-empty evidence never reaches the DB.
    3. `--miss` appends {note,ts,worker} WITHOUT flipping met — met pinned
       explicitly (never the parse default), attempts bounded to the 5 most recent.
    4. Auth: wrong worker → :not_holder; wrong epoch → :fenced_off (close's
       fence); no live claim → {:not_in_progress, status}; unknown id → :not_found.
    5. D5 integration: stamp-then-DEFAULT-path-close succeeds with identical
       evidence at close; a criterion-TEXT edit still 409s doc_changed_since_claim.
    6. A `task.criterion` mutation_event is emitted on BOTH paths in the same
       transaction, carrying the criterion_stamp payload.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Tasks.{Close, Internal, Stamp}

  import Ecto.Query, only: [from: 2]

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

    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp default_criteria do
    [
      %{"criterion" => "gate passes", "met" => false, "evidence" => ""},
      %{"criterion" => "docs updated", "met" => false, "evidence" => ""}
    ]
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => default_criteria()
        },
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # Claim through the real primitive so the lease carries a work_digest —
  # the D5 integration tests depend on the genuine claim-time stamp.
  defp claim!(doc_id, worker, scope) do
    {:ok, claimed} = Tasks.claim_by_id(doc_id, worker, scope)
    {claimed, claimed.content["claim"]["epoch"]}
  end

  defp criterion_events(doc_id) do
    from(e in MutationEvent,
      where: e.doc_id == ^doc_id and e.mutation == "task.criterion",
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  # ─── (1) --met lands evidence atomically ───────────────────────────────────

  describe "stamp/3 — met with evidence" do
    test "flips met + writes evidence on the targeted row only; claim untouched", %{scope: scope} do
      doc_id = uniq("stamp-met")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:met, "42 tests green: stamp_test.exs"}
               )

      [first, second] = stamped.content["acceptance_criteria"]
      assert first["met"] == true
      assert first["evidence"] == "42 tests green: stamp_test.exs"
      assert first["criterion"] == "gate passes", "criterion text never rewritten"
      assert second == %{"criterion" => "docs updated", "met" => false, "evidence" => ""}

      # Progress, not the seal: still in_progress, lease + epoch untouched.
      assert stamped.content["lifecycle_status"] == "in_progress"
      assert stamped.content["claim"]["worker"] == "w"
      assert stamped.content["claim"]["epoch"] == epoch
    end

    test "index out of range refuses without partial state", %{scope: scope} do
      doc_id = uniq("stamp-range")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:error, :criteria_index_out_of_range} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 9,
                 outcome: {:met, "phantom"}
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["acceptance_criteria"] == default_criteria()
      assert criterion_events(task.doc_id) == [], "no event for a refused stamp"
    end
  end

  # ─── (2) Evidence or nothing ───────────────────────────────────────────────

  describe "stamp/3 — met REQUIRES non-empty evidence" do
    test "empty / missing / non-string evidence is rejected before any write", %{scope: scope} do
      doc_id = uniq("stamp-noev")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      for bad <- ["", nil, 42] do
        assert {:error, :evidence_required} =
                 Stamp.stamp(task.id, "w",
                   observed_epoch: epoch,
                   criterion: 0,
                   outcome: {:met, bad}
                 )
      end

      reloaded = Repo.get!(Document, task.id)
      assert [%{"met" => false} | _] = reloaded.content["acceptance_criteria"]
      assert criterion_events(task.doc_id) == []
    end

    test "a miss without a note is likewise rejected", %{scope: scope} do
      doc_id = uniq("stamp-nonote")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:error, :note_required} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:miss, ""}
               )
    end
  end

  # ─── (3) --miss: honest attempts, met never flips ──────────────────────────

  describe "stamp/3 — miss records the attempt without flipping" do
    test "appends {note,ts,worker} and PINS met explicitly to false when unset", %{scope: scope} do
      doc_id = uniq("stamp-miss")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:miss, "sandbox flake — retrying with shared mode"}
               )

      [first | _] = stamped.content["acceptance_criteria"]

      # The proven footgun: parse/merge defaults met→true when absent. The miss
      # path must write met EXPLICITLY — assert the key is present AND false.
      assert Map.fetch!(first, "met") == false

      assert [attempt] = first["attempts"]
      assert attempt["note"] == "sandbox flake — retrying with shared mode"
      assert attempt["worker"] == "w"
      assert {:ok, _, _} = DateTime.from_iso8601(attempt["ts"])
    end

    test "a miss AFTER a met keeps the lock flipped (met stays true)", %{scope: scope} do
      doc_id = uniq("stamp-miss-after-met")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, _} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:met, "proved once"}
               )

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:miss, "regression probe failed — investigating"}
               )

      [first | _] = stamped.content["acceptance_criteria"]
      assert first["met"] == true, "a miss never UNflips either — it only records"
      assert length(first["attempts"]) == 1
    end

    test "attempts are bounded to the 5 most recent", %{scope: scope} do
      doc_id = uniq("stamp-bound")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      for n <- 1..7 do
        assert {:ok, _} =
                 Stamp.stamp(task.id, "w",
                   observed_epoch: epoch,
                   criterion: 0,
                   outcome: {:miss, "attempt #{n}"}
                 )
      end

      [first | _] = Repo.get!(Document, task.id).content["acceptance_criteria"]
      notes = Enum.map(first["attempts"], & &1["note"])
      assert notes == ["attempt 3", "attempt 4", "attempt 5", "attempt 6", "attempt 7"]
    end
  end

  # ─── (4) Auth: holder + epoch fence ────────────────────────────────────────

  describe "stamp/3 — holder + fencing" do
    test "a non-holder cannot stamp", %{scope: scope} do
      doc_id = uniq("stamp-holder")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:error, :not_holder} =
               Stamp.stamp(task.id, "intruder",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:met, "not mine to prove"}
               )
    end

    test "a stale epoch is fenced off exactly like close", %{scope: scope} do
      doc_id = uniq("stamp-fence")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:error, :fenced_off} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch + 1,
                 criterion: 0,
                 outcome: {:met, "late write"}
               )

      # Recovery is close's documented path: same-worker re-claim (renewal,
      # epoch bumps) then restamp with the fresh epoch.
      {:ok, renewed} = Tasks.claim_by_id(doc_id, "w", scope)
      fresh_epoch = renewed.content["claim"]["epoch"]

      assert {:ok, _} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: fresh_epoch,
                 criterion: 0,
                 outcome: {:met, "restamped after renewal"}
               )
    end

    test "a task without a live claim is not stampable", %{scope: scope} do
      doc_id = uniq("stamp-unclaimed")
      task = mk_task!(doc_id, scope)

      assert {:error, {:not_in_progress, "open"}} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: 1,
                 criterion: 0,
                 outcome: {:met, "no claim yet"}
               )
    end

    test "unknown task id → :not_found" do
      assert {:error, :not_found} =
               Stamp.stamp("00000000-0000-0000-0000-000000000099", "w",
                 observed_epoch: 1,
                 criterion: 0,
                 outcome: {:met, "ghost"}
               )
    end
  end

  # ─── (5) D5 integration: stamp never fences the worker's own close ────────

  describe "stamp/3 — D5 work-digest narrowing (the close handshake)" do
    test "mid-claim stamps then the DEFAULT-path close succeeds, evidence identical at close",
         %{scope: scope} do
      doc_id = uniq("stamp-then-close")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, _} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:met, "gate output: 12 tests, 0 failures"}
               )

      assert {:ok, _} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 1,
                 outcome: {:miss, "docs pending review"}
               )

      # DEFAULT path — no observed_rev. Before D5 this 409'd
      # doc_changed_since_claim on ["acceptance_criteria"] by construction.
      assert {:ok, closed} =
               Close.close(task.id, "w", observed_epoch: epoch, lifecycle_status: "done")

      assert closed.content["lifecycle_status"] == "done"

      # No divergence: what was stamped mid-claim is EXACTLY what close sealed.
      [first, second] = closed.content["acceptance_criteria"]
      assert first["met"] == true
      assert first["evidence"] == "gate output: 12 tests, 0 failures"
      assert second["met"] == false
      assert [%{"note" => "docs pending review"}] = second["attempts"]
    end

    test "a foreign criterion-TEXT edit still trips doc_changed_since_claim", %{scope: scope} do
      doc_id = uniq("stamp-text-fence")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      # Someone rewrites a criterion's TEXT under the claim (raw CAS write that
      # preserves the claim, mirroring close_test's foreign_patch_content!).
      doc = Repo.get!(Document, task.id)

      rewritten =
        List.update_at(doc.content["acceptance_criteria"], 0, fn entry ->
          Map.put(entry, "criterion", "gate passes ON ARM64 TOO")
        end)

      new_content = Map.put(doc.content, "acceptance_criteria", rewritten)

      {1, _} =
        from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev)
        |> Repo.update_all(set: [content: new_content, rev: Internal.generate_rev()])

      assert {:error, {:doc_changed_since_claim, _rev, ["acceptance_criteria"]}} =
               Close.close(task.id, "w", observed_epoch: epoch, lifecycle_status: "done")
    end
  end

  # ─── (6) task.criterion mutation_event, same transaction ─────────────────

  describe "stamp/3 — task.criterion event" do
    test "both paths emit the event with the criterion_stamp payload", %{scope: scope} do
      doc_id = uniq("stamp-event")
      task = mk_task!(doc_id, scope)
      {_claimed, epoch} = claim!(doc_id, "w", scope)

      assert {:ok, met_doc} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:met, "proof attached"}
               )

      assert {:ok, miss_doc} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 1,
                 outcome: {:miss, "second lock still resists"}
               )

      assert [met_ev, miss_ev] = criterion_events(met_doc.doc_id)
      assert met_ev.mutation == Tasks.event_kinds().criterion

      assert met_ev.document["criterion_stamp"] ==
               %{"index" => 0, "result" => "met", "worker" => "w"}

      assert miss_ev.document["criterion_stamp"] ==
               %{"index" => 1, "result" => "miss", "worker" => "w"}

      # Durable-then-ack: each event row pins the post-stamp rev + previous rev,
      # written in the SAME transaction as the criteria write.
      assert met_ev.rev == met_doc.rev
      assert miss_ev.rev == miss_doc.rev
      assert miss_ev.previous_rev == met_doc.rev
    end
  end
end
