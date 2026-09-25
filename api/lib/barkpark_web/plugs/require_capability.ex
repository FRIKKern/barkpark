defmodule BarkparkWeb.Plugs.RequireCapability do
  @moduledoc """
  Refuses every route of a disabled capability (see `Barkpark.Capability`) with
  a plain 404.

  The routes stay compiled in; this plug decides at request time, so a release
  can turn a subsystem off through `BARKPARK_CAPABILITIES_OFF` without a
  rebuild. The refusal is `Phoenix.Router.NoRouteError`, the same one
  `BarkparkWeb.Plugs.PluginRouteGuard` raises for a disabled plugin's routes:
  the endpoint renders a 404 in whatever format the request negotiated, and a
  caller cannot tell a disabled subsystem from a route that does not exist.

  Mounted FIRST in each gated pipeline list, so a disabled subsystem does no
  token lookup and touches no chat process or ledger row.

      pipe_through([:studio_chat_capability, :api, :require_chat_access])
  """

  @behaviour Plug

  @impl Plug
  def init(capability) do
    unless capability in Barkpark.Capability.names() do
      raise ArgumentError, "unknown capability #{inspect(capability)}"
    end

    capability
  end

  @impl Plug
  def call(%Plug.Conn{} = conn, capability) do
    if Barkpark.Capability.enabled?(capability) do
      conn
    else
      raise Phoenix.Router.NoRouteError,
        conn: conn,
        router: Map.get(conn.private, :phoenix_router, __MODULE__)
    end
  end
end
