defmodule BarkparkWeb.EndpointLowTrustBodyCapTest do
  @moduledoc """
  The anonymous / outsider doors cap the body AT THE PARSER (Run-4 Lane B).

  `BarkparkWeb.Endpoint.parse_body/2` parses every request body up to 100 MB
  before the router runs. The anonymous form-submission door (`POST
  /v1/plugins/forms/…/submissions`) and the outsider ticket door (`/v1/tickets…`,
  `bptk_` keys) both enforce their real caps — 64 KiB, 64 KiB per message,
  10 MiB per attachment — only in the CONTROLLER, after that parse, and the
  forms `content-length` pre-check passes a chunked request (no header) straight
  through. So one anonymous client could make the server decode ~100 MB per
  request, repeatedly, before any gate — including the per-IP rate limit and
  the key check — ran.

  These requests carry NO `content-length` (the test adapter sends none — a
  chunked upload), so only the parser can refuse them. Each refusal is paired
  with a control on a non-low-trust route that still accepts the same body, so
  a global cap cut would fail this file rather than pass it.
  """
  use BarkparkWeb.ConnCase, async: false

  @forms_path "/v1/plugins/forms/w/nope/p/nope/d/production/sites/nope/submissions"

  defp json_body(bytes), do: Jason.encode!(%{"message" => String.duplicate("a", bytes)})

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, body)
  end

  describe "the anonymous form-submission door" do
    test "a 200 KB chunked JSON body is refused 413 by the parser, before any lookup", %{
      conn: conn
    } do
      resp = post_json(conn, @forms_path, json_body(200_000))

      assert resp.status == 413,
             "a 200 KB anonymous form post was parsed and routed (got #{resp.status})"

      assert Jason.decode!(resp.resp_body)["error"]["code"] == "payload_too_large"
    end

    # Run-4 lane C: the 413 named the GLOBAL cap ("100 MB") to a poster this
    # route refused at 64 KiB.
    test "the 413 names THIS route's limit, not the global 100 MB", %{conn: conn} do
      error = Jason.decode!(post_json(conn, @forms_path, json_body(200_000)).resp_body)["error"]

      assert error["message"] =~ "64 KiB"
      assert error["hint"] =~ "64 KiB"
      refute error["hint"] =~ "100 MB"
    end

    test "a small body still reaches the controller (404 for an unknown endpoint)", %{conn: conn} do
      resp = post_json(conn, @forms_path, json_body(100))
      assert resp.status == 404
    end
  end

  describe "the outsider ticket door" do
    test "a 2 MB chunked JSON body is refused 413 before the key check", %{conn: conn} do
      resp =
        conn
        |> put_req_header("authorization", "Bearer bptk_not_a_real_key")
        |> post_json("/v1/tickets", json_body(2_000_000))

      assert resp.status == 413,
             "a 2 MB ticket body was parsed before the key check (got #{resp.status})"
    end

    test "a small body still reaches the key check (401 for a bogus key)", %{conn: conn} do
      resp =
        conn
        |> put_req_header("authorization", "Bearer bptk_not_a_real_key")
        |> post_json("/v1/tickets", json_body(100))

      assert resp.status in [401, 404]
    end

    test "an attachment body over 10 MiB + multipart slack is refused 413", %{conn: conn} do
      resp =
        conn
        |> put_req_header("authorization", "Bearer bptk_not_a_real_key")
        |> post_json("/v1/tickets/some-id/attachments", json_body(12 * 1024 * 1024))

      assert resp.status == 413
    end
  end

  describe "the control — trusted doors keep the general cap" do
    test "a 2 MB body on the mutate door is parsed and reaches auth", %{conn: conn} do
      resp = post_json(conn, "/v1/data/mutate/production", json_body(2_000_000))
      refute resp.status == 413
    end
  end
end
