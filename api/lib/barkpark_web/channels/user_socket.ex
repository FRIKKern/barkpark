defmodule BarkparkWeb.UserSocket do
  @moduledoc """
  The public realtime socket. Today it carries one channel — `SearchChannel`
  ("search:<ws>:<proj>:<dataset>") — so a browser can run live, per-keystroke
  search over a single persistent connection instead of one HTTPS request (via
  Vercel) per keystroke.

  Auth is a Bearer-style READ token presented in the connect params
  (`{token: "<read token>"}`) — the same `Barkpark.Auth.verify_token/1` the HTTP
  `RequireToken` plug uses. The token is stashed in `socket.assigns.api_token`;
  the channel resolves the workspace/project scope on join and authorizes the
  token against it (the P0 leak guard). An unverifiable token fails the connect
  closed.
  """
  use Phoenix.Socket

  channel "search:*", BarkparkWeb.SearchChannel

  @impl true
  def connect(%{"token" => raw}, socket, _connect_info) when is_binary(raw) do
    case Barkpark.Auth.verify_token(raw) do
      {:ok, token} -> {:ok, assign(socket, :api_token, token)}
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # No socket-wide id — disconnect targeting is per-token if ever needed, not
  # required for read-only search.
  @impl true
  def id(_socket), do: nil
end
