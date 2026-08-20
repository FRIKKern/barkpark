defmodule BarkparkWeb.ErrorEnvelopeFormatTest do
  @moduledoc """
  `config/config.exs` `render_errors` lists JSON first (Phoenix renders the
  FIRST format when Accept can't be resolved, and NoRouteError fires before
  the `:accepts` plug runs) — so an unmatched `/v1` path returns the canonical
  JSON envelope, never `ErrorHTML`'s dark HTML page, for BOTH real API
  consumers: the Go apiclient (sends no `Accept` header on ordinary calls) and
  the JS SDK (sends the vendor `Accept: application/vnd.barkpark+json`,
  registered via `config :mime, :types` in config.exs).
  """
  use BarkparkWeb.ConnCase, async: true

  @unmatched_path "/v1/this-route-does-not-exist"

  test "no Accept header on an unmatched /v1 path returns the JSON envelope" do
    conn = get(build_conn(), @unmatched_path)

    assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert %{"error" => %{"code" => code, "message" => _}} = json_response(conn, 404)
    assert code == "not_found"
  end

  test "vendor-only Accept header on an unmatched /v1 path returns the JSON envelope" do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("accept", "application/vnd.barkpark+json")
      |> get(@unmatched_path)

    assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert %{"error" => %{"code" => code, "message" => _}} = json_response(conn, 404)
    assert code == "not_found"
  end
end
