defmodule Barkpark.Webhooks.DispatcherTest do
  use Barkpark.DataCase, async: false
  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Dispatcher

  # Fake HTTP adapter backed by an Agent. Test pushes a list of scripted
  # responses; each call pops one. Also records attempts (url/body/headers)
  # so we can assert on retries and header shape.
  defmodule FakeHTTP do
    @name __MODULE__

    def start(responses) do
      case Process.whereis(@name) do
        nil ->
          {:ok, _} = Agent.start_link(fn -> %{responses: responses, calls: []} end, name: @name)

        _pid ->
          Agent.update(@name, fn _ -> %{responses: responses, calls: []} end)
      end

      :ok
    end

    def calls, do: Agent.get(@name, & &1.calls) |> Enum.reverse()

    def post(url, body, headers) do
      Agent.get_and_update(@name, fn %{responses: [resp | rest], calls: calls} = state ->
        new_state = %{state | responses: rest, calls: [{url, body, headers} | calls]}
        {resp, new_state}
      end)
    end
  end

  setup do
    prev_adapter = Application.get_env(:barkpark, :webhook_http_adapter)
    prev_delays = Application.get_env(:barkpark, :webhook_retry_delays_ms)
    prev_max = Application.get_env(:barkpark, :webhook_max_attempts)

    Application.put_env(:barkpark, :webhook_http_adapter, FakeHTTP)
    Application.put_env(:barkpark, :webhook_retry_delays_ms, [5, 10, 20])
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

    {:ok, wh} =
      Webhooks.create_webhook(%{
        "name" => "ep",
        "url" => "http://example.test/hook",
        "dataset" => "test",
        "secret" => "sek"
      })

    %{webhook: wh}
  end

  defp set_or_delete(k, nil), do: Application.delete_env(:barkpark, k)
  defp set_or_delete(k, v), do: Application.put_env(:barkpark, k, v)

  defp new_event_id do
    id = "e-" <> (Ecto.UUID.generate() |> binary_part(0, 8))
    {:ok, doc} = Content.create_document("widget", %{"_id" => id, "title" => "t"}, "test")

    [ev | _] =
      Barkpark.Repo.all(
        from(e in Barkpark.Content.MutationEvent,
          where: e.doc_id == ^doc.doc_id,
          order_by: [desc: e.id]
        )
      )

    ev.id
  end

  test "build_payload creates correct structure" do
    payload = Dispatcher.build_payload("create", "post", "p1", %{"_id" => "p1"}, "production")

    assert payload.event == "create"
    assert payload.type == "post"
    assert payload.doc_id == "p1"
    assert payload.dataset == "production"
    assert payload.document == %{"_id" => "p1"}
    assert is_binary(payload.timestamp)
  end

  test "200 on first attempt succeeds without retry", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 200}])
    eid = new_event_id()

    assert {:ok, 200, 1} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 1

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "ok"
    assert d.attempts == 1
  end

  test "500 → 500 → 200 yields 2 retries then success", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 500}, {:ok, 500}, {:ok, 200}])
    eid = new_event_id()

    assert {:ok, 200, 3} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 3

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "ok"
    assert d.attempts == 3
  end

  test "400 is terminal — no retry", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 400}, {:ok, 200}])
    eid = new_event_id()

    assert {:error, :giveup_4xx, 1} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 1

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "failed_giveup"
    assert d.last_status_code == 400
  end

  test "3 consecutive 500s exhaust retries and give up", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 500}, {:ok, 500}, {:ok, 500}])
    eid = new_event_id()

    assert {:error, :exhausted, 3} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 3

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "failed_giveup"
  end

  test "transport error triggers retry", %{webhook: wh} do
    :ok = FakeHTTP.start([{:error, :timeout}, {:ok, 200}])
    eid = new_event_id()

    assert {:ok, 200, 2} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 2
  end

  test "duplicate (endpoint, event) is skipped", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 200}])
    eid = new_event_id()

    assert {:ok, 200, 1} = Dispatcher.deliver(wh, "{}", eid)

    # Second attempt — no HTTP call should occur
    :ok = FakeHTTP.start([{:ok, 500}])
    assert {:skipped, :already_delivered} = Dispatcher.deliver(wh, "{}", eid)
    assert FakeHTTP.calls() == []
  end

  test "every attempt carries signature + timestamp + event-id headers", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 200}])
    eid = new_event_id()

    assert {:ok, 200, 1} = Dispatcher.deliver(wh, ~s({"a":1}), eid)
    [{_url, body, headers}] = FakeHTTP.calls()

    hmap = Map.new(headers)
    assert body == ~s({"a":1})
    assert hmap["content-type"] == "application/json"
    assert "v1=" <> _ = hmap["x-barkpark-signature"]
    assert is_binary(hmap["x-barkpark-timestamp"])
    assert hmap["x-barkpark-event-id"] == Integer.to_string(eid)

    # Signature verifies against the webhook's secret + the sent timestamp
    ts = String.to_integer(hmap["x-barkpark-timestamp"])
    assert Dispatcher.sign_payload(body, ts, "sek") == hmap["x-barkpark-signature"]
  end
end
