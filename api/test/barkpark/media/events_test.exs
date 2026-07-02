defmodule Barkpark.Media.Delivery.EventsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Media.Delivery.Events
  alias Barkpark.Media.Storage.MediaFile

  # Events uses a 3-entry backoff table → 4 attempts total (initial + 3 retries).
  # Kept here so the retry-count assertions read against a named constant instead
  # of a bare 4. `[1, 1, 1]` below preserves this length while dropping the
  # wall-clock sleeps.
  @attempts_total 4

  setup do
    original = Application.get_env(:barkpark, :media_webhooks)
    original_delays = Application.fetch_env(:barkpark, :media_webhook_retry_delays_ms)

    # Keep the 3-entry length (→ 4 attempts) but drop the real 2.6s of sleeps so
    # the give-up-after-N assertions stay meaningful without burning wall-clock.
    Application.put_env(:barkpark, :media_webhook_retry_delays_ms, [1, 1, 1])

    on_exit(fn ->
      Application.put_env(:barkpark, :media_webhooks, original)

      case original_delays do
        {:ok, val} -> Application.put_env(:barkpark, :media_webhook_retry_delays_ms, val)
        :error -> Application.delete_env(:barkpark, :media_webhook_retry_delays_ms)
      end
    end)

    :ok
  end

  test "dispatch delivers signed payload to configured endpoint" do
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
    drain_tasks()
  end

  test "500 → 500 → 200 succeeds after 2 retries" do
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/hook", fn conn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      status = if n < 2, do: 500, else: 200
      Plug.Conn.resp(conn, status, "")
    end)

    put_endpoints([endpoint(bypass)])

    Events.dispatch("production", "media.processed", media_file(), nil)
    drain_tasks()

    assert Agent.get(counter, & &1) == 3
  end

  test "4xx is terminal — exactly one POST" do
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/hook", fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, 400, "")
    end)

    put_endpoints([endpoint(bypass)])

    Events.dispatch("production", "media.processed", media_file(), nil)
    drain_tasks()

    assert Agent.get(counter, & &1) == 1
  end

  test "always-500 gives up after @attempts_total POSTs with no trailing sleep" do
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/hook", fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, 500, "")
    end)

    put_endpoints([endpoint(bypass)])

    {elapsed_ms, log} =
      with_log(fn ->
        t0 = System.monotonic_time(:millisecond)
        Events.dispatch("production", "media.processed", media_file(), nil)
        drain_tasks()
        System.monotonic_time(:millisecond) - t0
      end)

    # No 5th (unbounded) attempt, and the final failed attempt logs a give-up.
    # The attempt-count assertion is the primary guard against the old off-by-one
    # (which slept an extra pointless final delay + returned :ok with NO give-up
    # log). With the `[1, 1, 1]` override the wall-clock bound is now a loose
    # sanity check rather than the 2.6s-vs-4.6s split it once was.
    assert Agent.get(counter, & &1) == @attempts_total
    assert log =~ "gave up after"
    assert elapsed_ms < 3_500
  end

  test "endpoint with empty url is skipped without crashing" do
    put_endpoints([%{url: "", secret: "s", events: ["media.processed"]}])

    assert :ok = Events.dispatch("production", "media.processed", media_file(), nil)
    drain_tasks()
  end

  test "dataset-mismatched endpoint receives zero POSTs" do
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # stub (not expect): zero calls is the passing condition.
    Bypass.stub(bypass, "POST", "/hook", fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, 200, "")
    end)

    put_endpoints([Map.put(endpoint(bypass), :dataset, "production")])

    Events.dispatch("staging", "media.processed", media_file(), nil)
    drain_tasks()

    assert Agent.get(counter, & &1) == 0
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

  # Deliveries now run under Barkpark.WebhookDeliverySupervisor (the async_stream
  # workers) wrapped by an outer Task on Barkpark.TaskSupervisor, so drain BOTH.
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
