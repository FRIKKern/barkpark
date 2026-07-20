defmodule Barkpark.Accounts.HibpReqClientTest do
  @moduledoc """
  Transport + response-mapping coverage for the REAL HIBP client.

  Every other HIBP test injects a fake `range/1` at the `@behaviour` seam, so
  `Hibp.ReqClient`'s own transport logic (status→error mapping, body coercion)
  and the `SUFFIX:COUNT` parse in `Hibp.suffix_present?/2` are otherwise
  uncovered. A regression there — a 200 body shape change, a dropped
  `String.upcase`, an inverted status match — would make `breached?/1` return
  `false` while HIBP is UP and correctly reporting the breach, silently
  accepting known-breached passwords with CI green (scar-class: silent
  security-control disablement, same shape as field-visibility fail-open).

  This drives the real `ReqClient` against a local Bypass endpoint that serves
  a genuine `SUFFIX:COUNT` range body — matching the established github /
  bokbasen `client_test` pattern.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Accounts.Hibp

  # SHA-1(prefix<5>) + suffix<35>, uppercase hex — exactly what HIBP indexes on.
  defp sha1_split(password) do
    <<prefix::binary-size(5), suffix::binary>> =
      :crypto.hash(:sha, password) |> Base.encode16(case: :upper)

    {prefix, suffix}
  end

  setup do
    # Trap exits so a Bypass plug crash after a forced transport error
    # (Bypass.down closing the conn) doesn't surface as `(exit) shutdown`.
    Process.flag(:trap_exit, true)

    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    prev_base = Application.get_env(:barkpark, :hibp_base_url)
    prev_enabled = Application.get_env(:barkpark, :hibp_enabled)
    prev_http = Application.get_env(:barkpark, :hibp_http)

    # Point the REAL ReqClient at Bypass, enable the check, and make sure the
    # default (real) ReqClient is the wired impl — NOT a behaviour fake.
    Application.put_env(:barkpark, :hibp_base_url, base)
    Application.put_env(:barkpark, :hibp_enabled, true)
    Application.delete_env(:barkpark, :hibp_http)

    on_exit(fn ->
      set_or_del(:hibp_base_url, prev_base)
      set_or_del(:hibp_enabled, prev_enabled)
      set_or_del(:hibp_http, prev_http)
    end)

    {:ok, bypass: bypass, base: base}
  end

  describe "ReqClient.range/1 (real transport, direct)" do
    test "200 -> {:ok, body} with the SUFFIX:COUNT text intact", %{bypass: bypass} do
      {prefix, suffix} = sha1_split("hunter2")
      body = "#{suffix}:42\r\nFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF:1\r\n"

      Bypass.expect_once(bypass, "GET", "/range/#{prefix}", fn conn ->
        # k-anonymity: only the 5-char prefix ever hits the wire.
        assert conn.request_path == "/range/#{prefix}"
        Plug.Conn.resp(conn, 200, body)
      end)

      assert {:ok, got} = Hibp.ReqClient.range(prefix)
      assert got == body
    end

    test "503 -> {:error, {:http, 503}} (NOT silently coerced to ok)", %{bypass: bypass} do
      {prefix, _suffix} = sha1_split("hunter2")

      Bypass.expect_once(bypass, "GET", "/range/#{prefix}", fn conn ->
        Plug.Conn.resp(conn, 503, "upstream down")
      end)

      assert {:error, {:http, 503}} = Hibp.ReqClient.range(prefix)
    end

    test "429 -> {:error, {:http, 429}} (rate-limit is an error, not a clean body)",
         %{bypass: bypass} do
      {prefix, _suffix} = sha1_split("hunter2")

      Bypass.expect_once(bypass, "GET", "/range/#{prefix}", fn conn ->
        Plug.Conn.resp(conn, 429, "slow down")
      end)

      assert {:error, {:http, 429}} = Hibp.ReqClient.range(prefix)
    end

    test "connection refused -> {:error, reason} (transport-level failure)",
         %{bypass: bypass} do
      {prefix, _suffix} = sha1_split("hunter2")
      Bypass.down(bypass)

      assert {:error, _reason} = Hibp.ReqClient.range(prefix)
    end
  end

  describe "breached?/1 end-to-end over the real ReqClient" do
    test "(a) suffix present in the 200 body -> breached? = true", %{bypass: bypass} do
      pw = "P@ssw0rd-known-breach"
      {prefix, suffix} = sha1_split(pw)

      Bypass.expect_once(bypass, "GET", "/range/#{prefix}", fn conn ->
        Plug.Conn.resp(conn, 200, "#{suffix}:1337\r\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:9\r\n")
      end)

      assert Hibp.breached?(pw) == true
    end

    test "(b) suffix absent from the 200 body -> breached? = false", %{bypass: bypass} do
      pw = "a-totally-unique-passphrase-92731"
      {prefix, _suffix} = sha1_split(pw)

      Bypass.expect_once(bypass, "GET", "/range/#{prefix}", fn conn ->
        # A well-formed response that simply does NOT list this suffix.
        Plug.Conn.resp(
          conn,
          200,
          "0000000000000000000000000000000000A:3\r\nBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB:7\r\n"
        )
      end)

      assert Hibp.breached?(pw) == false
    end

    test "(c) case-insensitive suffix match — HIBP returns uppercase, a lowercased body still matches",
         %{bypass: bypass} do
      # This is exactly the mapping a regression (dropping String.upcase) would
      # break: the encoded suffix is uppercase, so a lowercase body suffix must
      # still be recognised as breached.
      pw = "MixedCase-Match-Test"
      {prefix, suffix} = sha1_split(pw)
      lowercased = String.downcase(suffix)

      Bypass.expect_once(bypass, "GET", "/range/#{prefix}", fn conn ->
        Plug.Conn.resp(conn, 200, "#{lowercased}:5\r\n")
      end)

      assert Hibp.breached?(pw) == true
    end

    test "count 0 -> not breached (padding rows are ignored)", %{bypass: bypass} do
      # HIBP's add-padding returns real-suffix rows with count 0; those are NOT
      # breaches and must not flip breached? true.
      pw = "padding-row-suffix"
      {prefix, suffix} = sha1_split(pw)

      Bypass.expect_once(bypass, "GET", "/range/#{prefix}", fn conn ->
        Plug.Conn.resp(conn, 200, "#{suffix}:0\r\n")
      end)

      assert Hibp.breached?(pw) == false
    end

    test "(d) fail-OPEN on transport error: 503 -> breached? = false (DELIBERATE)",
         %{bypass: bypass} do
      # Documented policy (Hibp @moduledoc): availability > this defence, so an
      # unreachable/erroring HIBP allows the password. Asserted here so the
      # fail-open is a *tested* decision, not an accident — while a healthy but
      # misparsed 200 (tests a/c above) does NOT get this same free pass.
      pw = "would-be-breached-but-hibp-down"
      {prefix, _suffix} = sha1_split(pw)

      Bypass.expect_once(bypass, "GET", "/range/#{prefix}", fn conn ->
        Plug.Conn.resp(conn, 503, "upstream down")
      end)

      assert Hibp.breached?(pw) == false
    end

    test "(d) fail-OPEN on connection refused -> breached? = false", %{bypass: bypass} do
      pw = "would-be-breached-but-network-gone"
      Bypass.down(bypass)

      assert Hibp.breached?(pw) == false
    end
  end

  defp set_or_del(key, nil), do: Application.delete_env(:barkpark, key)
  defp set_or_del(key, val), do: Application.put_env(:barkpark, key, val)
end
