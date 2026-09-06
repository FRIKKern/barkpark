defmodule Barkpark.Tasks.CloseCancelReasonTest do
  @moduledoc """
  THE CANCEL REASON GATE (task-650d7844d8fe7199).

  Every other close-time gate EXEMPTS `cancelled` BY NAME — the criteria gate
  (PDS-D289) and the close artifact gate (PDS-D291) both wave it through,
  because abandoning the acceptance criteria is precisely what cancelling
  MEANS. Each exemption is right on its own. Their COMBINED effect was not: on
  a cancel the reason is not one record among several, it is the ENTIRE record
  of why the work stopped — and it was the one field a caller could omit.

  MEASURED 2026-09-06 ~05:27Z, twice inside one minute, on real ledger rows:
  a scripting fault expanded `$(cat reason.txt)` to the empty string, and

      bp task close task-e1920c0a8cd3013b lead-cli 1 cancelled "" --yes

  exited 0 and printed `the store holds it — lifecycle_status=cancelled`.
  Read back: lifecycle `cancelled`, `close_reason` ABSENT.

  RED-WITHOUT / GREEN-WITH. On origin/main every `refuses` test below returns
  `{:ok, doc}` — that is the defect. Every `lands` test is green on
  origin/main too and must STAY green: the blast radius of this gate is
  exactly one path — a cancel that carries no reason — and a gate that also
  refuses `done`, `blocked`, or a cancel that DOES carry a reason has replaced
  the invariant rather than implemented it.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Close
  alias BarkparkWeb.TasksController.Params

  @dataset "production"
  @epoch 1

  # A real artifact, so a `done` permit arm below is answering THIS gate and not
  # tripping PDS-D291 on the way past it.
  @artifact "landed #14383 @ 63b89bef30"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
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

  # UNCLAIMED on purpose: `check_fencing/2` and `check_close_holder/3` both pass
  # cleanly on a claimless row, so the only gate a close of this fixture can
  # trip is the one under test. Zero acceptance criteria for the same reason —
  # it is the shape the measured fault hit, and it keeps D289 vacuous.
  defp mk_task!(scope, content_extra \\ %{}) do
    doc_id = uniq("cancel-task")
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # CLAIMED, with the lease stated outright rather than taken through the claim
  # verb — this file is about what `close` does to a row already in a given
  # state. `apply_close_update/9` stamps `closed_by` onto exactly this map,
  # which is the authorship record `idempotent_replay?/3` compares against.
  defp mk_claimed_task!(scope, worker) do
    mk_task!(scope, %{
      "lifecycle_status" => "in_progress",
      "claim" => %{
        "worker" => worker,
        "epoch" => @epoch,
        "ts_iso" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })
  end

  defp close(%Document{} = doc, opts) do
    Close.close(doc.id, "worker-1", Keyword.merge([observed_epoch: @epoch], opts))
  end

  defp stored(%Document{} = doc), do: Repo.get!(Document, doc.id)

  # ─── The refusal ────────────────────────────────────────────────────────

  describe "a cancelled close with a blank reason" do
    test "is REFUSED when the reason is absent entirely", %{scope: scope} do
      doc = mk_task!(scope)

      assert {:error, :cancel_reason_required} = close(doc, lifecycle_status: "cancelled")

      # Nothing was written. The refusal aborts before any content write, so the
      # row is still cancellable the honest way; a gate that refused AFTER the
      # flip would leave a `cancelled` row wearing a refusal — which is the
      # measured defect with extra steps.
      after_refusal = stored(doc)
      assert after_refusal.content["lifecycle_status"] == "open"
      refute Map.has_key?(after_refusal.content, "close_reason")
    end

    # THE EXACT MEASURED FAULT: `$(cat reason.txt)` expanded to "".
    test "is REFUSED when the reason is the empty string", %{scope: scope} do
      doc = mk_task!(scope)

      assert {:error, :cancel_reason_required} =
               close(doc, lifecycle_status: "cancelled", reason: "")

      assert stored(doc).content["lifecycle_status"] == "open"
    end

    # Whitespace-only is STRICTLY WORSE than "" on origin/main, because it does
    # write: `apply_close_update/9` stores any non-empty binary, so a stray space
    # becomes the whole justification for abandoning a task. A gate that refused
    # "" and accepted " " would be a gate you can typo your way past.
    test "is REFUSED when the reason is whitespace only", %{scope: scope} do
      doc = mk_task!(scope)

      assert {:error, :cancel_reason_required} =
               close(doc, lifecycle_status: "cancelled", reason: "   \t\n ")

      after_refusal = stored(doc)
      assert after_refusal.content["lifecycle_status"] == "open"
      refute Map.has_key?(after_refusal.content, "close_reason")
    end

    # There is no override for this gate, on purpose — the escape hatch IS the
    # sentence. The three overrides that DO exist on this verb must not double
    # as one, or the fix becomes "reach for a flag" instead of "say why".
    test "no existing override discharges it", %{scope: scope} do
      for override <- [:criteria_override, :close_reason_override, :ack_override] do
        doc = mk_task!(scope)

        opts =
          [lifecycle_status: "cancelled", reason: ""] ++
            [{override, "closing it anyway"}]

        # Bound first, then asserted on a boolean: `assert pattern = expr, "msg"`
        # raises MatchError before assert/2 ever sees the message, so the message
        # naming WHICH override leaked would never print.
        result = close(doc, opts)

        assert result == {:error, :cancel_reason_required},
               "#{override} discharged the cancel reason gate — got #{inspect(result)}"
      end
    end

    # The refusal has to TEACH. A caller who reads only the token learns that a
    # field is missing, never why a cancel is the one status this binds on.
    test "the refusal carries a hint naming the fifth positional and no override" do
      hint = Params.criteria_hint(:cancel_reason_required, :close)

      assert is_binary(hint)
      assert String.contains?(hint, "cancelled")
      assert String.contains?(hint, "FIFTH positional")
      assert String.contains?(hint, "no override")
      # It must not invent an override flag that does not exist.
      refute String.contains?(hint, "cancel_reason_override")
    end

    # The wire token the bp CLI and any retry wrapper string-match on.
    test "renders as a stable wire token" do
      assert Params.reason_to_string(:cancel_reason_required) == "cancel_reason_required"
    end
  end

  # ─── What still lands ───────────────────────────────────────────────────

  describe "the permit arms" do
    test "a cancelled close WITH a reason lands, and stores it verbatim", %{scope: scope} do
      doc = mk_task!(scope)
      reason = "superseded by task-650d7844d8fe7199 — the ledger already refuses this shape"

      assert {:ok, %Document{content: content}} =
               close(doc, lifecycle_status: "cancelled", reason: reason)

      assert content["lifecycle_status"] == "cancelled"
      assert content["close_reason"] == reason
    end

    # A single non-space character is a reason. This gate measures PRESENCE, not
    # quality — an eloquence gate is not something a close path can adjudicate,
    # and pretending otherwise would make the refusal unpredictable.
    test "a one-character reason lands", %{scope: scope} do
      doc = mk_task!(scope)

      assert {:ok, %Document{content: %{"lifecycle_status" => "cancelled"}}} =
               close(doc, lifecycle_status: "cancelled", reason: "x")
    end

    # `blocked` is an HONEST PARTIAL — the work continues, so no final record is
    # due — and the Studio board DRAGS to blocked through `Board.restage_plan/4`
    # sending NO reason and offering nowhere to type one. Refusing blank here
    # would break a shipped UI path whose user has no fix available.
    test "a blocked close with NO reason still lands", %{scope: scope} do
      doc = mk_task!(scope)

      assert {:ok, %Document{content: %{"lifecycle_status" => "blocked"}}} =
               close(doc, lifecycle_status: "blocked")
    end

    # `done` is governed by the criteria gate and the close artifact gate; a
    # done close carrying its record in a landed digest or an artifact must not
    # be newly refused, or every lead seal close breaks.
    test "a done close whose reason is an artifact still lands", %{scope: scope} do
      doc = mk_task!(scope)

      assert {:ok, %Document{content: %{"lifecycle_status" => "done"}}} =
               close(doc, reason: @artifact)
    end

    # And a done close of a criteria-less row with NO reason must keep answering
    # D291's refusal — not this one. Two gates that answer the same shape would
    # make the message a coin flip.
    test "a done close with a blank reason still answers D291, not this gate", %{scope: scope} do
      doc = mk_task!(scope)
      assert {:error, :close_reason_needs_artifact} = close(doc, reason: "")
    end
  end

  # ─── The replay ─────────────────────────────────────────────────────────

  describe "an already-cancelled row" do
    # `idempotent_replay?/3` answers a terminal row ABOVE the `with` chain, so
    # this gate is never reached on a replay. That matters for the rows the
    # measured fault already produced: they are cancelled with no reason, and a
    # retry against one must still return its stored receipt rather than a
    # refusal it can never satisfy.
    test "replays to a success receipt even though it holds no reason", %{scope: scope} do
      worker = "worker-1"
      doc = mk_claimed_task!(scope, worker)

      # Reproduce the measured shape directly: this first close is what the
      # ledger already contains for the two rows in the filing.
      {:ok, _} =
        Close.close(doc.id, worker,
          observed_epoch: @epoch,
          lifecycle_status: "cancelled",
          reason: "a reason, so the row can be created at all under the new gate"
        )

      # The replay carries NO reason — the shape a retry wrapper re-sends.
      assert {:ok, %Document{} = replayed, :already_closed} =
               Close.close_with_receipt(doc.id, worker,
                 observed_epoch: @epoch,
                 lifecycle_status: "cancelled"
               )

      assert replayed.content["lifecycle_status"] == "cancelled"

      assert replayed.content["close_reason"] ==
               "a reason, so the row can be created at all under the new gate"
    end
  end
end
