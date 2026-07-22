defmodule Barkpark.Webhooks.PayloadRebuildAuditTest do
  @moduledoc """
  The audit-kind crash-recovery rebuild (herd layer, charter D62h/D63h): an
  audit delivery row carries a real `endpoint_id` but a NULL `event_id`, so it
  MUST resume from its `payload_snapshot` — never fall through to the catch-all
  clause, whose `Repo.get(MutationEvent, nil)` RAISES `ArgumentError` (ecto
  queryable, before any DB round-trip). `StuckDeliverySweeper.sweep/1`'s reduce
  is unguarded, so without the audit clause ONE audit row aborts recovery for
  every other stuck delivery in the cron batch — both regressions are pinned
  here (reverting the audit clause in `PayloadRebuild` reintroduces the raise
  and fails this file).
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.{Delivery, PayloadRebuild, StuckDeliverySweeper}

  # Minimal Agent-backed HTTP adapter: the test pushes a list of scripted
  # responses, each `post/3` pops one and records the call. Mirrors the fake in
  # stuck_delivery_sweeper_test so the sweeper drives real `Dispatcher` paths.
  defmodule FakeHTTP do
    @name __MODULE__

    def start(responses) do
      case Process.whereis(@name) do
        nil ->
          {:ok, _} = Agent.start_link(fn -> %{responses: responses, calls: []} end, name: @name)

        _ ->
          Agent.update(@name, fn _ -> %{responses: responses, calls: []} end)
      end

      :ok
    end

    def calls, do: Agent.get(@name, & &1.calls) |> Enum.reverse()

    def post(url, body, headers) do
      Agent.get_and_update(@name, fn %{responses: [resp | rest], calls: calls} = state ->
        {resp, %{state | responses: rest, calls: [{url, body, headers} | calls]}}
      end)
    end
  end

  setup do
    prev_adapter = Application.get_env(:barkpark, :webhook_http_adapter)
    prev_delays = Application.get_env(:barkpark, :webhook_retry_delays_ms)
    prev_max = Application.get_env(:barkpark, :webhook_max_attempts)

    Application.put_env(:barkpark, :webhook_http_adapter, FakeHTTP)
    Application.put_env(:barkpark, :webhook_retry_delays_ms, [1, 1, 1])
    Application.put_env(:barkpark, :webhook_max_attempts, 3)

    on_exit(fn ->
      set_or_delete(:webhook_http_adapter, prev_adapter)
      set_or_delete(:webhook_retry_delays_ms, prev_delays)
      set_or_delete(:webhook_max_attempts, prev_max)
    end)

    Content.upsert_schema(
      %{"name" => "widget", "title" => "W", "visibility" => "public", "fields" => []},
      "test"
    )

    # Seed hook's `events` filter deliberately does NOT match "create", so the
    # create-broadcast fired inside `new_event_id/0` does not spawn a competing
    # delivery Task against the same event (setup-race guard, same as
    # stuck_delivery_sweeper_test). These tests drive deliveries directly.
    {:ok, wh} =
      Webhooks.create_webhook(%{
        "name" => "ep",
        "url" => "http://example.test/hook",
        "dataset" => "test",
        "secret" => "sek",
        "events" => ["publish"]
      })

    %{webhook: wh}
  end

  defp set_or_delete(k, nil), do: Application.delete_env(:barkpark, k)
  defp set_or_delete(k, v), do: Application.put_env(:barkpark, k, v)

  # Create a real mutation_events row (via a document create) and return its id —
  # the document-kind delivery in the batch test rebuilds from it.
  defp new_event_id do
    id = "e-" <> (Ecto.UUID.generate() |> binary_part(0, 8))
    {:ok, doc} = Content.create_document("widget", %{"_id" => id, "title" => "t"}, "test")

    [ev | _] =
      Repo.all(
        from(e in Barkpark.Content.MutationEvent,
          where: e.doc_id == ^doc.doc_id,
          order_by: [desc: e.id]
        )
      )

    ev.id
  end

  # Backdate a delivery row's updated_at by `age_seconds` — simulating a row
  # claimed that long ago (a crashed dispatcher leaves it `pending`).
  defp backdate(delivery_id, age_seconds) do
    ts = DateTime.utc_now() |> DateTime.add(-age_seconds, :second)

    {1, _} =
      from(x in Delivery, where: x.id == ^delivery_id)
      |> Repo.update_all(set: [updated_at: ts])

    Repo.get(Delivery, delivery_id)
  end

  describe "PayloadRebuild.rebuild/1 — audit resumes from raw snapshot, never Repo.get(MutationEvent, nil)" do
    test "a retried audit row rebuilds {webhook, body} by re-encoding the raw snapshot map",
         %{webhook: wh} do
      snapshot = %{"action" => "auth.login", "actor" => "u-1", "workspace_id" => "ws-1"}
      {:ok, delivery} = Webhooks.create_audit_delivery(wh.id, snapshot)
      assert delivery.event_id == nil

      # MUTATION PROOF: without the audit clause this row falls to the
      # catch-all, whose Repo.get(MutationEvent, nil) raises ArgumentError on
      # the NULL event_id — the assertion below can only pass via the clause.
      assert {:ok, rebuilt_wh, body} = PayloadRebuild.rebuild(delivery)
      assert rebuilt_wh.id == wh.id
      # Audit snapshots are the RAW decoded payload map deliver_audit stored —
      # NOT chat_blocked's %{"body" => body} wrapper — so the rebuilt body is
      # the whole map re-encoded.
      assert Jason.decode!(body) == snapshot
    end

    test ":gone when the target webhook was deleted", %{webhook: wh} do
      {:ok, delivery} = Webhooks.create_audit_delivery(wh.id, %{"action" => "auth.login"})

      Repo.delete!(wh)

      assert PayloadRebuild.rebuild(delivery) == :gone
    end

    test ":gone when the snapshot is not a map (fail-closed)", %{webhook: wh} do
      {:ok, delivery} = Webhooks.create_audit_delivery(wh.id, %{"action" => "auth.login"})

      {1, _} =
        from(x in Delivery, where: x.id == ^delivery.id)
        |> Repo.update_all(set: [payload_snapshot: nil])

      assert PayloadRebuild.rebuild(Repo.get(Delivery, delivery.id)) == :gone
    end
  end

  describe "PayloadRebuild.rebuild/1 — catch-all guarded against a NULL event_id (poison class)" do
    test "a document-kind row with NULL event_id returns :gone, never Repo.get(MutationEvent, nil)",
         %{webhook: wh} do
      # Pre-fix this fell to the catch-all, whose Repo.get(MutationEvent, nil)
      # raised ArgumentError ("cannot perform Ecto.Repo.get/2 because the given
      # value is nil"). The `is_integer(event_id)` guard + terminal fallback now
      # return :gone loudly instead of crashing the recovery drivers.
      poison = %Delivery{id: 424_242, endpoint_id: wh.id, event_id: nil, source_kind: "document"}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert PayloadRebuild.rebuild(poison) == :gone
        end)

      assert log =~ "unrecoverable"
      assert log =~ ~s(source_kind="document")
      assert log =~ "event_id=nil"
    end

    test "an unknown/future source_kind with NULL event_id also returns :gone (not a raise)",
         %{webhook: wh} do
      # The catch-all is the fallback for EVERY untyped kind; a future kind that
      # forgot to add a clause must degrade to :gone, never crash the batch.
      poison = %Delivery{id: 515_151, endpoint_id: wh.id, event_id: nil, source_kind: "future_x"}

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert PayloadRebuild.rebuild(poison) == :gone
             end) =~ "unrecoverable"
    end
  end

  describe "StuckDeliverySweeper.sweep/1 — an audit row no longer aborts the batch" do
    test "a batch with one audit row plus a document row completes without raising; both reach terminal status",
         %{webhook: wh} do
      :ok = FakeHTTP.start([{:ok, 200}, {:ok, 200}])

      # One stuck document row (rebuilds from mutation_events)…
      eid = new_event_id()
      {:ok, doc_delivery} = Webhooks.claim_delivery(wh.id, eid)
      backdate(doc_delivery.id, 600)

      # …and one stuck audit row (event_id NULL — the pre-fix batch-killer).
      {:ok, audit_delivery} = Webhooks.create_audit_delivery(wh.id, %{"action" => "auth.login"})
      backdate(audit_delivery.id, 600)

      # Pre-fix: the audit row's rebuild raised ArgumentError inside the
      # unguarded Enum.reduce, aborting recovery for the WHOLE batch. Now both
      # rows sweep to a terminal status in one pass.
      assert %{swept: 2, skipped: 0} = StuckDeliverySweeper.sweep(300)

      assert length(FakeHTTP.calls()) == 2
      assert Repo.get(Delivery, audit_delivery.id).status == "ok"
      assert Repo.get(Delivery, doc_delivery.id).status == "ok"
    end
  end
end
