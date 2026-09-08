defmodule BarkparkWeb.Plugs.RateLimitRetryAfterCarriersTest do
  @moduledoc """
  THE BACK-OFF INTERVAL TRAVELS ON TWO CARRIERS, AND BOTH MUST SURVIVE.

  Every 429 this server emits from a JSON refusal path carries the retry
  interval TWICE:

    * the `retry-after` **response header** — `put_resp_header/3`, the value an
      HTTP client library reads without parsing a body; and
    * `error.details.retry_after` **inside the JSON error envelope** — built by
      `Errors.to_envelope({:error, :rate_limited, %{retry_after: s}}, conn)`,
      the value an SDK reads off the decoded body.

  WHY BOTH ARE PINNED HERE, AND WHY THIS IS NOT BUSYWORK. Thirty consumers
  across the surfaces mishandle a 429 today: twelve cannot see it at all,
  eighteen more mis-read it. Every fix those lanes ship will read ONE carrier or
  the other — some the header, some the envelope field — and the choice is made
  independently in each consumer. If a later refactor drops the carrier a given
  consumer happened to pick, that consumer's fix silently stops working and
  NOBODY ATTRIBUTES IT TO THE LIMITER. This file is the thing that reds first.

  WHY NO ABSOLUTE VALUE IS ASSERTED. Every `retry_after_seconds/1` here derives
  the interval from a CONFIGURED budget (`:rate_limits`, `:ticket_rate_limits`,
  `:auth_write_rate_limits`), so an absolute number would pin deployment
  configuration, not the contract. What is asserted instead is: the carrier is
  PRESENT, it is a POSITIVE INTEGER, and — the assertion with the most teeth —
  the two carriers AGREE WITH EACH OTHER. Two carriers disagreeing is strictly
  worse than one missing: no consumer can detect it, and two consumers of the
  same refusal would back off by different amounts.

  ## The three limiters, as found by symbol

    * `BarkparkWeb.Plugs.RateLimit.json_refuse/2` — the 14 API pipelines
    * `BarkparkWeb.Plugs.TicketRateLimit.deny/2`
    * `BarkparkWeb.Plugs.AuthWriteRateLimit.deny/2`

  All three build the SAME envelope through the SAME `Errors.to_envelope/2`
  clause and set the SAME header, so header/envelope agreement is a property of
  one shared shape — which is exactly why one refactor can break all three, and
  why all three are driven here rather than one taken as representative.

  ## The FOURTH refusal path, which carries only ONE carrier — by design

  `RateLimit.browser_refuse/2` answers a `:browser`-class refusal that asked for
  `text/html` with an HTML page and the header ALONE: the body is a compile-time
  literal (Sobelow XSS.HTML flags any non-literal body), so there is no envelope
  and no `error.details.retry_after` to read. That is charter D4's intent, not a
  gap — but it is pinned below so nobody "fixes" the browser page by teaching a
  consumer to expect an envelope there, and so the asymmetry is discoverable
  from this file rather than from a support ticket.

  The plugs are driven DIRECTLY rather than through a route: the carriers are a
  property of the plug's refusal, and a direct call needs neither a database row
  nor an authenticated principal.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state that no Ecto
  # sandbox owns and that outlives each test. Start from an unspent table.
  setup :reset_rate_limiter!

  alias BarkparkWeb.Plugs.{AuthWriteRateLimit, RateLimit, TicketRateLimit}

  setup do
    rate_limits = Application.get_env(:barkpark, :rate_limits)
    auth_write = Application.get_env(:barkpark, :auth_write_rate_limits)

    on_exit(fn ->
      restore(:rate_limits, rate_limits)
      restore(:auth_write_rate_limits, auth_write)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  # The limiter table is process-global and survives each test, so every test
  # bills a UNIQUE client IP. 10.x is NOT loopback, therefore not a trusted
  # front, so `RateLimiter.client_ip/1` ignores `x-forwarded-for` and keys on the
  # peer — this address IS the bucket identity.
  defp unique_ip do
    n = System.unique_integer([:positive])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end

  defp from(ip), do: %{scoped_conn() | remote_ip: ip}

  # Spend the bucket until it refuses, rather than counting to a configured
  # budget. A token bucket refills, so an exact call count is a race; and an
  # absolute count over whole-node state shared with every other agent's test
  # process is not a thing this suite may assert.
  defp drive_to_refusal(limiter, fun, max_calls) do
    1..max_calls
    |> Enum.reduce_while(nil, fn _, _ ->
      conn = fun.()

      if conn.status == 429 do
        {:halt, conn}
      else
        {:cont, nil}
      end
    end)
    |> case do
      %Plug.Conn{} = conn ->
        conn

      nil ->
        flunk("""
        #{limiter} never refused in #{max_calls} calls, so this test asserted
        NOTHING about its 429. That is a broken fixture, not a passing limiter —
        the budget in force is larger than the drive, or the plug never reached
        its refusal clause.
        """)
    end
  end

  # THE HEADER CARRIER. Named arm: a mutation that drops `put_resp_header` must
  # exit HERE and nowhere else.
  defp header_seconds!(conn, limiter) do
    case Plug.Conn.get_resp_header(conn, "retry-after") do
      [raw] ->
        case Integer.parse(raw) do
          {seconds, ""} ->
            assert seconds > 0,
                   "#{limiter}: HEADER CARRIER NOT A BACK-OFF — `retry-after: #{raw}` is not positive"

            seconds

          _ ->
            flunk(
              "#{limiter}: HEADER CARRIER NOT NUMERIC — `retry-after: #{inspect(raw)}` does not parse as an integer"
            )
        end

      other ->
        flunk("""
        #{limiter}: HEADER CARRIER MISSING on a 429.

        `get_resp_header(conn, "retry-after")` returned #{inspect(other)}.
        Every consumer that backs off by reading the RESPONSE HEADER — rather
        than by decoding the body — is now blind on this limiter.
        """)
    end
  end

  # THE ENVELOPE CARRIER. Named arm: a mutation that drops `details.retry_after`
  # must exit HERE and nowhere else.
  defp envelope_seconds!(conn, limiter) do
    body =
      case Jason.decode(conn.resp_body) do
        {:ok, %{} = decoded} ->
          decoded

        _ ->
          flunk(
            "#{limiter}: ENVELOPE CARRIER UNREADABLE — the 429 body is not a JSON object: #{inspect(conn.resp_body)}"
          )
      end

    assert get_in(body, ["error", "code"]) == "rate_limited",
           "#{limiter}: the 429 envelope is not the `rate_limited` envelope: #{inspect(body)}"

    case get_in(body, ["error", "details", "retry_after"]) do
      seconds when is_integer(seconds) and seconds > 0 ->
        seconds

      other ->
        flunk("""
        #{limiter}: ENVELOPE CARRIER MISSING on a 429.

        `error.details.retry_after` was #{inspect(other)} in:

          #{inspect(body)}

        Every consumer that backs off by DECODING THE BODY — rather than reading
        the response header — is now blind on this limiter.
        """)
    end
  end

  # No absolute value. Presence, positivity, and — the assertion with teeth —
  # AGREEMENT.
  defp assert_both_carriers!(conn, limiter) do
    assert conn.status == 429,
           "#{limiter}: expected a 429 refusal to assert carriers against, got #{inspect(conn.status)}"

    header = header_seconds!(conn, limiter)
    envelope = envelope_seconds!(conn, limiter)

    assert header == envelope,
           """
           #{limiter}: THE TWO CARRIERS DISAGREE — header `retry-after: #{header}`,
           envelope `error.details.retry_after: #{envelope}`.

           This is worse than one carrier missing: no consumer can detect it, and
           two consumers of the SAME refusal back off by DIFFERENT amounts.
           """

    {header, envelope}
  end

  describe "BarkparkWeb.Plugs.RateLimit — the 14 API pipelines (json_refuse/2)" do
    test "a write refusal carries the interval in BOTH the header and the envelope" do
      ip = unique_ip()

      conn =
        drive_to_refusal(
          "RateLimit (:write)",
          fn -> RateLimit.call(%{from(ip) | method: "POST"}, RateLimit.init([])) end,
          400
        )

      assert_both_carriers!(conn, "RateLimit (:write)")
    end

    test "a read refusal carries the interval in BOTH the header and the envelope" do
      ip = unique_ip()

      conn =
        drive_to_refusal(
          "RateLimit (:read)",
          fn -> RateLimit.call(%{from(ip) | method: "GET"}, RateLimit.init([])) end,
          1200
        )

      assert_both_carriers!(conn, "RateLimit (:read)")
    end

    test "`Accept: text/html` does NOT strip either carrier on an API class" do
      # The negotiating branch is a property of the `:browser` class alone. An
      # API caller sending browser headers must still get the JSON envelope, so
      # both carriers survive an Accept header a browser would send.
      ip = unique_ip()

      conn =
        drive_to_refusal(
          "RateLimit (:write, Accept: text/html)",
          fn ->
            %{from(ip) | method: "POST"}
            |> put_req_header("accept", "text/html,application/xhtml+xml")
            |> RateLimit.call(RateLimit.init([]))
          end,
          400
        )

      assert_both_carriers!(conn, "RateLimit (:write, Accept: text/html)")
    end
  end

  describe "BarkparkWeb.Plugs.TicketRateLimit (deny/2)" do
    test "a ticket write refusal carries the interval in BOTH the header and the envelope" do
      # The plug only reads `%{id: key_id}` off the assign — a unique id is a
      # unique bucket, and no ticket-key row has to exist for the refusal shape
      # to be the thing under test.
      key_id = "carriers-#{System.unique_integer([:positive])}"

      conn =
        drive_to_refusal(
          "TicketRateLimit",
          fn ->
            %{from(unique_ip()) | method: "POST", path_info: ["v1", "tickets"]}
            |> Plug.Conn.assign(:ticket_key, %{id: key_id})
            |> TicketRateLimit.call(TicketRateLimit.init([]))
          end,
          200
        )

      assert_both_carriers!(conn, "TicketRateLimit")
    end
  end

  describe "BarkparkWeb.Plugs.AuthWriteRateLimit (deny/2)" do
    test "a register refusal carries the interval in BOTH the header and the envelope" do
      # config/test.exs parks this budget at 1_000_000 (effectively off) because
      # the whole suite's anonymous registers share the 127.0.0.1 bucket. A test
      # that forgot to set its own budget would drive 1_000_000 calls or pass
      # vacuously, so this one sets the budget AND takes a unique IP.
      Application.put_env(:barkpark, :auth_write_rate_limits, register: 2)
      ip = unique_ip()

      conn =
        drive_to_refusal(
          "AuthWriteRateLimit",
          fn ->
            %{from(ip) | method: "POST"}
            |> AuthWriteRateLimit.call(AuthWriteRateLimit.init([]))
          end,
          50
        )

      assert_both_carriers!(conn, "AuthWriteRateLimit")
    end
  end

  describe "the browser HTML refusal carries the header ALONE — by design" do
    test "an enforcing :browser refusal that asked for HTML has the header and NO envelope" do
      # THIS IS A PIN ON AN ASYMMETRY, NOT A SECOND COPY OF THE CONTRACT ABOVE.
      # `browser_refuse/2` answers `text/html` with a compile-time-literal page,
      # so the interval exists ONLY as the header. A consumer taught to read
      # `error.details.retry_after` gets nothing here — and that is the charter's
      # intent (a non-literal body reddens Sobelow's XSS.HTML), not a defect.
      Application.put_env(:barkpark, :rate_limits,
        browser_enabled: true,
        browser_enforce: true,
        browser_per_minute: 2
      )

      ip = unique_ip()

      conn =
        drive_to_refusal(
          "RateLimit (:browser, HTML)",
          fn ->
            %{from(ip) | method: "GET"}
            |> put_req_header("accept", "text/html")
            |> RateLimit.call(RateLimit.init(class: :browser))
          end,
          50
        )

      assert conn.status == 429

      # The one carrier this path does emit is still a real back-off.
      assert header_seconds!(conn, "RateLimit (:browser, HTML)") > 0

      refute String.contains?(conn.resp_body, "retry_after"),
             """
             The browser HTML 429 grew an envelope-shaped `retry_after`. Either
             the body stopped being a compile-time literal (Sobelow XSS.HTML) or
             this path started negotiating JSON. Both change what a browser-class
             consumer may rely on, and this file is the record that it could not.
             """
    end

    test "a :browser refusal that did NOT ask for HTML falls through to BOTH carriers" do
      Application.put_env(:barkpark, :rate_limits,
        browser_enabled: true,
        browser_enforce: true,
        browser_per_minute: 2
      )

      ip = unique_ip()

      conn =
        drive_to_refusal(
          "RateLimit (:browser, JSON)",
          fn ->
            %{from(ip) | method: "GET"}
            |> put_req_header("accept", "application/json")
            |> RateLimit.call(RateLimit.init(class: :browser))
          end,
          50
        )

      assert_both_carriers!(conn, "RateLimit (:browser, JSON)")
    end
  end
end
