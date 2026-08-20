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

  describe "AcceptBarkparkVendor x-tar negotiation (bp cloud workspace export)" do
    # `bp cloud workspace export` sends `application/x-tar`, but the bundle route
    # rides the `:api` pipeline (`plug :accepts ["json"]`), which would 406 that
    # header before the request reaches `WorkspaceController.export` (which sets
    # its own `application/x-tar` attachment response type). AcceptBarkparkVendor
    # appends `application/json` — mirroring its `text/event-stream` branch — so
    # the seam negotiates json instead. The latent 406 read as a server 500 on
    # guerrilla (the CLI envelope rendered it as internal_error).

    alias BarkparkWeb.Plugs.AcceptBarkparkVendor

    test "a bare `application/x-tar` Accept 406s under `:accepts [\"json\"]` (pre-fix behavior)" do
      conn =
        :get
        |> conn("/")
        |> put_req_header("accept", "application/x-tar")
        |> fetch_query_params()

      assert_raise Phoenix.NotAcceptableError, fn ->
        Phoenix.Controller.accepts(conn, ["json"])
      end
    end

    test "AcceptBarkparkVendor rewrites `application/x-tar` so `:accepts` negotiates json" do
      conn =
        :get
        |> conn("/")
        |> put_req_header("accept", "application/x-tar")
        |> AcceptBarkparkVendor.call(AcceptBarkparkVendor.init([]))

      # Appended, NOT replaced — the tar type survives; json is negotiable.
      assert get_req_header(conn, "accept") == ["application/x-tar, application/json"]

      # The exact negotiation the `:api` pipeline runs no longer raises → the
      # request reaches WorkspaceController.export (which sets its own x-tar
      # attachment response type + 200) instead of 406-ing in the pipeline.
      negotiated = Phoenix.Controller.accepts(conn, ["json"])
      refute negotiated.halted
      # NOT flagged as a vendor response — the controller owns its content-type.
      refute negotiated.assigns[:barkpark_vendor_accept]
    end
  end

  describe "AcceptBarkparkVendor x-ndjson negotiation (GET /v1/data/export/:dataset)" do
    # The backup verb streams NDJSON: `ExportController.export/2` sets
    # `application/x-ndjson` as its response content-type, and the Go client
    # (`internal/apiclient/export.go`) sends the matching Accept. But the route
    # rides `:scoped_api` under `plug :accepts ["json"]`, which 406s a bare
    # `application/x-ndjson` BEFORE auth — the owner's backup fails with a
    # negotiation error that names nothing. Same seam as x-tar above, same fix.

    alias BarkparkWeb.Plugs.AcceptBarkparkVendor

    test "a bare `application/x-ndjson` Accept 406s under `:accepts [\"json\"]` (pre-fix behavior)" do
      conn =
        :get
        |> conn("/")
        |> put_req_header("accept", "application/x-ndjson")
        |> fetch_query_params()

      assert_raise Phoenix.NotAcceptableError, fn ->
        Phoenix.Controller.accepts(conn, ["json"])
      end
    end

    test "AcceptBarkparkVendor rewrites `application/x-ndjson` so `:accepts` negotiates json" do
      conn =
        :get
        |> conn("/")
        |> put_req_header("accept", "application/x-ndjson")
        |> AcceptBarkparkVendor.call(AcceptBarkparkVendor.init([]))

      # Appended, NOT replaced — the ndjson type survives; json is negotiable.
      assert get_req_header(conn, "accept") == ["application/x-ndjson, application/json"]

      negotiated = Phoenix.Controller.accepts(conn, ["json"])
      refute negotiated.halted
      # NOT flagged as a vendor response — ExportController owns its content-type.
      refute negotiated.assigns[:barkpark_vendor_accept]
    end

    test "the Go client's full export Accept header negotiates json" do
      conn =
        :get
        |> conn("/")
        |> put_req_header("accept", "application/x-ndjson, application/json")
        |> AcceptBarkparkVendor.call(AcceptBarkparkVendor.init([]))

      negotiated = Phoenix.Controller.accepts(conn, ["json"])
      refute negotiated.halted
    end
  end
end
