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
