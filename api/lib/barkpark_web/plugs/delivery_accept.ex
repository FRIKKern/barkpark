defmodule BarkparkWeb.Plugs.DeliveryAccept do
  @moduledoc """
  Lets the media delivery GETs answer any `Accept` header
  (task-701191424b8d15e8).

  The delivery routes (`/media/files/*path`, `/media/renditions/:id/:preset`,
  their `/w/:ws/p/:proj` mirrors, and the Sanity-shaped `/images/...` and
  `/files/...` routes) return image and file bytes, not JSON. They ride
  pipelines that run `plug(:accepts, ["json"])` so that a refusal still renders
  the JSON error envelope. That plug raised `Phoenix.NotAcceptableError` for a
  strict header such as `Accept: image/webp`, `image/avif`, `image/*` or
  `application/pdf`, so a client that asked for exactly the type the route
  serves got a 406. Sanity's CDN serves those headers, and a browser header
  works only because it carries `*/*`.

  This plug runs before `:accepts` on the delivery scopes only. When the
  header does not already name `application/json`, it appends
  `, application/json`, the same append `AcceptBarkparkVendor` does for SSE,
  tar and NDJSON clients. `:accepts` then negotiates the `json` format, which
  is what an error on these routes renders in. The bytes are unaffected:
  `auto=format` reads the header by substring (`image/avif`, `image/webp`),
  and the appended type names neither.

  The JSON API routes do not mount this plug, so they keep refusing a header
  that cannot take JSON. That refusal renders as 406 `not_acceptable`
  (`BarkparkWeb.ErrorJSON`).
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "accept") do
      [header | _] when is_binary(header) ->
        if String.trim(header) == "" or String.contains?(header, "application/json"),
          do: conn,
          else: put_req_header(conn, "accept", header <> ", application/json")

      _ ->
        conn
    end
  end
end
