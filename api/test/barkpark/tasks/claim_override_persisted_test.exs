defmodule Barkpark.Tasks.ClaimOverridePersistedTest do
  @moduledoc """
  task-07c21ec0d1d43e90 — the criteria-gate override was ACCEPTED and then
  DROPPED.

  MEASURED on guerrilla in a sandbox row: `POST /v1/tasks/<criteria-less
  draft>/claim` with `criteria_unstated_override="<reason>"` returned
  `ok:true, epoch 1` — the gate passed — and the raw document read back
  immediately after carried `.claim` keys exactly
  `[epoch, ts_iso, work_digest, work_field_digests, worker]`. A recursive walk
  of the whole document for any key containing "override" found nothing, before
  the close and after it. The reason was consumed by the gate and thrown away.

  Two surfaces asserted the opposite — the `--set` flag summary on `task.claim`
  (`Plugins.Tasks`) says the reason "lands on the record", and the refusal text
  (`TasksController.Params.criteria_unstated_message/2`) offers `--set
  criteria_unstated_override=…` as the way to claim "on the record". The
  assertion is where people stop looking: both promised a persistence the code
  did not have.

  ## Why this matters more than tidiness

  The override exists so a criteria-less claim is attestable AFTER the fact.
  Without the write, a row claimed with a stated reason reads back BYTE FOR BYTE
  like one claimed with none — so "was there a reason?" is not a question the
  ledger can answer, and no audit of any past override is possible.

  ## What the tests below have to prove, and in which direction

  A write is easy to assert and easy to make vacuous. The load-bearing half is
  the NEGATIVE: the key must be ABSENT — the key itself, not an empty string —
  on a claim that never needed the override. If it appeared on every claim it
  would mean "somebody typed a flag", not "this row was waved through the
  criteria gate", and it would attest nothing.

  So each direction gets its own test, and the survival tests read the STORED
  Document back through `Repo` rather than trusting the returned struct.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.{Repo, Tasks}

  @dataset "production"
  @reason "spike: the shape is the deliverable, criteria would describe not shape it"
  # A close artifact in the prose form the `done` door accepts: a PR number and
  # a hex sha. `cancelled` needs none — it is exempt by name — but it does need
  # a non-blank reason.
  @artifact "landed #17185 @ bf816c9a8f — the override rides the claim record"

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

  defp mk!(scope, extra) do
    doc_id = uniq("cop")
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # THE STORED ROW, never the returned struct.
  defp stored_claim(%Document{id: id}) do
    Repo.get!(Document, id).content["claim"] || %{}
  end

  @criterion [%{"criterion" => "the thing is measurably done", "met" => false, "evidence" => ""}]

  describe "the claim record carries the reason" do
    test "a criteria-less claim that needed the override stores it on claim.criteria_unstated_override",
         %{scope: scope} do
      doc = mk!(scope, %{})

      {:ok, _} =
        Tasks.claim_by_id(doc.doc_id, "w-cop", scope ++ [criteria_unstated_override: @reason])

      claim = stored_claim(doc)

      assert claim["criteria_unstated_override"] == @reason,
             "the reason the gate accepted must survive into the stored claim record"

      # A control on the read itself: the claim map IS the one this claim wrote,
      # so an empty/foreign map cannot masquerade as a pass.
      assert claim["worker"] == "w-cop"
      assert claim["epoch"] == 1
    end

    test "the STORED reason is trimmed, and a blank reason is no override at all",
         %{scope: scope} do
      doc = mk!(scope, %{})

      assert {:error, :criteria_unstated} =
               Tasks.claim_by_id(doc.doc_id, "w-cop", scope ++ [criteria_unstated_override: "   "])

      assert stored_claim(doc) == %{}

      {:ok, _} =
        Tasks.claim_by_id(
          doc.doc_id,
          "w-cop",
          scope ++ [criteria_unstated_override: "  #{@reason}  "]
        )

      assert stored_claim(doc)["criteria_unstated_override"] == @reason
    end

    test "a claim that did NOT need the override carries NO such key", %{scope: scope} do
      # THE NEGATIVE DIRECTION, and the one that makes the key mean something.
      # This row states criteria, so the gate never consulted the override — and
      # a reason sent anyway must NOT be recorded, because the stored key is an
      # attestation about the ROW, not a receipt for a flag.
      doc = mk!(scope, %{"acceptance_criteria" => @criterion})

      {:ok, _} =
        Tasks.claim_by_id(
          doc.doc_id,
          "w-cop",
          scope ++ [criteria_unstated_override: "sent, but never needed"]
        )

      claim = stored_claim(doc)

      refute Map.has_key?(claim, "criteria_unstated_override"),
             "an exempt row must carry no override key at all, not an empty one"

      assert claim["worker"] == "w-cop"
    end

    test "a plain criteria-less claim is refused, so no key can appear by accident",
         %{scope: scope} do
      doc = mk!(scope, %{})

      assert {:error, :criteria_unstated} = Tasks.claim_by_id(doc.doc_id, "w-cop", scope)
      assert stored_claim(doc) == %{}
    end
  end

  describe "the reason survives the lease" do
    test "it survives a renewal and a pulse", %{scope: scope} do
      doc = mk!(scope, %{})

      {:ok, _} =
        Tasks.claim_by_id(doc.doc_id, "w-cop", scope ++ [criteria_unstated_override: @reason])

      # A renewal (same worker, live claim) keeps the map it read.
      {:ok, _} = Tasks.claim_by_id(doc.doc_id, "w-cop", scope)
      assert stored_claim(doc)["criteria_unstated_override"] == @reason

      {:ok, _} = Tasks.pulse_by_id(doc.id, "w-cop", text: "still on it")

      claim = stored_claim(doc)
      assert claim["criteria_unstated_override"] == @reason
      # Control: the pulse really did run in this row, so the assertion above is
      # not passing on a document nothing touched.
      assert claim["now"]["text"] == "still on it"
    end

    test "a CANCELLED close keeps it", %{scope: scope} do
      doc = mk!(scope, %{})

      {:ok, claimed} =
        Tasks.claim_by_id(doc.doc_id, "w-cop", scope ++ [criteria_unstated_override: @reason])

      {:ok, _} =
        Tasks.close(doc.id, "w-cop",
          observed_epoch: claimed.content["claim"]["epoch"],
          lifecycle_status: "cancelled",
          reason: "abandoned: the spike answered the question"
        )

      after_close = Repo.get!(Document, doc.id)
      assert after_close.content["lifecycle_status"] == "cancelled"

      assert after_close.content["claim"]["criteria_unstated_override"] == @reason,
             "a closed claim must still say why it was allowed to start"

      assert after_close.content["claim"]["closed_by"] == "w-cop"
    end

    test "a DONE close keeps it", %{scope: scope} do
      doc = mk!(scope, %{})

      {:ok, claimed} =
        Tasks.claim_by_id(doc.doc_id, "w-cop", scope ++ [criteria_unstated_override: @reason])

      {:ok, _} =
        Tasks.close(doc.id, "w-cop",
          observed_epoch: claimed.content["claim"]["epoch"],
          lifecycle_status: "done",
          reason: @artifact
        )

      after_close = Repo.get!(Document, doc.id)
      assert after_close.content["lifecycle_status"] == "done"
      assert after_close.content["claim"]["criteria_unstated_override"] == @reason
      assert after_close.content["claim"]["closed_by"] == "w-cop"
    end
  end
end
