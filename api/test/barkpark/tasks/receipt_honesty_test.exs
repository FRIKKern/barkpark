defmodule Barkpark.Tasks.ReceiptHonestyTest do
  @moduledoc """
  PDS-D451 — THE LEDGER'S OWN RECEIPT MUST BE THE ROW POSTGRES HOLDS.

  The epic's law is "no Barkpark verb may report success on an exit code alone".
  Every task CAS write path used to break it in the smallest possible way: the
  fenced `Repo.update_all` returns a ROW COUNT, and the receipt handed back to
  the caller was then RECONSTRUCTED as `%{doc | content: …, rev: …}` — a
  statement of intent. `updated_at` was written to the DB and omitted from the
  struct, so every claim/renew/stamp/close receipt shipped the PREVIOUS write's
  timestamp, deterministically, on every verb.

  These tests drive the real verbs and assert the receipt is BYTE-EQUAL to the
  stored row, rendered through the exact function that reaches the wire
  (`TasksController.Params.render_doc/1`), with the divergent keys NAMED on
  failure rather than a bare `assert ==`.

  The cascade-unblock arm gets its own test at the BROADCAST, not the return:
  its receipt never reaches an HTTP caller — `Content.Broadcast` copies
  `doc.updated_at` onto three PubSub topics, so a stale value there reaches
  every LiveView and SSE consumer.

  And the fence itself is re-proven: a lost CAS must still be `:stale_claim`.
  This is a receipt change, not a semantics change.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Close, Edges, Stamp}
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

    # Deliberately NOT `Sandbox.mode(Repo, {:shared, self()})`: every verb under
    # test runs its transaction — and fires its broadcast — in THIS process, so
    # the checked-out connection is enough. Flipping the sandbox to shared from a
    # sync case is what produced an intermittent 40P01 deadlock here.
    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # PDS-D291: one MET criterion keeps this file's `done` closes out of the
  # close-artifact gate, which refuses a `done` close of a criteria-less
  # kind:task row whose reason names no PR+sha and pastes no run. These
  # tests measure the returned receipt and the fence, not the close reason.
  # The stale-rev case matters most: the honesty gates run AHEAD of the rev
  # CAS (D289 already does), so without a criterion that test would hear the
  # artifact refusal instead of the `:stale_claim` it exists to pin.
  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
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

  # The whole point, in one function: the receipt a verb hands back, rendered
  # exactly as the controller renders it, must equal the row the DATABASE holds
  # — with the divergent keys named, because "assert a == b" on a 20-key map
  # tells you nothing about WHICH field lied.
  defp assert_receipt_is_stored!(%Document{} = receipt, verb) do
    stored = Repo.get!(Document, receipt.id)
    rendered_receipt = Params.render_doc(receipt)
    rendered_stored = Params.render_doc(stored)

    divergent =
      rendered_stored
      |> Map.keys()
      |> Enum.filter(fn key ->
        Map.get(rendered_receipt, key) != Map.get(rendered_stored, key)
      end)

    assert divergent == [],
           """
           #{verb}: the receipt is not the stored row.
           divergent keys: #{inspect(divergent)}
           receipt: #{inspect(Map.take(rendered_receipt, divergent))}
           stored:  #{inspect(Map.take(rendered_stored, divergent))}
           """

    stored
  end

  describe "the four caller-facing arms return the stored row" do
    test "claim (claim.ex do_claim)", %{scope: scope} do
      doc_id = uniq("receipt-claim")
      _task = mk_task!(doc_id, scope)

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w-receipt", scope)
      assert_receipt_is_stored!(claimed, "claim")
    end

    test "renew (claim.ex do_renew)", %{scope: scope} do
      doc_id = uniq("receipt-renew")
      _task = mk_task!(doc_id, scope)

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w-receipt", scope)
      # A targeted claim by the SAME worker on an in_progress task IS the renew
      # path (rail-l4), not a second claim.
      assert {:ok, renewed} = Tasks.claim_by_id(doc_id, "w-receipt", scope)
      assert renewed.content["claim"]["epoch"] == claimed.content["claim"]["epoch"] + 1

      assert_receipt_is_stored!(renewed, "renew")
    end

    test "stamp (stamp.ex apply_stamp_update)", %{scope: scope} do
      doc_id = uniq("receipt-stamp")

      task =
        mk_task!(doc_id, scope, %{
          "acceptance_criteria" => [
            %{"criterion" => "gate passes", "met" => false, "evidence" => ""}
          ]
        })

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w-receipt", scope)

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w-receipt",
                 observed_epoch: claimed.content["claim"]["epoch"],
                 criterion: 0,
                 criterion_text: "gate passes",
                 outcome: {:met, "receipt_honesty_test.exs green"}
               )

      assert_receipt_is_stored!(stamped, "stamp")
    end

    test "close (close.ex apply_close_update)", %{scope: scope} do
      doc_id = uniq("receipt-close")
      task = mk_task!(doc_id, scope)

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w-receipt", scope)

      assert {:ok, closed} =
               Close.close(task.id, "w-receipt",
                 observed_epoch: claimed.content["claim"]["epoch"],
                 reason: "receipt honesty"
               )

      stored = assert_receipt_is_stored!(closed, "close")
      assert stored.content["lifecycle_status"] == "done"
    end

    test "merge reconcile (close.ex write_reconcile)", %{scope: scope} do
      doc_id = uniq("receipt-reconcile")

      task =
        mk_task!(doc_id, scope, %{
          "acceptance_criteria" => [
            %{
              "criterion" => "PR merged",
              "met" => false,
              "evidence" => "",
              "merge_gate" => true
            }
          ]
        })

      # `reconcile_merge_gate/3` returns only the stamped indices to its caller;
      # its receipt reaches the world through the broadcast, so that is where it
      # is checked.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")

      assert {:ok, :stamped, [0]} =
               Close.reconcile_merge_gate(task.id, %{"prs" => ["8764"]})

      task_doc_id = task.doc_id

      assert_receive {:document_changed,
                      %{
                        mutation: "task.criterion",
                        doc_id: ^task_doc_id,
                        doc: %{updated_at: broadcast_updated_at}
                      }},
                     2_000

      assert broadcast_updated_at == Repo.get!(Document, task.id).updated_at,
             "the merge-reconcile broadcast shipped a timestamp the DB does not hold"
    end
  end

  describe "the cascade-unblock arm is honest at the BROADCAST" do
    test "the unblocked dependent's broadcast carries the STORED updated_at", %{scope: scope} do
      blocker_id = uniq("receipt-blocker")
      dependent_id = uniq("receipt-dependent")

      blocker = mk_task!(blocker_id, scope)
      dependent = mk_task!(dependent_id, scope, %{"lifecycle_status" => "blocked"})

      {:ok, _edge} = Edges.add_dep(dependent.id, blocker.id, :blocks)

      # The dependent's PRE-close stored timestamp — the value a reconstructed
      # receipt would have broadcast.
      pre_close_updated_at = Repo.get!(Document, dependent.id).updated_at

      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")

      assert {:ok, claimed} = Tasks.claim_by_id(blocker_id, "w-receipt", scope)

      assert {:ok, _closed} =
               Close.close(blocker.id, "w-receipt",
                 observed_epoch: claimed.content["claim"]["epoch"],
                 reason: "unblock the dependent"
               )

      dependent_doc_id = dependent.doc_id

      assert_receive {:document_changed,
                      %{
                        mutation: "task.mutated",
                        doc_id: ^dependent_doc_id,
                        doc: %{content: content, updated_at: broadcast_updated_at}
                      }},
                     2_000

      assert content["lifecycle_status"] == "open", "the cascade actually unblocked it"

      stored_updated_at = Repo.get!(Document, dependent.id).updated_at

      assert broadcast_updated_at == stored_updated_at,
             """
             the unblock broadcast shipped a timestamp the DB does not hold.
             broadcast: #{inspect(broadcast_updated_at)}
             stored:    #{inspect(stored_updated_at)}
             """

      refute broadcast_updated_at == pre_close_updated_at,
             "the broadcast is still carrying the PRE-close value — the reconstruction survived"
    end
  end

  describe "the fence is unchanged" do
    test "a lost CAS is still {:error, :stale_claim}", %{scope: scope} do
      doc_id = uniq("receipt-stale")
      task = mk_task!(doc_id, scope)

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w-receipt", scope)

      # An explicit, WRONG observed_rev: the CAS predicate `d.rev == ^observed_rev`
      # matches 0 rows, and the 0-row arm must still be :stale_claim (not a crash,
      # not a silent success now that the query carries a `select:`).
      assert {:error, :stale_claim} =
               Close.close(task.id, "w-receipt",
                 observed_epoch: claimed.content["claim"]["epoch"],
                 observed_rev: "deadbeefdeadbeefdeadbeefdeadbeef",
                 reason: "should not land"
               )

      assert Repo.get!(Document, task.id).content["lifecycle_status"] == "in_progress",
             "the refused close wrote nothing"
    end
  end
end
