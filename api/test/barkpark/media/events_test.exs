defmodule Barkpark.Media.Delivery.EventsTest do
  # Media deliveries are now DURABLE-ROW backed and their retries are SCHEDULED
  # (Oban `RetryWorker`), not slept in-task — so this needs the DB sandbox + Oban
  # draining, exactly like the document `DispatcherTest`. `async: false` puts the
  # sandbox in SHARED mode so the fan-out tasks (and drained jobs) see the DB.
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Ecto.Query

  alias Barkpark.Media.Delivery.Events
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Webhooks.Delivery

  # Media now inherits the DOCUMENT retry policy (`:webhook_max_attempts`): an
  # initial attempt + (max_attempts - 1) scheduled retries.
  @max_attempts 3

  # A retryable failure schedules a `RetryWorker` job instead of sleeping in-slot.
  # Draining the `:default` queue (scheduled + recursively) runs the whole retry
  # chain to its terminal state — the deterministic stand-in for backoff elapsing.
  defp drain_retries do
    Oban.drain_queue(queue: :default, with_scheduled: true, with_recursion: true)
  end

  setup do
    prev_endpoints = Application.get_env(:barkpark, :media_webhooks)
    prev_delays = Application.get_env(:barkpark, :webhook_retry_delays_ms)
    prev_max = Application.get_env(:barkpark, :webhook_max_attempts)

    # Tiny delays so scheduled retries drain instantly; bounded attempt count so
    # the give-up-after-N assertions stay meaningful without burning wall-clock.
    Application.put_env(:barkpark, :webhook_retry_delays_ms, [5, 10, 20])
    Application.put_env(:barkpark, :webhook_max_attempts, @max_attempts)

    on_exit(fn ->
      set_or_delete(:media_webhooks, prev_endpoints)
      set_or_delete(:webhook_retry_delays_ms, prev_delays)
      set_or_delete(:webhook_max_attempts, prev_max)
    end)

    :ok
  end

  test "dispatch delivers signed payload to configured endpoint (durable row → ok)" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
      # Combined Stripe-style form (`t=<unix>,v1=<hex>`) — proves the SDK's
      # parseSignatureHeader accepts it (it 401s `bad_signature` on any header
      # lacking the `t=` part before HMAC).
      [sig] = Plug.Conn.get_req_header(conn, "x-barkpark-signature")
      assert sig =~ ~r/^t=\d+,v1=[0-9a-f]+$/
      assert Plug.Conn.get_req_header(conn, "x-barkpark-timestamp") != []
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["event"] == "media.processed"
      # Both the workspace/project-scoped tag and the legacy dataset-only tag
      # are present (additive tenancy revalidation).
      assert "bp:ws:default:p:default:ds:production:media" in payload["sync_tags"]
      assert "bp:ds:production:media" in payload["sync_tags"]
      Plug.Conn.resp(conn, 200, "")
    end)

    put_endpoints([endpoint(bypass)])

    Events.dispatch("production", "media.processed", media_file(), nil)
    settle()

    # A durable media row was persisted and terminalised to "ok".
    row = media_delivery!()
    assert row.source_kind == "media"
    assert row.status == "ok"
    assert row.endpoint_id == nil and row.event_id == nil
    assert row.payload_snapshot["url"] =~ "/hook"
  end

  test "500 → 500 → 200 succeeds after 2 SCHEDULED retries" do
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/hook", fn conn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      status = if n < 2, do: 500, else: 200
      Plug.Conn.resp(conn, status, "")
    end)

    put_endpoints([endpoint(bypass)])

    Events.dispatch("production", "media.processed", media_file(), nil)
    settle()

    assert Agent.get(counter, & &1) == 3
    assert media_delivery!().status == "ok"
  end

  test "4xx is terminal — exactly one POST, row failed_giveup" do
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/hook", fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, 400, "")
    end)

    put_endpoints([endpoint(bypass)])

    Events.dispatch("production", "media.processed", media_file(), nil)
    settle()

    assert Agent.get(counter, & &1) == 1
    assert media_delivery!().status == "failed_giveup"
  end

  test "always-500 gives up after @max_attempts POSTs (row failed_giveup)" do
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/hook", fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, 500, "")
    end)

    put_endpoints([endpoint(bypass)])

    Events.dispatch("production", "media.processed", media_file(), nil)
    settle()

    # Exactly @max_attempts POSTs (initial + retries), then a durable terminal
    # give-up — the retries were SCHEDULED off-slot, never slept in-task.
    assert Agent.get(counter, & &1) == @max_attempts
    assert media_delivery!().status == "failed_giveup"
  end

  test "429 is retried (not dropped) and gives up after @max_attempts POSTs" do
    # Whole-class mirror of the document-webhook fix: a transient 429 must retry
    # like a 5xx instead of being treated as a terminal 4xx and dropped.
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/hook", fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, 429, "")
    end)

    put_endpoints([endpoint(bypass)])

    Events.dispatch("production", "media.processed", media_file(), nil)
    settle()

    assert Agent.get(counter, & &1) == @max_attempts
    assert media_delivery!().status == "failed_giveup"
  end

  test "429 with Retry-After header is honored, then recovers" do
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/hook", fn conn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

      if n == 0 do
        # retry-after: 0 exercises the honor path without slowing the test.
        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.resp(429, "")
      else
        Plug.Conn.resp(conn, 200, "")
      end
    end)

    put_endpoints([endpoint(bypass)])

    Events.dispatch("production", "media.processed", media_file(), nil)
    settle()

    assert Agent.get(counter, & &1) == 2
    assert media_delivery!().status == "ok"
  end

  test "endpoint with empty url is skipped without crashing or persisting a row" do
    put_endpoints([%{url: "", secret: "s", events: ["media.processed"]}])

    assert :ok = Events.dispatch("production", "media.processed", media_file(), nil)
    settle()

    assert Repo.aggregate(from(d in Delivery), :count) == 0
  end

  test "dataset-mismatched endpoint receives zero POSTs and persists no row" do
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # stub (not expect): zero calls is the passing condition.
    Bypass.stub(bypass, "POST", "/hook", fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, 200, "")
    end)

    put_endpoints([Map.put(endpoint(bypass), :dataset, "production")])

    Events.dispatch("staging", "media.processed", media_file(), nil)
    settle()

    assert Agent.get(counter, & &1) == 0
    assert Repo.aggregate(from(d in Delivery), :count) == 0
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp settle do
    drain_tasks()
    drain_retries()
  end

  defp media_delivery! do
    Repo.one!(from d in Delivery, where: d.source_kind == "media")
  end

  defp endpoint(bypass) do
    %{
      url: "http://127.0.0.1:#{bypass.port}/hook",
      secret: "hook-secret",
      events: ["media.processed"]
    }
  end

  defp put_endpoints(endpoints) do
    Application.put_env(:barkpark, :media_webhooks, endpoints: endpoints)
  end

  defp set_or_delete(key, nil), do: Application.delete_env(:barkpark, key)
  defp set_or_delete(key, val), do: Application.put_env(:barkpark, key, val)

  defp media_file do
    %MediaFile{
      id: Ecto.UUID.generate(),
      dataset: "production",
      path: "2026/05/a.png",
      mime_type: "image/png",
      filename: "a.png",
      original_name: "a.png"
    }
  end

  # First attempts run under Barkpark.WebhookDeliverySupervisor (the async_stream
  # workers) wrapped by an outer Task on Barkpark.TaskSupervisor, so drain BOTH —
  # then `drain_retries/0` runs the SCHEDULED retry chain.
  defp drain_tasks do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn ->
      Process.sleep(20)

      children =
        Task.Supervisor.children(Barkpark.TaskSupervisor) ++
          Task.Supervisor.children(Barkpark.WebhookDeliverySupervisor)

      case children do
        [] -> :done
        _ -> :wait
      end
    end)
    |> Enum.find_value(deadline, fn
      :done -> :ok
      :wait -> if System.monotonic_time(:millisecond) >= deadline, do: :timeout, else: nil
    end)
  end
end
