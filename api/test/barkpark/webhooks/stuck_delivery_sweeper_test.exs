defmodule Barkpark.Webhooks.StuckDeliverySweeperTest do
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.{Delivery, StuckDeliverySweeper}

  # Minimal Agent-backed HTTP adapter: the test pushes a list of scripted
  # responses, each `post/3` pops one and records the call. Mirrors the fake in
  # dispatcher_test so the sweeper drives real `Dispatcher.attempt/5` paths.
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
    # dispatcher_test). The sweeper tests drive deliveries directly.
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
  # the sweeper rebuilds the payload from it, and the delivery FK requires it.
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

  # Struct-insert a DOCUMENT-kind row with a NULL `event_id`. The changeset would
  # REJECT this (document requires event_id), so we bypass it via a direct struct
  # insert to simulate the crash-orphan poison row: the catch-all rebuild's
  # `Repo.get(MutationEvent, nil)` raises ArgumentError. Backdated past the cutoff.
  defp seed_poison_document_delivery(wh_id, age_seconds) do
    ts = DateTime.utc_now() |> DateTime.add(-age_seconds, :second)

    Repo.insert!(%Delivery{
      endpoint_id: wh_id,
      event_id: nil,
      source_kind: "document",
      status: "pending",
      inserted_at: ts,
      updated_at: ts
    })
  end

  # Struct-insert an AUDIT-kind row with a NULL `endpoint_id`. The audit rebuild
  # clause runs `Repo.get(Webhook, endpoint_id)`, which RAISES ArgumentError on a
  # nil id (before the `with/else` can catch it) — a DIFFERENT poison class than
  # the nil-`event_id` one the PayloadRebuild `is_integer` guard turns into
  # `:gone`. It reaches the sweeper still RAISING, so it is what the per-row
  # `try/rescue` net must isolate (the event_id guard never sees this clause).
  # Backdated past the cutoff.
  defp seed_poison_audit_delivery(age_seconds) do
    ts = DateTime.utc_now() |> DateTime.add(-age_seconds, :second)

    Repo.insert!(%Delivery{
      endpoint_id: nil,
      event_id: nil,
      source_kind: "audit",
      payload_snapshot: %{"body" => "{}"},
      status: "pending",
      inserted_at: ts,
      updated_at: ts
    })
  end

  # Insert a delivery row for (webhook, event) in the given status, with its
  # updated_at backdated by `age_seconds` — simulating a row claimed that long
  # ago (a crashed dispatcher leaves it `pending`).
  defp seed_delivery(wh_id, event_id, status, age_seconds) do
    {:ok, d} = Webhooks.claim_delivery(wh_id, event_id)
    ts = DateTime.utc_now() |> DateTime.add(-age_seconds, :second)

    {1, _} =
      from(x in Delivery, where: x.id == ^d.id)
      |> Repo.update_all(set: [status: status, updated_at: ts])

    Repo.get(Delivery, d.id)
  end

  test "a pending row older than the threshold is re-dispatched to a terminal status",
       %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 200}])
    eid = new_event_id()
    _stuck = seed_delivery(wh.id, eid, "pending", 600)

    assert %{swept: 1, skipped: 0} = StuckDeliverySweeper.sweep(300)

    # Exactly one HTTP attempt, and the row reached the terminal `ok` state.
    assert length(FakeHTTP.calls()) == 1
    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "ok"
  end

  test "a recent pending row is left alone (not yet past the threshold)", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 200}])
    eid = new_event_id()
    _fresh = seed_delivery(wh.id, eid, "pending", 5)

    assert %{swept: 0, skipped: 0} = StuckDeliverySweeper.sweep(300)

    # No delivery attempted; still pending, awaiting its owning dispatcher.
    assert FakeHTTP.calls() == []
    assert Webhooks.get_delivery(wh.id, eid).status == "pending"
  end

  test "an already-ok row is never touched", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 200}])
    eid = new_event_id()
    _ok = seed_delivery(wh.id, eid, "ok", 600)

    assert %{swept: 0, skipped: 0} = StuckDeliverySweeper.sweep(300)

    # No re-delivery — no double-delivery of a row that already succeeded.
    assert FakeHTTP.calls() == []
    assert Webhooks.get_delivery(wh.id, eid).status == "ok"
  end

  test "a failed_giveup row is never resurrected", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 200}])
    eid = new_event_id()
    _dead = seed_delivery(wh.id, eid, "failed_giveup", 600)

    assert %{swept: 0, skipped: 0} = StuckDeliverySweeper.sweep(300)

    assert FakeHTTP.calls() == []
    assert Webhooks.get_delivery(wh.id, eid).status == "failed_giveup"
  end

  test "a re-dispatch that exhausts retries lands on failed_giveup and is not swept again",
       %{webhook: wh} do
    # Three 5xx → exhausts and gives up. The recovered delivery now retries via
    # SCHEDULED RetryWorker hops (no in-sweep sleep), so drain the queue to run
    # the remaining attempts to the terminal state.
    :ok = FakeHTTP.start([{:ok, 500}, {:ok, 500}, {:ok, 500}])
    eid = new_event_id()
    _stuck = seed_delivery(wh.id, eid, "pending", 600)

    assert %{swept: 1, skipped: 0} = StuckDeliverySweeper.sweep(300)
    Oban.drain_queue(queue: :default, with_scheduled: true, with_recursion: true)
    assert Webhooks.get_delivery(wh.id, eid).status == "failed_giveup"

    # A second sweep finds no pending candidate — the terminal row stays put.
    :ok = FakeHTTP.start([{:ok, 200}])
    assert %{swept: 0, skipped: 0} = StuckDeliverySweeper.sweep(300)
    assert FakeHTTP.calls() == []
    assert Webhooks.get_delivery(wh.id, eid).status == "failed_giveup"
  end

  # Insert a durable MEDIA row (source_kind "media", snapshot-backed, no
  # endpoint/event FKs) and backdate its updated_at to simulate a crash-orphan.
  defp seed_media_delivery(snapshot, status, age_seconds) do
    {:ok, d} = Webhooks.create_media_delivery(snapshot)
    ts = DateTime.utc_now() |> DateTime.add(-age_seconds, :second)

    {1, _} =
      from(x in Delivery, where: x.id == ^d.id)
      |> Repo.update_all(set: [status: status, updated_at: ts])

    Repo.get(Delivery, d.id)
  end

  test "a stuck MEDIA row is recovered FROM its snapshot (branches on source_kind)" do
    :ok = FakeHTTP.start([{:ok, 200}])
    snap = %{"url" => "http://example.test/cdn", "secret" => "sek", "body" => ~s({"e":"m"})}
    stuck = seed_media_delivery(snap, "pending", 600)

    assert %{swept: 1, skipped: 0} = StuckDeliverySweeper.sweep(300)

    # One HTTP attempt (rebuilt from the snapshot, not a mutation_events row) and
    # the SAME row terminalised to ok — no endpoint/event FK touched.
    assert length(FakeHTTP.calls()) == 1
    d = Repo.get(Delivery, stuck.id)
    assert d.status == "ok"
    assert d.source_kind == "media"
    assert d.endpoint_id == nil and d.event_id == nil
  end

  test "a MEDIA row with an unusable snapshot is skipped (:gone), not endlessly retried" do
    :ok = FakeHTTP.start([{:ok, 200}])
    # Corrupt/incomplete snapshot: PayloadRebuild returns :gone → skipped.
    stuck = seed_media_delivery(%{"url" => "http://example.test/cdn"}, "pending", 600)

    assert %{swept: 0, skipped: 1} = StuckDeliverySweeper.sweep(300)

    assert FakeHTTP.calls() == []
    # The claim-CAS still bumped updated_at, so the next sweep won't re-select it
    # until it ages past the threshold again (no tight loop).
    assert Repo.get(Delivery, stuck.id).status == "pending"
  end

  test "a NULL-event_id document poison row is skipped, never aborting the batch",
       %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 200}])

    # A crash-orphan poison row: document-kind but `event_id` NULL. Pre-fix the
    # catch-all's `Repo.get(MutationEvent, nil)` raised ArgumentError inside the
    # unguarded reduce, aborting recovery for the WHOLE batch — the recoverable
    # row below then starved forever, every cron pass.
    poison = seed_poison_document_delivery(wh.id, 600)

    # A genuinely recoverable document row in the SAME batch.
    eid = new_event_id()
    _good = seed_delivery(wh.id, eid, "pending", 600)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{swept: 1, skipped: 1} = StuckDeliverySweeper.sweep(300)
      end)

    # The recoverable row delivered to a terminal status — it no longer starves
    # behind the poison row.
    assert length(FakeHTTP.calls()) == 1
    assert Webhooks.get_delivery(wh.id, eid).status == "ok"

    # The poison row was claimed-and-skipped (:gone): still pending, no HTTP, and
    # LOUDLY logged with its id / source_kind / event_id.
    assert Repo.get(Delivery, poison.id).status == "pending"
    assert log =~ "unrecoverable"
    assert log =~ ~s(source_kind="document")
    assert log =~ "event_id=nil"
  end

  test "a rebuild that RAISES (audit row, NULL endpoint_id) is caught by the per-row rescue, batch continues",
       %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 200}])

    # This poison row's rebuild RAISES (audit clause's `Repo.get(Webhook, nil)`),
    # NOT the nil-`event_id` class the PayloadRebuild guard degrades to `:gone`.
    # So it exercises the sweeper's OWN `try/rescue` net — remove that net and the
    # raise propagates out of the reduce, aborting the whole batch (the recoverable
    # row below then starves). This is the test the nil-event_id case cannot be:
    # there the rebuild returns `:gone` and the rescue never fires.
    poison = seed_poison_audit_delivery(600)

    # A genuinely recoverable document row in the SAME batch.
    eid = new_event_id()
    _good = seed_delivery(wh.id, eid, "pending", 600)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{swept: 1, skipped: 1} = StuckDeliverySweeper.sweep(300)
      end)

    # The recoverable row delivered — it did not starve behind the raising row.
    assert length(FakeHTTP.calls()) == 1
    assert Webhooks.get_delivery(wh.id, eid).status == "ok"

    # The raising row was rescued: still pending, and logged by the SWEEPER's
    # rescue clause (distinct from PayloadRebuild's `:gone` log), naming the error.
    assert Repo.get(Delivery, poison.id).status == "pending"
    assert log =~ "StuckDeliverySweeper skipped delivery ##{poison.id}"
    assert log =~ "ArgumentError"
  end

  test "re-dispatch reuses the same row — no second delivery row, UNIQUE intact",
       %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 200}])
    eid = new_event_id()
    original = seed_delivery(wh.id, eid, "pending", 600)

    assert %{swept: 1} = StuckDeliverySweeper.sweep(300)

    rows =
      Repo.all(from(d in Delivery, where: d.endpoint_id == ^wh.id and d.event_id == ^eid))

    # Still exactly one (endpoint, event) row — the sweeper updated it in place.
    assert length(rows) == 1
    assert hd(rows).id == original.id
  end
end
