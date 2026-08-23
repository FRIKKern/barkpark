defmodule BarkparkWeb.PulsePublicSurfaceTest do
  @moduledoc """
  Shared Storm t1–t3 acceptance — the pulse public surface end-to-end
  through the router (`:public_api` bucket): CORS on pulse routes only,
  unknown-channel 404, validated anonymous ingest with an atomic durable
  counter, per-IP rate caps, and the cursor feed.

  Uses the `test-storm` channel fixture from `config/test.exs` (rate_per_min
  600) for the ingest/feed/CORS paths. The per-IP burst-cap 429 test drives the
  SLOW-refill `abuse-rate` channel instead (rate_per_min 6 = 0.1 tok/sec):
  test-storm's 10 tok/sec refills a 4th token inside the ~100ms of real request
  latency and flaked an exact `== 3` on the merge train (felix wave-8).
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!

  alias Barkpark.Pulse

  # Mirror of the controller's hardcoded per-IP burst capacity.
  @burst 3

  @valid %{"hue" => 200, "x" => 0.5, "y" => 0.25, "mega" => false}

  defp post_event(conn, body, ip \\ {203, 0, 113, 7}) do
    conn
    |> Map.put(:remote_ip, ip)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/plugins/pulse/test-storm/events", Jason.encode!(body))
  end

  # Burst-cap probes drive the SLOW-refill `abuse-rate` channel (0.1 tok/sec),
  # which declares only `hue` — so a rapid same-IP volley is bounded to the
  # burst with no in-loop refill slop (latency-immune, unlike test-storm's
  # 10 tok/sec). Mirrors pulse_abuse_drill_test.exs.
  defp burst_conn(conn, ip) do
    conn
    |> Map.put(:remote_ip, ip)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/plugins/pulse/abuse-rate/events", Jason.encode!(%{"hue" => 200}))
  end

  defp burst_post(conn, ip), do: burst_conn(conn, ip).status

  describe "CORS (:public_api bucket)" do
    test "REAL browser preflight (origin + request-method headers) returns 204 + ACAO", %{
      conn: conn
    } do
      # access-control-request-method is what makes DatasetCors (endpoint
      # layer) classify this as a preflight — omitting it silently routes
      # around the plug and vacuously passes. Browsers always send it.
      conn =
        conn
        |> put_req_header("origin", "https://frikkern.github.io")
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "content-type")
        |> options("/v1/plugins/pulse/test-storm/events")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert ["GET, POST, OPTIONS"] = get_resp_header(conn, "access-control-allow-methods")
    end

    test "GET recent carries ACAO", %{conn: conn} do
      conn = get(conn, "/v1/plugins/pulse/test-storm/recent")
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    test "the core data API still serves NO CORS headers", %{conn: conn} do
      conn = get(conn, "/v1/data/query/production/post")
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  describe "channel gate" do
    test "unknown channel 404s on every verb", %{conn: conn} do
      for path <- ["events", "recent", "stats"] do
        c =
          if path == "events",
            do: post(conn, "/v1/plugins/pulse/nope/#{path}", %{}),
            else: get(conn, "/v1/plugins/pulse/nope/#{path}")

        assert c.status == 404, "#{path} should 404 for unknown channel"
      end
    end
  end

  describe "ingest + counter" do
    test "valid event: 200, row inserted, counter incremented", %{conn: conn} do
      before_total = Pulse.total("test-storm")
      conn = post_event(conn, @valid)

      assert %{"ok" => true, "id" => id, "total" => total} = json_response(conn, 200)
      assert is_integer(id)
      assert total == before_total + 1
      assert Pulse.total("test-storm") == total
    end

    test "unknown field rejected, counter unchanged", %{conn: conn} do
      before_total = Pulse.total("test-storm")
      conn = post_event(conn, Map.put(@valid, "evil", 1))
      assert %{"error" => %{"code" => "invalid_event"}} = json_response(conn, 400)
      assert Pulse.total("test-storm") == before_total
    end

    test "out-of-range and wrong-type fields rejected", %{conn: conn} do
      # fresh IP per request: the RateLimiter ETS table is process-global (not
      # sandbox-reset), and invalid payloads still bill the bucket by design
      for {bad, i} <-
            Enum.with_index([
              %{@valid | "hue" => 400},
              %{@valid | "hue" => "red"},
              %{@valid | "x" => 1.5},
              %{@valid | "mega" => "yes"},
              Map.delete(@valid, "hue")
            ]) do
        conn2 = post_event(conn, bad, {10, 66, 7, i})
        assert conn2.status == 400, "expected 400 for #{inspect(bad)}"
      end
    end

    test "counter increments are atomic under concurrency" do
      before_total = Pulse.total("test-storm")

      results =
        1..20
        |> Task.async_stream(
          fn _ -> Pulse.record_event("test-storm", @valid) end,
          max_concurrency: 10
        )
        |> Enum.map(fn {:ok, {:ok, r}} -> r.total end)

      assert Pulse.total("test-storm") == before_total + 20
      # every transaction observed a distinct total — no lost increments
      assert length(Enum.uniq(results)) == 20
    end

    test "per-IP burst cap yields 429 with Retry-After", %{conn: conn} do
      # Drives the SLOW-refill abuse-rate channel from ONE IP: the burst (3) is
      # exhausted and the excess is 429. Asserted as a latency-immune BOUND
      # (`<= @burst` + `429 in statuses`), mirroring pulse_abuse_drill_test.exs
      # — NOT an exact `== 3` on the fast-refill test-storm, whose 10 tok/sec
      # over-refilled a 4th token inside real request latency and flaked.
      ip = {198, 51, 100, 42}
      statuses = for _ <- 1..4, do: burst_post(conn, ip)

      two_hundreds = Enum.count(statuses, &(&1 == 200))
      assert two_hundreds >= 1
      assert two_hundreds <= @burst
      assert 429 in statuses

      limited = burst_conn(conn, ip)
      assert limited.status == 429
      assert [retry] = get_resp_header(limited, "retry-after")
      assert String.to_integer(retry) >= 1
    end
  end

  describe "feed" do
    test "cursor returns only newer events with correct next", %{conn: conn} do
      {:ok, %{id: id1}} = Pulse.record_event("test-storm", @valid)
      {:ok, %{id: id2}} = Pulse.record_event("test-storm", %{@valid | "hue" => 10})

      body = json_response(get(conn, "/v1/plugins/pulse/test-storm/recent?since=#{id1}"), 200)
      assert Enum.map(body["events"], & &1["id"]) == [id2]
      assert body["next"] == id2
      assert body["total"] == Pulse.total("test-storm")

      # empty page: cursor sticks
      body2 = json_response(get(conn, "/v1/plugins/pulse/test-storm/recent?since=#{id2}"), 200)
      assert body2["events"] == []
      assert body2["next"] == id2
    end

    test "batch cap enforced", %{conn: conn} do
      for i <- 1..5, do: Pulse.record_event("test-storm", %{@valid | "hue" => i})
      body = json_response(get(conn, "/v1/plugins/pulse/test-storm/recent?since=0&limit=2"), 200)
      assert length(body["events"]) == 2
    end

    test "stats returns total/today/last_hour", %{conn: conn} do
      Pulse.record_event("test-storm", @valid)
      body = json_response(get(conn, "/v1/plugins/pulse/test-storm/stats"), 200)
      assert body["total"] >= 1
      assert body["today"] >= 1
      assert body["last_hour"] >= 1
    end
  end

  describe "sweep" do
    test "old events swept, counter untouched" do
      {:ok, _} = Pulse.record_event("test-storm", @valid)
      total = Pulse.total("test-storm")

      # age one row past the 24h TTL — in Elixir-UTC, NOT SQL now(): the
      # session's TimeZone is server-local, so `now() - interval` writes local
      # wall time into the naive-UTC column and under-ages the row
      import Ecto.Query
      old = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)

      {aged, _} =
        Barkpark.Repo.update_all(
          from(e in Pulse.Event, where: e.channel == "test-storm"),
          set: [inserted_at: old]
        )

      assert aged >= 1
      swept = Pulse.sweep()
      assert swept["test-storm"] >= 1
      assert Pulse.total("test-storm") == total
      assert Pulse.recent("test-storm", 0).events == []
    end
  end
end
