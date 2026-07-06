defmodule BarkparkWeb.PulseChannel do
  @moduledoc """
  Subscribe-only realtime feed for one Pulse channel (Shared Storm).

  A client joins `"pulse:<channel>"`; the join is admitted only when the pulse
  channel is explicitly configured (`Barkpark.Pulse.channel/1`) — unknown
  channels fail closed, mirroring the HTTP surface's 404. The join reply
  carries the current durable total so a fresh client shows the counter
  without a round-trip.

  Events flow ONE way: `PulseController.create/2` broadcasts each recorded
  strike as a `"strike"` event (`%{id, payload, total}`) on the topic and
  Phoenix pushes it to every subscriber — no `handle_in` exists, so the
  socket cannot be used to write. Writes stay on the rate-limited HTTP POST.
  """
  use Phoenix.Channel

  alias Barkpark.Pulse

  @impl true
  def join("pulse:" <> name, _params, socket) do
    case Pulse.channel(name) do
      {:ok, _cfg} -> {:ok, %{total: Pulse.total(name)}, socket}
      :error -> {:error, %{reason: "unknown pulse channel"}}
    end
  end
end
