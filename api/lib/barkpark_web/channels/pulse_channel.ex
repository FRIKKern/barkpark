defmodule BarkparkWeb.PulseChannel do
  @moduledoc """
  Subscribe-only realtime feed for one Pulse channel (Shared Storm).

  A client joins `"pulse:<channel>"`; the join is admitted only when the pulse
  channel is explicitly configured (`Barkpark.Pulse.channel/1`) — unknown
  channels fail closed, mirroring the HTTP surface's 404. The join reply
  carries the current durable total so a fresh client shows the counter
  without a round-trip.

  Durable events flow ONE way: `PulseController.create/2` broadcasts each
  recorded strike as a `"strike"` event (`%{id, payload, total}`) on the topic
  and Phoenix pushes it to every subscriber. Strike WRITES stay on the
  rate-limited HTTP POST.

  The one inbound frame is `"cursor"` — live presence (a visitor's charged
  cursor position + hue), EPHEMERAL by design: validated, throttled per socket
  (≥80ms between frames, silent drop), rebroadcast to every OTHER subscriber,
  and never touches the database, the counter, or the feed. `x = -1` means
  "cursor left". A stolen socket can therefore wiggle a ghost cursor and
  nothing else.
  """
  use Phoenix.Channel

  alias Barkpark.Pulse

  @cursor_min_interval_ms 80

  @impl true
  def join("pulse:" <> name, _params, socket) do
    case Pulse.channel(name) do
      {:ok, _cfg} ->
        socket =
          socket
          |> assign(:sid, Base.encode16(:crypto.strong_rand_bytes(4), case: :lower))
          # monotonic time is usually NEGATIVE — a 0 sentinel would throttle
          # every frame forever. Seed one interval in the past instead.
          |> assign(
            :last_cursor_ms,
            System.monotonic_time(:millisecond) - @cursor_min_interval_ms - 1
          )

        {:ok, %{total: Pulse.total(name)}, socket}

      :error ->
        {:error, %{reason: "unknown pulse channel"}}
    end
  end

  @impl true
  def handle_in("cursor", %{"x" => x, "y" => y} = p, socket)
      when is_number(x) and is_number(y) and x >= -1 and x <= 1 and y >= 0 and y <= 1 do
    now = System.monotonic_time(:millisecond)

    if now - socket.assigns.last_cursor_ms >= @cursor_min_interval_ms do
      hue =
        case p["hue"] do
          h when is_integer(h) and h >= 0 and h <= 359 -> h
          _ -> 0
        end

      chg =
        case p["chg"] do
          c when is_number(c) and c >= 0 and c <= 1 -> c
          _ -> 0
        end

      broadcast_from!(socket, "cursor", %{sid: socket.assigns.sid, x: x, y: y, hue: hue, chg: chg})

      {:noreply, assign(socket, :last_cursor_ms, now)}
    else
      {:noreply, socket}
    end
  end

  # anything else inbound is silently ignored — this stays a presence-and-feed
  # surface, never a write path
  def handle_in(_event, _payload, socket), do: {:noreply, socket}
end
