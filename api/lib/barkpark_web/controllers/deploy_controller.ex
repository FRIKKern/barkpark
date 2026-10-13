defmodule BarkparkWeb.DeployController do
  @moduledoc """
  Infra-only, loopback-gated endpoints the deploy tooling calls on the
  BEAM's own port — never routed through Caddy. `retire_sse/2` is the hook
  `deploy/instance-deploy.sh` calls on the OLD slot right after the Caddy
  flip lands (task-2bcada0faa01ebb2): see `Barkpark.Realtime.DrainSignal`
  for why this exists and what it broadcasts.

  Mounted on `:api_local` (`BarkparkWeb.Plugs.RequireLoopback` only, same
  pipeline `/v1/data/local/search` uses) — no token, because the caller IS
  the box: a non-loopback request 403s with no body, same as that route.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Realtime.DrainSignal

  @doc """
  Broadcast the retire signal to every SSE loop subscribed on this node.
  Idempotent and cheap to call more than once (a stream that already closed
  on an earlier call simply isn't subscribed anymore); the deploy script
  does not need to know whether anything was listening.
  """
  def retire_sse(conn, _params) do
    :ok = DrainSignal.broadcast_retire()
    send_resp(conn, 204, "")
  end
end
