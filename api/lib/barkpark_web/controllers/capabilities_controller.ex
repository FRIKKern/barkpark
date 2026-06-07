defmodule BarkparkWeb.CapabilitiesController do
  @moduledoc """
  `GET /v1/capabilities` — the single CLI/MCP/SDK contract surface (M1).

  Mounted under the `:api` pipeline so `BarkparkWeb.Plugs.OptionalToken`
  resolves an OPTIONAL token into `conn.assigns[:api_token]`. The controller
  maps that token to one of the six auth tiers, assembles the full superset
  manifest, projects it through the existence-hiding allow-list keyed on the
  caller's tier, and returns the projected manifest as JSON.

  The projected body is content-addressed into an ETag (varies by tier); an
  `If-None-Match` that matches short-circuits to `304 Not Modified` with an
  empty body.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Plugins.Capabilities

  import Plug.Conn, only: [get_req_header: 2, put_resp_header: 3, send_resp: 3]

  def index(conn, _params) do
    caller_tier = Capabilities.tier_for_token(conn.assigns[:api_token])
    manifest = Capabilities.manifest(caller_tier)
    etag = manifest["etag"]

    conn = put_resp_header(conn, "etag", etag)

    if etag_matches?(conn, etag) do
      send_resp(conn, 304, "")
    else
      json(conn, manifest)
    end
  end

  # Honor If-None-Match. The header may carry a comma-separated list of
  # validators or the wildcard `*`; a match short-circuits to 304.
  defp etag_matches?(conn, etag) do
    case get_req_header(conn, "if-none-match") do
      [] ->
        false

      values ->
        candidates =
          values
          |> Enum.flat_map(&String.split(&1, ","))
          |> Enum.map(&String.trim/1)

        "*" in candidates or etag in candidates
    end
  end
end
