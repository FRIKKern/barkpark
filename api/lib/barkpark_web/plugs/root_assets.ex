defmodule BarkparkWeb.Plugs.RootAssets do
  @moduledoc """
  Answers `GET`/`HEAD /assets/root/<hash>/<name>` with a root layout asset
  from `BarkparkWeb.RootAssets` (task-cca3c6d48e57097e).

  The current hash gets `cache-control: public, max-age=31536000, immutable`:
  the URL changes whenever the bytes do, so a browser never needs to ask
  again. Any other hash is a page rendered before a deploy; it gets the
  current bytes with `no-cache`, the policy of every other `/assets` file. An
  unknown name falls through to the rest of the endpoint.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method, path_info: ["assets", "root", hash, name]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    case BarkparkWeb.RootAssets.fetch(name) do
      {content_type, body, ^hash} ->
        send_asset(conn, content_type, body, "public, max-age=31536000, immutable")

      {content_type, body, _old} ->
        send_asset(conn, content_type, body, "no-cache")

      nil ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp send_asset(conn, content_type, body, cache_control) do
    conn
    |> put_resp_header("content-type", content_type)
    |> put_resp_header("cache-control", cache_control)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(200, body)
    |> halt()
  end
end
