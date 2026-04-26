defmodule BarkparkWeb.Plugs.ErrorEnvelopeNegotiationTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias BarkparkWeb.Plugs.ErrorEnvelopeNegotiation

  defp run(conn), do: ErrorEnvelopeNegotiation.call(conn, ErrorEnvelopeNegotiation.init([]))

  test "Accept-Version: 2 selects :v2" do
    conn =
      :get
      |> conn("/")
      |> put_req_header("accept-version", "2")
      |> run()

    assert conn.assigns.error_envelope_version == :v2
  end

  test "missing header defaults to :v1" do
    conn = run(conn(:get, "/"))
    assert conn.assigns.error_envelope_version == :v1
  end

  test "header value of \"1\" stays on :v1" do
    conn =
      :get
      |> conn("/")
      |> put_req_header("accept-version", "1")
      |> run()

    assert conn.assigns.error_envelope_version == :v1
  end

  test "unknown / malformed values fall back to :v1" do
    for value <- ["3", "v2", "garbage", ""] do
      conn =
        :get
        |> conn("/")
        |> put_req_header("accept-version", value)
        |> run()

      assert conn.assigns.error_envelope_version == :v1, "expected :v1 for #{inspect(value)}"
    end
  end

  test "tolerates whitespace around the version value" do
    conn =
      :get
      |> conn("/")
      |> put_req_header("accept-version", "  2  ")
      |> run()

    assert conn.assigns.error_envelope_version == :v2
  end
end
