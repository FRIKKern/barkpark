defmodule BarkparkWeb.MetaControllerTest do
  @moduledoc """
  /v1/meta — the no-auth SDK handshake. Covers the tolerant `production`
  boolean added for the CLI's fail-closed prod write-guard
  (onb-backlog-isprod-custom-host-write-confirm): the client treats any
  non-local host as production unless the server explicitly advertises
  `production: false`, so this endpoint carrying an honest boolean is what
  keeps genuine non-prod instances frictionless. The signal is compile-time
  (`Mix.env() == :prod`), so a test build MUST report false — a prod build
  can never talk itself out of the guard at runtime, and a dev/test build
  never claims to be prod.
  """

  use BarkparkWeb.ConnCase, async: true

  test "GET /v1/meta carries the production boolean, false on a non-prod build", %{conn: conn} do
    body = conn |> get("/v1/meta") |> json_response(200)

    assert is_boolean(body["production"]),
           "production must be a real boolean, got: #{inspect(body["production"])}"

    assert body["production"] == false,
           "a MIX_ENV=test build must advertise production:false"
  end

  test "GET /v1/meta keeps the existing handshake fields intact", %{conn: conn} do
    body = conn |> get("/v1/meta") |> json_response(200)

    assert is_binary(body["minApiVersion"])
    assert is_binary(body["maxApiVersion"])
    assert {:ok, _, _} = DateTime.from_iso8601(body["serverTime"])
    assert Map.has_key?(body, "currentDatasetSchemaHash")
  end
end
