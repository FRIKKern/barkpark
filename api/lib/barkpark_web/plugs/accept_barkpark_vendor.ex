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
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "accept") do
      [] ->
        conn

      [header | _] ->
        if vendor?(header) do
          # TODO(P2): honor `+filterresponse=false` by suppressing the filter-aware
          # envelope wrapper. For Phase 1A the modifier is cosmetic — we acknowledge
          # the header, forward the current envelope, and let clients flip it later.
          conn
          |> assign(:barkpark_vendor_accept, true)
          |> put_req_header("accept", header <> ", application/json")
        else
          conn
        end
    end
  end

  defp vendor?(header) do
    String.contains?(header, "application/vnd.barkpark+json") or
      String.contains?(header, "application/vnd.barkpark+filterresponse=")
  end
end
