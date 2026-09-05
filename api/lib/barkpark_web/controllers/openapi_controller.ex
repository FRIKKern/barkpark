defmodule BarkparkWeb.OpenApiController do
  @moduledoc """
  `GET /v1/openapi.json` — the published OpenAPI 3.1 descriptor of the `/v1`
  CMS API.

  Public by design (mounted under `:api_unlimited`, no token): the descriptor
  is meant to be fetched by SDK generators, procurement, and humans before a
  caller even holds a token — exactly like Coolify's checked-in `openapi.yaml`.

  The body is content-addressed into a weak ETag; an `If-None-Match` that
  matches short-circuits to `304 Not Modified` with an empty body. The pattern
  is the proven one from `CapabilitiesController`.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Api.OpenApi
  alias BarkparkWeb.Http.IfNoneMatch

  import Plug.Conn,
    only: [put_resp_content_type: 2, put_resp_header: 3, send_resp: 3]

  def index(conn, _params) do
    body = OpenApi.spec() |> Jason.encode!()

    etag =
      "W/\"openapi-" <>
        (:crypto.hash(:sha256, body) |> Base.encode16(case: :lower) |> binary_part(0, 16)) <>
        "\""

    conn = put_resp_header(conn, "etag", etag)

    if IfNoneMatch.match?(conn, etag) do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end
end
