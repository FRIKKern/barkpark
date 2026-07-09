defmodule BarkparkWeb.QuizChannel do
  @moduledoc """
  Player-facing quiz channel (P1) — joins the three P1 backend tasks into one
  cohesive surface over a single anonymous WebSocket:

    * **Join flow + Presence** — a phone/browser joins `"quiz:room:<pin>"` with
      a nickname; we ensure the room (`Barkpark.Quiz`), register the player, and
      track them in `BarkparkWeb.Presence` on the channel topic so every client
      sees the live roster.
    * **Answer submit** — a `"submit_answer"` frame records the player's choice
      (last write wins) and replies with the fresh tally.
    * **Live tally** — the room broadcasts `{:quiz, pin, {:tally, t}}` on its
      events topic after every answer; this channel subscribes to that topic and
      forwards each update as a `"tally"` push. O(N) fan-out — fine for P1's
      few-hundred individual path (the heatmap path is P5,
      `/papers/hyperquiz-scaling`).

  No API token: players are anonymous (see `BarkparkWeb.QuizSocket`). The room
  events topic (`Barkpark.Quiz.room_topic/1` → `quiz:events:<pin>`) is distinct
  from this channel's topic, so the explicit subscribe below never collides with
  the channel's own channel-topic subscription.
  """
  use Phoenix.Channel

  alias Barkpark.Quiz
  alias BarkparkWeb.Presence

  # Backpressure: accept at most one inbound cursor per this many ms per
  # connection (~30Hz); faster frames are coalesced/dropped.
  @cursor_min_interval_ms 33

  # Anti-abuse: minimum gap between accepted answer submissions per connection.
  @submit_min_interval_ms 250

  # Backpressure: minimum gap between accepted hover frames per connection.
  @hover_min_interval_ms 50

  # Observer join (host/projector): subscribes to the room's frames but is NEVER
  # registered or counted as a player — that's what kept player_count honest.
  @impl true
  def join("quiz:room:" <> pin, %{"observe" => true}, socket) when pin != "" do
    case Quiz.ensure_room(pin) do
      {:ok, _pid} ->
        Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
        Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.cursor_topic(pin))
        Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.heat_topic(pin))
        {:ok, %{observer: true}, socket |> assign(:pin, pin) |> assign(:observer, true)}

      {:error, _reason} ->
        {:error, %{reason: "room_unavailable"}}
    end
  end

  def join("quiz:room:" <> pin, params, socket) when pin != "" do
    name = sanitize_name(params["name"])
    player_id = socket.assigns.player_id

    case Quiz.join(pin, player_id, name) do
      {:ok, snapshot} ->
        Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
        Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.cursor_topic(pin))
        Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.heat_topic(pin))

        socket =
          socket
          |> assign(:pin, pin)
          |> assign(:name, name)

        send(self(), :after_join)
        # Hand back a signed identity token the client stores + presents on reconnect.
        reply = Map.put(snapshot, :player_token, BarkparkWeb.QuizSocket.sign(player_id))
        {:ok, reply, socket}

      {:error, _reason} ->
        {:error, %{reason: "room_unavailable"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "bad_topic"}}

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _ref} =
      Presence.track(socket, socket.assigns.player_id, %{
        name: socket.assigns.name,
        joined_at: System.system_time(:second)
      })

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  # Room events topic → client pushes.
  def handle_info({:quiz, _pin, {:tally, tally}}, socket) do
    push(socket, "tally", %{tally: tally})
    {:noreply, socket}
  end

  def handle_info({:quiz, _pin, {:player_joined, player, count}}, socket) do
    push(socket, "player_joined", %{id: player.id, name: player.name, player_count: count})
    {:noreply, socket}
  end

  def handle_info({:quiz, _pin, {:player_left, player_id, slot, count}}, socket) do
    # Carry the slot so the canvas can evict the departed cursor (the binary
    # delta protocol never encodes removals).
    push(socket, "player_left", %{id: player_id, slot: slot, player_count: count})
    {:noreply, socket}
  end

  def handle_info({:quiz, _pin, {:hover_counts, counts}}, socket) do
    push(socket, "hover_counts", %{counts: counts})
    {:noreply, socket}
  end

  # Cursor topic → push the raw binary CursorFrame straight to the client
  # (decoded in JS); binary frames keep the wire small (2 + 6·N bytes).
  def handle_info({:quiz_cursors, _pin, frame}, socket) when is_binary(frame) do
    push(socket, "cursors", {:binary, frame})
    {:noreply, socket}
  end

  # Aggregate heatmap frame (above the crossover) → client renders a density cloud.
  def handle_info({:quiz_heat, _pin, frame}, socket) when is_binary(frame) do
    push(socket, "heatmap", {:binary, frame})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_in("submit_answer", %{"choice" => choice_id}, socket)
      when is_binary(choice_id) do
    now = System.monotonic_time(:millisecond)
    last = Map.get(socket.assigns, :last_submit_ms)

    if not is_nil(last) and now - last < @submit_min_interval_ms do
      {:reply, {:error, %{reason: "rate_limited"}}, socket}
    else
      case Quiz.submit_answer(socket.assigns.pin, socket.assigns.player_id, choice_id) do
        {:ok, tally} -> {:reply, {:ok, %{tally: tally}}, assign(socket, :last_submit_ms, now)}
        {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    end
  end

  def handle_in("submit_answer", _bad, socket),
    do: {:reply, {:error, %{reason: "invalid_payload"}}, socket}

  # High-frequency, fire-and-forget: the client streams normalized 0..1 cursor
  # positions; the room quantizes + batches them into the ~15Hz frame.
  def handle_in("cursor", %{"x" => x, "y" => y}, socket) when is_number(x) and is_number(y) do
    now = System.monotonic_time(:millisecond)
    last = Map.get(socket.assigns, :last_cursor_ms)

    if is_nil(last) or now - last >= @cursor_min_interval_ms do
      Quiz.move(socket.assigns.pin, socket.assigns.player_id, x, y)
      {:noreply, assign(socket, :last_cursor_ms, now)}
    else
      {:noreply, socket}
    end
  end

  def handle_in("hover", %{"choice" => choice}, socket)
      when is_binary(choice) or is_nil(choice) do
    now = System.monotonic_time(:millisecond)
    last = Map.get(socket.assigns, :last_hover_ms)

    if is_nil(last) or now - last >= @hover_min_interval_ms do
      Quiz.hover(socket.assigns.pin, socket.assigns.player_id, choice)
      {:noreply, assign(socket, :last_hover_ms, now)}
    else
      {:noreply, socket}
    end
  end

  def handle_in(event, _payload, socket) when event in ["cursor", "hover"],
    do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    # Best-effort: drop the player from room state on disconnect (Presence
    # untracks itself). On a failed join `pin` is unset — skip cleanly.
    case socket.assigns do
      # Observers never joined as players — nothing to shed.
      %{observer: true} -> :ok
      %{pin: pin, player_id: player_id} -> Quiz.leave(pin, player_id)
      _ -> :ok
    end

    :ok
  end

  # Strip control chars, collapse internal whitespace, trim, cap 24, default empty.
  defp sanitize_name(name) when is_binary(name) do
    cleaned =
      name
      |> String.replace(~r/[[:cntrl:]]/u, "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, 24)

    if cleaned == "", do: "Player", else: cleaned
  end

  defp sanitize_name(_), do: "Player"
end
