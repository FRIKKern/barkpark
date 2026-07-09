defmodule BarkparkWeb.QuizHostLive do
  @moduledoc """
  P1 host/projector surface (the big-screen half of the split-surface client).
  `/quiz/host/:pin` ensures the room, shows the question, the live player count,
  and animated per-choice tally bars that move as answers land — read-only, no
  input. Subscribes to the room events topic so every `{:tally, t}` /
  `{:player_joined|left, _}` broadcast re-renders without polling.

  This is the surface P5's crowd heatmap will eventually replace the bars with
  (`/papers/hyperquiz-realtime-protocol`); for P1 it's the individual-tally view.
  """
  use Phoenix.LiveView

  alias Barkpark.Quiz

  @impl true
  def mount(%{"pin" => pin}, _session, socket) do
    if connected?(socket) do
      {:ok, _pid} = Quiz.ensure_room(pin)
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
      state = Quiz.state(pin)

      {:ok,
       assign(socket,
         pin: pin,
         question: state.question,
         tally: state.tally,
         player_count: state.player_count
       )}
    else
      {:ok, assign(socket, pin: pin, question: nil, tally: %{}, player_count: 0)}
    end
  end

  @impl true
  def handle_info({:quiz, _pin, {:tally, tally}}, socket),
    do: {:noreply, assign(socket, tally: tally)}

  # Roster broadcasts carry the AUTHORITATIVE count — assign it directly rather
  # than accumulating +1/-1 deltas against a separately-read base (which drifts).
  def handle_info({:quiz, _pin, {:player_joined, _player, count}}, socket),
    do: {:noreply, assign(socket, player_count: count)}

  def handle_info({:quiz, _pin, {:player_left, _player_id, _slot, count}}, socket),
    do: {:noreply, assign(socket, player_count: count)}

  # Live-edit (P4): re-render the projector with the swapped question.
  def handle_info({:quiz, _pin, {:question_updated, question}}, socket),
    do: {:noreply, assign(socket, question: question)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :total, assigns.tally |> Map.values() |> Enum.sum())

    ~H"""
    <div class="q-shell">
      <canvas class="quiz-cursor-canvas" data-quiz-pin={@pin} data-quiz-role="host"></canvas>
      <p class="q-eyebrow">Hyperquiz · Host</p>
      <p class="q-pin">
        Join at <code>/quiz/play/{@pin}</code> · <span class="q-count">{@player_count} players</span>
      </p>

      <%= if @question do %>
        <h1 class="q-question">{@question.prompt}</h1>
        <img :if={@question[:image]} src={@question[:image]} alt="" class="q-image" />
        <div class="q-meta">{@total} answers in</div>

        <div class="q-bar-row" :for={{choice, idx} <- Enum.with_index(@question.choices)}>
          <div class="q-bar-label">
            <span>{choice.label}</span>
            <span class="q-count">{Map.get(@tally, choice.id, 0)}</span>
          </div>
          <div class="q-bar-track">
            <div class={"q-bar-fill c#{rem(idx, 4)}"} style={"width: #{pct(Map.get(@tally, choice.id, 0), @total)}%"}></div>
          </div>
        </div>
      <% else %>
        <p class="q-status">Opening the room…</p>
      <% end %>
    </div>
    """
  end

  defp pct(_count, 0), do: 0
  defp pct(count, total), do: round(count / total * 100)
end
