defmodule BarkparkWeb.PulseSocket do
  @moduledoc """
  The ANONYMOUS realtime socket for Pulse channels (Shared Storm). Deliberately
  separate from `UserSocket`, whose connect gate requires a read token — a
  pulse subscriber is any visitor of a static page, carrying nothing.

  Connect always succeeds; every gate lives at channel JOIN
  (`PulseChannel.join/3` admits only explicitly-configured pulse channels).
  The socket is subscribe-only in practice: `PulseChannel` accepts no inbound
  events, so an anonymous connection can listen to the public strike feed and
  nothing else. Writes stay on the rate-limited HTTP POST.

  No per-socket `check_origin` override (the Past-Mistake-#11 landmine) — the
  websocket inherits the endpoint-level allowlist from runtime.exs
  (barkpark.cloud + *.vercel.app + BARKPARK_EXTRA_ORIGINS). A site embedding
  the pulse feed adds its origin to BARKPARK_EXTRA_ORIGINS.
  """
  use Phoenix.Socket

  channel "pulse:*", BarkparkWeb.PulseChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
