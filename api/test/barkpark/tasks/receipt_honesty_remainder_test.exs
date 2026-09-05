defmodule Barkpark.Tasks.ReceiptHonestyRemainderTest do
  @moduledoc """
  PDS-D451, THE REMAINING ARMS — release, pulse, stage, do_move, the two
  `Tasks.Mutations` arms, and the `Fleet` beat.

  `receipt_honesty_test.exs` pinned the six arms the core slice paid (claim,
  renew, stamp, close, merge-reconcile, cascade-unblock). These are the other
  seven, and the point of this file is that each one is MEASURED SEPARATELY.
  Their source shape is identical — a CAS-fenced
  `Repo.update_all(set: [content:, rev:, updated_at:])` followed by
  `%{doc | content: …, rev: …}` — but "identical shape" is an inference, and
  quoting one arm's measurement as covering its six siblings is precisely the
  one-paid-site-certifies-its-siblings error this wave exists to kill. Every
  arm below drives its own real verb and names its own divergent key set.

  TWO CONTROLS RIDE HERE DELIBERATELY, AND NEITHER IS A DEFECT:

    * `move.ex`'s NOOP arm (`same_parent?` → `{:noop, doc}`) performs NO WRITE
      AT ALL — it returns the row it read under the advisory lock. It is the
      family's one proven-honest receipt and it is the CONTROL that proves the
      label discriminates: routing it through `fenced_content_write/4` would
      INTRODUCE a write and destroy it. It is pinned here as honest, untouched.

    * `Fleet.beat`'s registration arm returns a `Content.create_document`
      persisted struct — already the stored row. Untouched.

  AND ONE HONEST-BUT-FRAGILE ARM. `Fleet`'s beat reconstruction IS
  struct-divergent, but its receipt is WIRE-CONVERGENT: `receipt/2` projects
  only content-derived keys (id, worker, status, last_seen, ttl_s) and emits
  no rev, no inserted_at, no updated_at, and `last_seen` is stamped INSIDE the
  written content. It does not currently lie. Its honesty is incidental, not
  principled — the moment anyone adds `rev` or `updated_at` to `receipt/2` it
  becomes a lie — so the beat arm is paid for fence-consistency AND the
  projection is pinned below. It is NOT claimed to have been divergent.

  THE MEASURED DIVERGENCE IS EXACTLY `updated_at`. The `documents` generated
  columns (`slug_text`/`author_text`/`category_text`) are a real CLASS risk
  that a struct-merge cannot recompute, but PDS-D451 already bounded it and
  no arm here writes a mirrored key — this file does not claim tasks ship
  wrong slugs, and the generated-column equality is asserted rather than
  assumed.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [where: 3]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Fleet, Internal, Move, Mutations, Pulse, Release, Stage}
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

  # Content that deliberately carries the three keys the GENERATED columns
  # mirror, so the generated-column assertion below is not vacuous.
  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          # A claimable fixture states its bar (task-9554c64bf51a0f81): the
          # claim-time gate refuses a criteria-less work row, so a fixture that
          # omits them is testing a row nobody can claim.
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ],
          "lifecycle_status" => "open",
          "slug" => doc_id,
          "author" => "receipt-remainder",
          "category" => "pds"
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

  # THE MEASUREMENT. Named divergent keys at the WIRE (the exact renderer the
  # controller uses) and at the STRUCT, plus the generated-column check, so a
  # failure says WHICH field lied instead of "a 20-key map differs".
  @struct_lens [:content, :rev, :updated_at, :inserted_at]
  @generated_lens [:slug_text, :author_text, :category_text]

  defp assert_receipt_is_stored!(%Document{} = receipt, verb, pre_updated_at \\ nil) do
    stored = Repo.get!(Document, receipt.id)
    rendered_receipt = Params.render_doc(receipt)
    rendered_stored = Params.render_doc(stored)

    wire_divergent =
      rendered_stored
      |> Map.keys()
      |> Enum.filter(&(Map.get(rendered_receipt, &1) != Map.get(rendered_stored, &1)))

    struct_divergent =
      Enum.filter(@struct_lens, &(Map.get(receipt, &1) != Map.get(stored, &1)))

    generated_divergent =
      Enum.filter(@generated_lens, &(Map.get(receipt, &1) != Map.get(stored, &1)))

    # THE LINEAGE, MEASURED FIRST. Equality alone is not enough: a receipt that
    # equals storage because NOTHING was written would pass the check below.
    # The pre-write timestamp is what the reconstruction shipped — the receipt
    # must have LEFT it. This half of the proof survives after payment.
    if pre_updated_at do
      refute receipt.updated_at == pre_updated_at,
             """
             #{verb}: the receipt is still carrying the PRE-write timestamp —
             the reconstruction survived (or the write did not land).
             pre-write stored: #{inspect(pre_updated_at)}
             receipt:          #{inspect(receipt.updated_at)}
             post-write stored:#{inspect(stored.updated_at)}
             """
    end

    assert {wire_divergent, struct_divergent, generated_divergent} == {[], [], []},
           """
           #{verb}: the receipt is not the stored row.
           divergent keys (WIRE):      #{inspect(wire_divergent)}
           divergent fields (STRUCT):  #{inspect(struct_divergent)}
           divergent GENERATED cols:   #{inspect(generated_divergent)}
           receipt: #{inspect(Map.take(rendered_receipt, wire_divergent))}
           stored:  #{inspect(Map.take(rendered_stored, wire_divergent))}
           """

    stored
  end

  defp pre_updated_at!(uuid), do: Repo.get!(Document, uuid).updated_at

  describe "the seven remaining write arms return the stored row" do
    test "release (release.ex apply_release_update)", %{scope: scope} do
      doc_id = uniq("rem-release")
      _task = mk_task!(doc_id, scope)

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w-rem", scope)
      pre = pre_updated_at!(claimed.id)

      assert {:ok, released} =
               Release.release(claimed.id, "w-rem",
                 observed_epoch: claimed.content["claim"]["epoch"]
               )

      stored = assert_receipt_is_stored!(released, "release", pre)
      assert stored.content["lifecycle_status"] == "open"
    end

    test "pulse (pulse.ex apply_pulse)", %{scope: scope} do
      doc_id = uniq("rem-pulse")
      _task = mk_task!(doc_id, scope)

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w-rem", scope)
      pre = pre_updated_at!(claimed.id)

      assert {:ok, pulsed} = Pulse.pulse(claimed.id, "w-rem", text: "measuring this arm")

      stored = assert_receipt_is_stored!(pulsed, "pulse", pre)
      assert stored.content["claim"]["now"]["text"] == "measuring this arm"
    end

    test "stage (stage.ex do_stage)", %{scope: scope} do
      doc_id = uniq("rem-stage")
      task = mk_task!(doc_id, scope)

      pre = pre_updated_at!(task.id)

      assert {:ok, staged} = Stage.stage(task.id, "considering", object: "research")

      stored = assert_receipt_is_stored!(staged, "stage", pre)
      assert stored.content["lifecycle_status"] == "considering"
    end

    test "move (move.ex do_move)", %{scope: scope} do
      parent_id = uniq("rem-move-parent")
      child_id = uniq("rem-move-child")

      _parent = mk_task!(parent_id, scope)
      child = mk_task!(child_id, scope)

      pre = pre_updated_at!(child.id)

      assert {:ok, moved} = Move.move(child.id, parent_id)

      stored = assert_receipt_is_stored!(moved, "move/do_move", pre)
      assert stored.content["parent_id"] == parent_id
    end

    test "relabel (mutations.ex relabel_by_id)", %{scope: scope} do
      doc_id = uniq("rem-relabel")
      task = mk_task!(doc_id, scope)

      pre = pre_updated_at!(task.id)

      assert {:ok, relabeled} = Mutations.relabel_by_id(task.id, ["measured"], [])

      stored = assert_receipt_is_stored!(relabeled, "relabel", pre)
      assert stored.content["labels"] == ["measured"]
    end

    test "paper refs (mutations.ex update_ref_list_by_id via papers)", %{scope: scope} do
      doc_id = uniq("rem-papers")
      task = mk_task!(doc_id, scope)

      pre = pre_updated_at!(task.id)

      assert {:ok, referenced} =
               Mutations.update_paper_refs_by_id(task.id, ["pds-wave-34-2026-08-01"], [])

      stored = assert_receipt_is_stored!(referenced, "update_paper_refs", pre)
      assert stored.content["papers"] == ["pds-wave-34-2026-08-01"]
    end

    test "session refs (mutations.ex update_ref_list_by_id — the SAME arm, second endpoint)",
         %{scope: scope} do
      doc_id = uniq("rem-sessions")
      task = mk_task!(doc_id, scope)

      pre = pre_updated_at!(task.id)

      assert {:ok, referenced} =
               Mutations.update_session_refs_by_id(task.id, ["session-rem"], [])

      stored = assert_receipt_is_stored!(referenced, "update_session_refs", pre)
      assert stored.content["sessions"] == ["session-rem"]
    end
  end

  # The listener row is created through the draft/published twin machinery, so
  # its stored doc_id is either the logical id or its `drafts.` twin.
  defp stored_listener!(worker) do
    logical = "listener-" <> worker

    Document
    |> where([d], d.type == "listener" and d.doc_id in ^[logical, "drafts." <> logical])
    |> Repo.all()
    |> case do
      [row] -> row
      rows -> Enum.find(rows, &(&1.status == "published")) || hd(rows)
    end
  end

  describe "the fleet beat arm" do
    # The beat receipt is a PROJECTION, not a Document, so honesty here is
    # "every projected key equals the stored row's value", not struct equality.
    test "the beat receipt's every key is the stored listener row", %{scope: scope} do
      worker = uniq("rem-fleet")

      assert {:ok, %{registered: true}} =
               Fleet.beat(%{"worker" => worker}, @dataset, scope)

      assert {:ok, %{registered: false, doc: receipt}} =
               Fleet.beat(%{"worker" => worker, "status" => "working"}, @dataset, scope)

      stored = stored_listener!(worker)

      assert receipt["worker"] == stored.content["worker"]
      assert receipt["status"] == stored.content["status"]
      assert receipt["last_seen"] == stored.content["last_seen"]
      assert receipt["ttl_s"] == stored.content["ttl_s"]
      assert receipt["status"] == "working"
    end

    # THE PROJECTION PIN. The beat receipt is wire-convergent ONLY because
    # `receipt/2` emits content-derived keys and nothing else. Adding `rev` or
    # `updated_at` to it would make it a lie with no other test to catch it —
    # this is that test.
    test "the beat receipt projects content-derived keys ONLY (no rev/updated_at)", %{
      scope: scope
    } do
      worker = uniq("rem-fleet-proj")

      assert {:ok, _} = Fleet.beat(%{"worker" => worker}, @dataset, scope)
      assert {:ok, %{doc: receipt}} = Fleet.beat(%{"worker" => worker}, @dataset, scope)

      assert Map.keys(receipt) |> Enum.sort() == ~w(id last_seen status ttl_s worker),
             """
             the fleet beat receipt grew a key. Every key it projects must be
             derived from the CONTENT it wrote; `rev`, `updated_at` and
             `inserted_at` are row metadata the projection cannot honestly
             carry unless it reads them from the stored row.
             got: #{inspect(Map.keys(receipt))}
             """
    end

    # CONTROL: registration returns a persisted struct, already the stored row.
    test "registration (control) — the first beat's receipt is the created row", %{scope: scope} do
      worker = uniq("rem-fleet-reg")

      assert {:ok, %{registered: true, doc: receipt}} =
               Fleet.beat(%{"worker" => worker}, @dataset, scope)

      stored = stored_listener!(worker)
      assert receipt["worker"] == stored.content["worker"]
      assert receipt["last_seen"] == stored.content["last_seen"]
    end
  end

  describe "the NOOP control (move.ex :84-86) — no write, and it stays that way" do
    # This arm is EXPLICITLY OUT OF SCOPE for payment. It returns the row read
    # under the advisory lock without writing anything, so its receipt is
    # trivially the stored row. It is the control that proves the divergence
    # label above discriminates: if this ever measured divergent, the harness
    # is broken, not the arm.
    test "a same-parent move measures ZERO divergent fields and writes nothing", %{scope: scope} do
      parent_id = uniq("noop-parent")
      child_id = uniq("noop-child")

      _parent = mk_task!(parent_id, scope)
      child = mk_task!(child_id, scope, %{"parent_id" => parent_id})

      before = Repo.get!(Document, child.id)

      assert {:ok, noop} = Move.move(child.id, parent_id)

      assert_receipt_is_stored!(noop, "move/NOOP")

      after_row = Repo.get!(Document, child.id)

      assert after_row.rev == before.rev, "the NOOP arm wrote a new rev — it is no longer a NOOP"

      assert after_row.updated_at == before.updated_at,
             "the NOOP arm touched updated_at — it is no longer a NOOP"
    end
  end

  describe "the fence is unchanged" do
    # HONEST SCOPE OF THIS PROOF: every arm here holds a per-task advisory lock
    # and re-reads the row inside it, so no public call sequence can make one
    # of them LOSE its CAS on demand — the 0-row branch is unreachable through
    # the API. What is reachable, and what actually changed, is the shared
    # helper the seven arms now call: it must still refuse a lost fence with
    # `:stale` (which every arm maps to its existing `{:error, :stale_claim}` /
    # `{:error, :stale_beat}`) now that the query carries a `select:` — a
    # `select:` on a 0-row UPDATE must not turn into a silent success.
    test "fenced_content_write refuses a lost fence and writes nothing", %{scope: scope} do
      doc_id = uniq("rem-stale")
      task = mk_task!(doc_id, scope)

      assert {:ok, _} = Mutations.relabel_by_id(task.id, ["first"], [])

      stored = Repo.get!(Document, task.id)
      stale_rev = "deadbeefdeadbeefdeadbeefdeadbeef"

      assert :stale =
               Internal.fenced_content_write(
                 stored,
                 stale_rev,
                 %{"labels" => ["should not land"]},
                 "00000000000000000000000000000000"
               )

      after_row = Repo.get!(Document, task.id)

      assert after_row.content["labels"] == ["first"], "the refused write landed anyway"
      assert after_row.rev == stored.rev, "the refused write moved the rev"
    end
  end
end
