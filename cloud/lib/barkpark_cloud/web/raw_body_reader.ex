defmodule BarkparkCloud.Web.RawBodyReader do
  @moduledoc """
  Plug.Parsers body reader that ALSO stashes the raw request body in
  `conn.assigns[:raw_body]` (as an iolist) so HMAC-verifying routes can recover
  the EXACT bytes GitHub signed.

  Plug.Parsers consumes the body once and hands the decoded params to the
  router; without a custom reader the raw bytes are gone before the route can
  see them. This reader does the same `Plug.Conn.read_body/2` call but
  prepends each chunk to `:raw_body` first, so a webhook handler can recover
  the original payload via `Enum.reverse/1 |> IO.iodata_to_binary/1`.
  """

  @doc """
  Drop-in replacement for `Plug.Conn.read_body/2`. On every chunk, prepends the
  body to `conn.assigns[:raw_body]` so the route sees the exact request bytes
  later — needed for GitHub HMAC-SHA256 verification, which signs the raw JSON.
  """
  def read_body(conn, opts) do
    with {:ok, body, conn} <- Plug.Conn.read_body(conn, opts) do
      conn = update_in(conn.assigns[:raw_body], &[body | &1 || []])
      {:ok, body, conn}
    end
  end
end
