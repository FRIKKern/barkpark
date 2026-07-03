defmodule BarkparkWeb.TicketKeysControllerTest do
  @moduledoc """
  Unit tests for `TicketKeysController.host_base/1` — the base URL the handoff
  card's verbatim curls target. The card is the 2-minute product artifact
  (charter Decision 6): if this derivation is wrong behind the prod proxy, the
  key-holder's very first curl dies in a 308 redirect, so the proxy-header
  handling is pinned here. (The controller's routes are mounted by the tickets
  plugin in a sibling slice; the full request-cycle story test is wave 2.)
  """
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias BarkparkWeb.TicketKeysController, as: Controller

  describe "host_base/1 — direct (unproxied) requests" do
    test "elides the standard port" do
      assert Controller.host_base(conn(:post, "http://example.test/v1/x")) ==
               "http://example.test"

      assert Controller.host_base(conn(:post, "https://example.test/v1/x")) ==
               "https://example.test"
    end

    test "keeps a nonstandard port (dev localhost:4000)" do
      assert Controller.host_base(conn(:post, "http://localhost:4000/v1/x")) ==
               "http://localhost:4000"
    end
  end

  describe "host_base/1 — behind a TLS-terminating proxy" do
    test "trusts x-forwarded-proto over the internal hop's scheme" do
      base =
        conn(:post, "http://guerrilla.barkpark.cloud/v1/x")
        |> put_req_header("x-forwarded-proto", "https")
        |> Controller.host_base()

      # https, and the INTERNAL port must not leak into the public URL.
      assert base == "https://guerrilla.barkpark.cloud"
    end

    test "internal nonstandard port never leaks when the proxy declares the scheme" do
      base =
        conn(:post, "http://guerrilla.barkpark.cloud:4001/v1/x")
        |> put_req_header("x-forwarded-proto", "https")
        |> Controller.host_base()

      assert base == "https://guerrilla.barkpark.cloud"
    end

    test "takes the first proto of a chained-proxy comma list" do
      base =
        conn(:post, "http://example.test/v1/x")
        |> put_req_header("x-forwarded-proto", "https, http")
        |> Controller.host_base()

      assert base == "https://example.test"
    end

    test "honours an explicit nonstandard x-forwarded-port" do
      base =
        conn(:post, "http://example.test/v1/x")
        |> put_req_header("x-forwarded-proto", "https")
        |> put_req_header("x-forwarded-port", "8443")
        |> Controller.host_base()

      assert base == "https://example.test:8443"
    end

    test "an unrecognised x-forwarded-proto falls back to the connection's own scheme" do
      base =
        conn(:post, "http://example.test:4000/v1/x")
        |> put_req_header("x-forwarded-proto", "gopher")
        |> Controller.host_base()

      assert base == "http://example.test:4000"
    end
  end
end
