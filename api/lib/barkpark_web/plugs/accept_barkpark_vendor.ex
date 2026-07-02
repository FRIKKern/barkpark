defmodule BarkparkWeb.Plugs.AcceptBarkparkVendor do
  @moduledoc """
  Normalizes `Accept` for `application/vnd.barkpark+json` so Plug's
  `:accepts` matcher admits the request without registering the vendor
  MIME type globally.

  When the incoming `Accept` header mentions the vendor type (with any
  suffix/modifier, e.g. `+filterresponse=false`), this plug appends
  `application/json` to the header so the standard matcher accepts it,
  and assigns `:barkpark_vendor_accept` so downstream controllers can
  set the vendor response content-type.

  It performs the SAME append (without the vendor assign) when the header
  mentions `text/event-stream`: a spec-compliant SSE client sends the
  canonical streaming Accept, but the listen pipelines run
  `plug(:accepts, ["json"])`, which would 406 that header before the
  request ever reaches `ListenController` (which sets its own
  `text/event-stream` response content-type). Appending `application/json`
  lets the standard matcher negotiate JSON — identical to `*/*` — so the
  stream endpoint is reachable. Barkpark's own sync worker hit this and
  documents an `Accept: */*` client workaround in
  `lib/barkpark/sync/HANDOFF.md`; this makes the canonical header work too.
  This runs before `:accepts` in both the `:api` and `:scoped_api`
  pipelines, so no router change is needed; only requests that would
  otherwise 406 are affected.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    accept_header = conn |> get_req_header("accept") |> List.first() || ""

    qp_suppress = conn.query_params["filterresponse"] == "false"
    accept_suppress = String.contains?(accept_header, "+filterresponse=false")

    conn = assign(conn, :barkpark_filterresponse, not (qp_suppress or accept_suppress))

    case get_req_header(conn, "accept") do
      [] ->
        conn

      [header | _] ->
        cond do
          vendor?(header) ->
            conn
            |> assign(:barkpark_vendor_accept, true)
            |> put_req_header("accept", header <> ", application/json")

          # SSE clients send `text/event-stream`; append (do NOT replace) so
          # `:accepts ["json"]` negotiates JSON instead of 406-ing. The listen
          # controller sets its own `text/event-stream` response type.
          sse?(header) ->
            put_req_header(conn, "accept", header <> ", application/json")

          true ->
            conn
        end
    end
  end

  defp vendor?(header) do
    String.contains?(header, "application/vnd.barkpark+json") or
      String.contains?(header, "application/vnd.barkpark+filterresponse=")
  end

  defp sse?(header), do: String.contains?(header, "text/event-stream")
end
