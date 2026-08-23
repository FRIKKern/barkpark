defmodule BarkparkWeb.PulseAbuseDrillTest do
  @moduledoc """
  Shared Storm t7 — the ABUSE DRILL. The pulse surface is anonymous and
  CORS-open by design: safety is CAPS, not identity. This suite hammers each
  cap the way a hostile client would and proves it HOLDS — the volley is
  bounded, the excess is a clean 429/400 (never a 5xx storm), the durable
  counter never over-counts, and the feed stays readable throughout.

  PROTECTIVE, not vacuous: every assertion is wired so that NEUTERING the cap
  it guards flips the test RED. Concretely (demonstrated at review time):

    * delete `check_ip_bucket/3` from the controller → the rate volley all
      succeeds → `two_hundreds <= @burst` fails.
    * delete `check_daily_cap/2` → the over-cap strike lands → the 429 +
      frozen-counter assertions fail.
    * short-circuit `within_byte_cap/2` to `:ok` → the oversize payload is
      accepted → the 400 + unchanged-counter assertions fail.

  Uses the tight-cap `abuse-*` channels from `config/test.exs`. `async: false`
  because the `RateLimiter` ETS table is process-global (not sandbox-reset);
  each drill picks unique client IPs so volleys never cross-contaminate.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!

  alias Barkpark.Pulse

  # Mirror of the controller's hardcoded burst capacity.
  @burst 3

  defp post_event(conn, channel, body, ip) do
    conn
    |> Map.put(:remote_ip, ip)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/plugins/pulse/#{channel}/events", Jason.encode!(body))
  end

  # No response in a drill may be a server error — a cap that 500s is a cap
  # that fell over, not a cap that held.
  defp refute_5xx(statuses) do
    refute Enum.any?(statuses, &(&1 >= 500)),
           "abuse drill produced a 5xx storm: #{inspect(statuses)}"
  end

  describe "rate/burst cap under a single-IP volley" do
    test "a rapid volley is bounded to the burst; excess is 429; counter never over-counts", %{
      conn: conn
    } do
      ip = {198, 51, 100, 201}
      before = Pulse.total("abuse-rate")

      responses = for _ <- 1..10, do: post_event(conn, "abuse-rate", %{"hue" => 120}, ip)
      statuses = Enum.map(responses, & &1.status)

      two_hundreds = Enum.count(statuses, &(&1 == 200))

      # CAP HELD: at least one strike lands, but the volley is bounded to the
      # burst capacity — remove the IP bucket and all 10 would be 200 (RED).
      assert two_hundreds >= 1
      assert two_hundreds <= @burst
      # the excess is a clean 429, never dropped and never a 5xx
      assert 429 in statuses
      refute_5xx(statuses)

      # the durable counter advanced by EXACTLY the accepted strikes
      assert Pulse.total("abuse-rate") == before + two_hundreds

      # the 429s carry a Retry-After the client can honor
      limited = Enum.find(responses, &(&1.status == 429))
      assert [retry] = get_resp_header(limited, "retry-after")
      assert String.to_integer(retry) >= 1

      # FEED STAYS USABLE mid-storm: the read path answers 200 with the
      # strikes that made it in.
      feed = json_response(get(conn, "/v1/plugins/pulse/abuse-rate/recent"), 200)
      assert length(feed["events"]) == two_hundreds
    end
  end

  describe "per-channel daily cap" do
    test "strikes past the daily ceiling are 429'd; the counter freezes at the cap", %{conn: conn} do
      # daily_cap is 3; each strike from a distinct IP so the rate bucket never
      # trips — this isolates the daily cap as the ONLY gate under test.
      statuses =
        for i <- 1..5 do
          post_event(conn, "abuse-daily", %{"hue" => 10 + i}, {203, 0, 113, 40 + i}).status
        end

      # exactly the cap's worth land, the rest are turned away
      assert Enum.count(statuses, &(&1 == 200)) == 3
      assert Enum.count(statuses, &(&1 == 429)) == 2
      refute_5xx(statuses)

      # the over-cap strike is a 429 with the day-long Retry-After
      over = post_event(conn, "abuse-daily", %{"hue" => 99}, {203, 0, 113, 250})
      assert over.status == 429
      assert [retry] = get_resp_header(over, "retry-after")
      assert String.to_integer(retry) == 3600

      # DURABLE counter frozen at the ceiling — no strike leaked past
      assert Pulse.total("abuse-daily") == 3
    end
  end

  describe "byte ceiling (max_bytes)" do
    test "a valid-typed but oversize payload is rejected 400; counter unchanged", %{conn: conn} do
      before = Pulse.total("abuse-bytes")

      # all three fields present + valid → coerced payload ~28 B > the 20 B cap
      resp =
        post_event(conn, "abuse-bytes", %{"hue" => 200, "x" => 0.5, "y" => 0.25}, {192, 0, 2, 7})

      assert %{"error" => %{"code" => "invalid_event", "message" => msg}} =
               json_response(resp, 400)

      assert msg =~ "bytes"
      # nothing recorded — the cap fired before ingest
      assert Pulse.total("abuse-bytes") == before
    end

    test "the byte cap itself rejects an oversize clean map (unit-level, protective)" do
      {:ok, cfg} = Pulse.channel("abuse-bytes")
      # a fully-valid, fully-declared payload still overflows the 20 B ceiling
      assert {:error, reason} =
               Pulse.validate_payload(cfg, %{"hue" => 200, "x" => 0.5, "y" => 0.25})

      assert reason =~ "exceeds 20 bytes"
      # a payload under the ceiling passes the same gate
      assert {:ok, _} =
               Pulse.validate_payload(%{cfg | "max_bytes" => 200}, %{
                 "hue" => 1,
                 "x" => 0.0,
                 "y" => 0.0
               })
    end
  end

  describe "junk payloads + foreign/hostile origin" do
    test "origin is NOT the gate: a hostile-origin preflight still gets 204 + open CORS", %{
      conn: conn
    } do
      conn =
        conn
        |> put_req_header("origin", "https://totally-hostile.example")
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "content-type")
        |> options("/v1/plugins/pulse/test-storm/events")

      # caps, not identity: any origin is allowed through — the drills above
      # are what actually bound the abuse.
      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    test "junk bodies from a foreign origin are all 4xx; counter untouched; no 5xx", %{conn: conn} do
      before = Pulse.total("test-storm")

      base = %{"hue" => 200, "x" => 0.5, "y" => 0.25, "mega" => false}

      junk = [
        # unknown field
        Map.put(base, "evil", 1),
        # out of range
        %{base | "hue" => 9999},
        # wrong type
        %{base | "mega" => "yes"},
        # missing required
        Map.delete(base, "hue"),
        # oversize garbage body
        %{"junk" => String.duplicate("A", 50_000)}
      ]

      statuses =
        for {body, i} <- Enum.with_index(junk) do
          conn
          |> Map.put(:remote_ip, {172, 16, 9, i})
          |> put_req_header("origin", "https://totally-hostile.example")
          |> put_req_header("content-type", "application/json")
          |> post("/v1/plugins/pulse/test-storm/events", Jason.encode!(body))
          |> Map.get(:status)
        end

      assert Enum.all?(statuses, &(&1 in [400, 413])),
             "expected all junk rejected, got #{inspect(statuses)}"

      refute_5xx(statuses)
      # not one junk strike was recorded
      assert Pulse.total("test-storm") == before
    end
  end

  # A read against /recent from a chosen client IP via x-forwarded-for so the
  # per-IP read bucket is deterministic and isolated (the controller trusts the
  # first XFF hop). Base 127.0.0.1 is left untouched so the surrounding suites'
  # reads never share this bucket.
  defp read(conn, channel, ip) do
    conn
    |> put_req_header("x-forwarded-for", ip)
    |> get("/v1/plugins/pulse/#{channel}/recent")
  end

  describe "read-path flood (GET /recent + /stats)" do
    test "a single-IP read flood past the cap is 429'd with a Retry-After", %{conn: conn} do
      # 60 rapid reads from one IP against a 30-token burst (10/sec refill): the
      # loop runs in a few ms so refill is negligible — ~30 land, the rest 429.
      responses = for _ <- 1..60, do: read(conn, "test-storm", "203.0.113.161")
      statuses = Enum.map(responses, & &1.status)

      # CAP HELD: some reads land, but the flood is bounded — remove
      # check_read_bucket/2 and all 60 would be 200 (RED).
      assert Enum.any?(statuses, &(&1 == 200))
      assert 429 in statuses
      refute_5xx(statuses)

      # the read 429 carries a Retry-After the client can honor
      limited = Enum.find(responses, &(&1.status == 429))
      assert [retry] = get_resp_header(limited, "retry-after")
      assert String.to_integer(retry) >= 1
    end

    test "the feed stays usable: a fresh IP still reads 200 mid write-flood", %{conn: conn} do
      # Flood the WRITE path from one IP (fills that IP's write bucket) …
      writer = {203, 0, 113, 170}
      for _ <- 1..10, do: post_event(conn, "test-storm", %{"hue" => 45}, writer)

      # … while a DIFFERENT visitor's read is unaffected — the read is its own
      # per-IP bucket, so no single client's storm can starve the feed.
      fresh = read(conn, "test-storm", "198.51.100.90")
      assert fresh.status == 200
      assert %{"events" => _} = json_response(fresh, 200)
    end

    test "stats shares the read bucket: a read flood 429s the stats endpoint too", %{conn: conn} do
      ip = "203.0.113.180"
      # drain the bucket via /recent, then the very next /stats read is throttled
      for _ <- 1..40, do: read(conn, "test-storm", ip)

      stats =
        conn
        |> put_req_header("x-forwarded-for", ip)
        |> get("/v1/plugins/pulse/test-storm/stats")

      assert stats.status == 429
      assert [retry] = get_resp_header(stats, "retry-after")
      assert String.to_integer(retry) >= 1
    end
  end
end
