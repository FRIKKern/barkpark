defmodule Barkpark.PulseConfigHardeningTest do
  @moduledoc """
  wbqs-api-pulse-config-crash — a misconfigured (not merely unknown) pulse
  channel must fail CLOSED through the existing clean-4xx path, never crash
  the connection with a raw 500.

  Two config defects, each previously a first/Nth-request 500:

    * a channel entry missing (or with a blank) `"fields"` key raised
      `KeyError` from `Map.fetch!(cfg, "fields")` in
      `Pulse.validate_payload/2` on the very first POST.
    * `"rate_per_min" => 0` raised `ArithmeticError` from `ceil(60 / rate)`
      in the controller's `check_ip_bucket/3` the moment the burst allowance
      (3) was spent — so the 4th request from one IP, not the first.

  Both are hardened in `Barkpark.Pulse.channel/1` (fields validated at fetch
  time; `rate_per_min` clamped to a positive integer, falling back to the
  default of 10) — one guard point upstream of both crash sites, no new
  envelope code.

  Uses `Application.put_env/3`-installed fixture channels (restored via
  `on_exit`) instead of `config/test.exs`, so this file stays fully
  self-contained. `async: false`: the `RateLimiter` ETS table is
  process-global, and this suite drives it directly.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!

  alias Barkpark.Pulse

  @no_fields_channel "hardening-no-fields"
  @zero_rate_channel "hardening-zero-rate"

  setup do
    original = Application.get_env(:barkpark, :pulse_channels, %{})

    fixture =
      Map.merge(original, %{
        @no_fields_channel => %{
          # deliberately absent "fields" — the defect under test
          "rate_per_min" => 6000,
          "daily_cap" => 1_000_000
        },
        @zero_rate_channel => %{
          "fields" => %{"hue" => ["int", 0, 359]},
          "rate_per_min" => 0,
          "daily_cap" => 1_000_000
        }
      })

    Application.put_env(:barkpark, :pulse_channels, fixture)
    on_exit(fn -> Application.put_env(:barkpark, :pulse_channels, original) end)
    :ok
  end

  defp post_event(conn, channel, body, ip) do
    conn
    |> Map.put(:remote_ip, ip)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/plugins/pulse/#{channel}/events", Jason.encode!(body))
  end

  describe "Pulse.channel/1 — fails closed on a bad config, never raises" do
    test "a fields-less channel entry returns :error, not a merged config" do
      assert :error = Pulse.channel(@no_fields_channel)
    end

    test "rate_per_min <= 0 is clamped to the positive default (10)" do
      assert {:ok, cfg} = Pulse.channel(@zero_rate_channel)
      assert cfg["rate_per_min"] == 10
    end
  end

  describe "POST with a fields-less channel — clean 4xx, not a crash" do
    test "returns clean 4xx JSON instead of a raw 500", %{conn: conn} do
      conn = post_event(conn, @no_fields_channel, %{"hue" => 1}, {198, 51, 100, 210})

      assert conn.status in 400..499
      assert %{"error" => %{"code" => _, "message" => _}} = json_response(conn, conn.status)
    end
  end

  describe "POST with rate_per_min: 0 — burst then 429, not a crash" do
    test "the burst lands, the next request is a clean 429 with Retry-After", %{conn: conn} do
      ip = {198, 51, 100, 211}

      responses =
        for _ <- 1..4, do: post_event(conn, @zero_rate_channel, %{"hue" => 1}, ip)

      statuses = Enum.map(responses, & &1.status)

      refute Enum.any?(statuses, &(&1 >= 500)),
             "rate_per_min: 0 produced a 5xx instead of a clean 429: #{inspect(statuses)}"

      assert 429 in statuses

      limited = Enum.find(responses, &(&1.status == 429))
      assert [retry_after] = get_resp_header(limited, "retry-after")
      assert {n, ""} = Integer.parse(retry_after)
      assert n > 0

      assert %{"error" => %{"code" => "rate_limited"}} = json_response(limited, 429)
    end
  end
end
